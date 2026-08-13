#!/bin/bash
# task-guard.sh - TaskCompleted. Refuses a task whose gate is not attested.
#
# The gates here are the ones that must hold before a stage is allowed to call
# itself finished:
#
#   tests-fail-correctly  the test-engineer's tests must FAIL before the code exists.
#                         A test that passes before the implementation is a
#                         broken test, and the red phase is the only moment you
#                         can tell.
#   build / tests-pass /
#   no-regression         the developer's oracle must be green before review.
#   review-clean          no blocking finding may still be open at merge.
#
# Each is backed by an external oracle (invariant 6): the hook reads
# evidence.jsonl, which only `orch run` can write, so a stage cannot talk its
# way past this.

set -u
ORCH_PROG=task-guard
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/evidence.sh" 2>/dev/null || {
  printf 'orch task-guard could not load its libraries; NOT blocking.\n' >&2
  exit 0
}
. "$ORCH_HOME/lib/findings.sh" 2>/dev/null || true

payload="$(cat 2>/dev/null)"

# Honour stop_hook_active so a guard cannot trap a session in a loop. The
# consecutive-block cap is 8; a guard that keeps firing past that is a bug in
# the guard, not persistence.
[ "$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

subject="$(printf '%s' "$payload" | jq -r '.task.subject // .subject // ""' 2>/dev/null)"
meta_gate="$(printf '%s' "$payload" | jq -r '.task.metadata.orch.requires // ""' 2>/dev/null)"
feature="$(printf '%s' "$payload" | jq -r '.task.metadata.orch.feature // ""' 2>/dev/null)"
[ -n "$feature" ] || feature="$(orch_current_feature)"

# Which gate this task is claiming. Explicit metadata wins; otherwise the
# stage is inferred from the subject, which is how a task created by hand still
# gets guarded.
gate="$meta_gate"
if [ -z "$gate" ]; then
  case "$subject" in
    *"red phase"*|*"failing test"*|*test-engineer*) gate=tests-fail-correctly ;;
    *implement*|*developer*|*build*)           gate=tests-pass ;;
    *review*|*code-reviewer*)                     gate=review-clean ;;
    *) exit 0 ;;
  esac
fi

block() {  # block <reason> <remedy...>
  ORCH_LEDGER_FEATURE="$feature" ledger_append gate.blocked gate "$gate" reason "$1" task "$subject"
  printf 'BLOCKED (%s): %s\n\n%s\n' "$gate" "$1" "$2" >&2
  exit 2
}

ORCH_LEDGER_FEATURE="$feature" ledger_append gate.checked gate "$gate" task "$subject"

case "$gate" in
  tests-fail-correctly)
    if ! evidence_verify "$feature" tests --claim fail >/dev/null 2>&1; then
      block "the red phase is unattested" \
"The test-engineer's tests must be shown FAILING before the implementation exists.
A test that passes now would be testing nothing, and you would never find out.

  orch run --feature $feature --label tests -- <your test command>

The run is expected to exit non-zero. That non-zero exit IS the attestation."
    fi
    ;;

  tests-pass|build|no-regression)
    for g in build tests; do
      evidence_verify "$feature" "$g" --claim pass >/dev/null 2>&1 && continue
      block "$g is not attested green at this sha" \
"Review does not start before the oracle is green, and the oracle is the
command, not your summary of it.

  orch run --feature $feature --label $g -- <command>

If it is already green, it is green at a sha older than HEAD — run it again."
    done
    ;;

  review-clean)
    if declare -f findings_current >/dev/null 2>&1; then
      open_blocking="$(findings_current "$feature" 2>/dev/null \
        | jq -s '[.[] | select(.status=="open" and .severity=="blocking")] | length' 2>/dev/null)"
      if [ "${open_blocking:-0}" -gt 0 ]; then
        block "$open_blocking blocking finding(s) still open" \
"$(findings_current "$feature" | jq -s -r '.[] | select(.status=="open" and .severity=="blocking")
   | "  \(.id)  \(.file):\(.line)  \(.claim)"')

Fix each one, or dispute it with a reason:

  orch findings dispute $feature <id> --reason \"<why the finding is wrong>\"

Disputing is a claim the auditor can test. Silence is not."
      fi
    fi
    ;;
esac

exit 0
