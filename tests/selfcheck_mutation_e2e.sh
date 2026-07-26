#!/usr/bin/env bash
# DIVE-2039 ACCEPTANCE — selfcheck proven by MUTATION, not by a green run.
#
# This is the whole ticket's acceptance criterion, and it is not a formality. A green
# run cannot distinguish a probe that asserts the rail from a probe that asserts
# nothing — that is precisely how heartbeat_gate_shipped_unit.sh shipped unwired for
# three releases while printing "14 passed, 2 failed" and exiting 0 (DIVE-2003), and
# how the ship-flag epoch guard produced an identical signature deleted and working.
# A prover for the succeeding-in-appearance defect class that could itself succeed in
# appearance would be the joke writing itself.
#
# So for each rail: BREAK IT FOR REAL, require selfcheck goes red AND names the
# breakage; restore, require green. "It passed" is not evidence here.
#
# Method: the repo is copied to a throwaway dir, the mutation is applied to the COPY's
# src/ (or tests/), a throwaway bundle is built from it, and that bundle is run. The
# live tree is never mutated — a harness that edits the source it is grading can
# leave a box broken when it dies halfway.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"

command -v sqlite3 >/dev/null 2>&1 || { printf 'skip - sqlite3 absent\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sc-mut.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# A pristine copy of the tree, rebuilt into its own bundle.
WORK="$TMP/repo"
mkdir -p "$WORK"
cp -R "$REPO/src" "$REPO/tests" "$REPO/build.sh" "$WORK/" 2>/dev/null
cp "$REPO/5dive.sha256" "$WORK/" 2>/dev/null || true
rebuild() { (cd "$WORK" && bash build.sh >/dev/null 2>&1); }
rebuild || { printf 'FAIL: could not build the pristine copy\n'; exit 1; }

# Run one probe against the throwaway bundle, with the probes that read a checkout
# pointed at the throwaway checkout rather than the live one.
probe() { # probe <probe-id> -> RC/OUT
  OUT=$(SELFCHECK_REPO_ROOT="$WORK" bash "$WORK/5dive" selfcheck --only="$1" 2>&1); RC=$?
}
# Full restore. `rm -rf` first: `cp -R src "$WORK/"` onto an existing dir nests it as
# src/src, which would leave the mutation live in the tree it claims to have restored.
restore() {
  rm -rf "$WORK/src" "$WORK/tests"
  cp -R "$REPO/src" "$REPO/tests" "$WORK/"
  rebuild
}

# assert_mutation <probe> <label> <mutator-fn> <expected-substring>
# The MUTATOR owns rebuilding, because not every mutation survives one: build.sh
# regenerates 5dive.sha256, so rebuilding after the bundle-integrity mutation would
# silently repair it and the probe would "pass" a mutation that was never applied.
assert_mutation() {
  local p="$1" label="$2" mut="$3" want="$4"
  probe "$p"
  if [[ $RC -eq 0 ]]; then ok_t "[$p] green before the mutation"
  else fail_t "[$p] NOT green before the mutation, so a red after it would prove nothing: $OUT"; return; fi

  "$mut" || { fail_t "[$p] mutation '$label' could not be applied — the probe is UNPROVEN, not passing"; restore; return; }
  probe "$p"
  if [[ $RC -ne 0 ]]; then ok_t "[$p] RED when $label"
  else fail_t "[$p] STILL GREEN when $label — this probe asserts nothing: $OUT"; fi
  if grep -qi -- "$want" <<<"$OUT"; then ok_t "[$p] the red output names the breakage"
  else fail_t "[$p] red, but for an unnamed reason (wanted /$want/): $OUT"; fi

  restore
  probe "$p"
  if [[ $RC -eq 0 ]]; then ok_t "[$p] green again once restored"
  else fail_t "[$p] did not recover after restore — the mutation leaked: $OUT"; fi
}

# ── rail 1: gate delivery ────────────────────────────────────────────────────
# Remove the DIVE-1968 delivery assertion: the wrapper stops synthesising a row for a
# notify path that recorded nothing. The gate is filed, reports OK, records NOTHING —
# the exact live state that left 194 undelivered rows.
mut_gate() {
  grep -q 'if (( ${TASK_GATE_DELIVERY_ROWS:-0} == 0 )); then' "$WORK/src/cmd_task.sh" || return 1
  sed -i 's/if (( ${TASK_GATE_DELIVERY_ROWS:-0} == 0 )); then/if false; then/' "$WORK/src/cmd_task.sh"
  rebuild
}
assert_mutation gate-delivery "the gate delivery assertion is removed" mut_gate "reported as pinged"

# ── rail 2: the audit log ────────────────────────────────────────────────────
# Reinstate DIVE-1989: gate the audit append on $EUID, so an agent running a verb as
# ITSELF writes no row while the identical command under sudo writes one. Measured
# from the non-root side, which is the side the defect hid on.
mut_audit() {
  grep -q '^_emit_audit_line() {' "$WORK/src/lib/audit.sh" || return 1
  sed -i 's/^_emit_audit_line() {/_emit_audit_line() {\n  [[ $EUID -eq 0 ]] || return 0/' "$WORK/src/lib/audit.sh"
  rebuild
}
if [[ $EUID -ne 0 ]]; then
  assert_mutation audit-nonroot "an agent's own actions are gated out of the audit log" mut_audit "leaves no trace"
else
  printf 'skip - audit-nonroot mutation needs an unprivileged uid (this run is root)\n'
fi

# ── rail 3: test harness verdicts ────────────────────────────────────────────
# Strand a harness's verdict behind an unconditional `exit 0` — the DIVE-2003 shape
# verbatim. The harness still prints its failures; CI and `task verify --cmd` both
# grade on $? and both go blind.
mut_harness() {
  local h="$WORK/tests/heartbeat_gate_shipped_unit.sh"
  [[ -r "$h" ]] || return 1
  printf '\nexit 0\n' >> "$h"
}
assert_mutation harness-verdicts "a harness's exit status is stranded behind exit 0" mut_harness "UNWIRED"

# ── rail 4: bundle integrity (cheap, and the same lesson) ────────────────────
# A checksum that describes a different bundle is the DIVE-1977 two-cache-generations
# state made local: the pair is self-consistent and neither half is the code.
# NB: no rebuild — build.sh REGENERATES 5dive.sha256, so a rebuild here would repair
# the mutation and hand the probe a green run it never earned.
mut_bundle() {
  printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$WORK/5dive.sha256"
}
assert_mutation bundle-integrity "the tracked checksum describes another bundle" mut_bundle "different generations"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
