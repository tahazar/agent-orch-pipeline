#!/bin/bash
# launcher.test.sh - session lifecycle.
#
# Runs entirely against ORCH_LAUNCHER=print, which starts no processes. That is
# not a limitation of the suite, it is the property being tested: every
# launcher runs the same command, so asserting on the command is asserting on
# all three, and the suite stays free of a terminal, a claude binary and a
# network.
#
# What matters here:
#   - no crew is spawned before a human confirms a tier
#   - every session in a team gets the same task list and the same role file
#   - a launcher that starts nothing does not report that it started something
#   - the seam is complete for every implementation

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
setup_repo launcher
trap teardown_repo EXIT

export ORCH_LAUNCHER=print
printf 'launcher\n\n'

printf 'the seam is complete for every implementation:\n'
for impl in cmux bg print; do
  missing=''
  for op in spawn kill peek list notify probe; do
    grep -q "orch_lnch_$op()" "$ORCH_ROOT/lib/launcher/$impl.sh" || missing="$missing $op"
  done
  [ -z "$missing" ]; chk $? "$impl implements every operation${missing:+ (missing:$missing)}"
done

out="$(ORCH_LAUNCHER=nonesuch "$ORCH" team status 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "an unknown launcher is refused, not silently defaulted"

printf '\nno crew before a confirmed tier:\n'
"$ORCH" feature start F030-spawn >/dev/null 2>&1
out="$("$ORCH" team start --feature F030-spawn 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "a crew cannot be spawned before a tier is confirmed"
contains "$out" "no confirmed tier" "and the refusal says what is missing"
contains "$out" "orch tier confirm" "and how to fix it"

"$ORCH" tier confirm F030-spawn --tier quick >/dev/null 2>&1
out="$("$ORCH" team start --feature F030-spawn 2>&1)"
contains "$out" "tech-lead" "quick spawns a tech-lead"
contains "$out" "developer" "and a developer"
not_contains "$out" "code-reviewer" "but not a code-reviewer"
not_contains "$out" "test-engineer" "and not a test-engineer"

printf '\nthe crew grows with the rung:\n'
"$ORCH" feature start F031-strict --tier strict >/dev/null 2>&1
out="$("$ORCH" team start --feature F031-strict 2>&1)"
contains "$out" "test-engineer" "strict adds the test-engineer"
contains "$out" "code-reviewer" "and the code-reviewer"

printf '\nevery session in a team shares its coordination environment:\n'
out="$("$ORCH" team start --feature F031-strict 2>&1)"
n_tl="$(printf '%s' "$out" | grep -c 'CLAUDE_CODE_TASK_LIST_ID=')"
n_ag="$(printf '%s' "$out" | grep -c 'claude --agent')"
[ "$n_tl" = "$n_ag" ] && [ "$n_ag" -gt 1 ]
chk $? "all $n_ag sessions carry a task list id"
[ "$(printf '%s' "$out" | grep 'CLAUDE_CODE_TASK_LIST_ID=' | sort -u | grep -c .)" = "1" ]
chk $? "and it is the same one for all of them — a mixed team coordinates with nobody"
[ "$(printf '%s' "$out" | grep -c 'ORCH_FEATURE=F031-strict')" = "$n_ag" ]
chk $? "each knows which feature it is on"

printf '\nroles launch with their own permissions:\n'
out="$("$ORCH" team start 2>&1)"
contains "$out" "role-director.json" "the director gets the director settings"
printf '%s' "$out" | grep -A1 'ORCH_ROLE=auditor' | grep -q 'role-crew.json' \
  || printf '%s' "$out" | grep 'agent auditor' | grep -q 'role-crew.json'
chk $? "the auditor gets the crew settings, not the director's"
contains "$out" "--permission-mode" "every session names a permission mode"
[ "$(printf '%s' "$out" | grep -o -- '--permission-mode [a-zA-Z]*' | sort -u | grep -c .)" = "1" ]
chk $? "and they all share one class — mismatched classes go quiet, not loud"

printf '\ndirector and auditor are the run, not a feature:\n'
not_contains "$out" "ORCH_FEATURE=" "starting the run pins no feature"

printf '\na launcher that starts nothing does not claim it did:\n'
LEDGER="$ORCH_REPO/docs/features/_orch/ledger.jsonl"
jq -e -s 'any(.[]; .event=="agent.printed")' "$LEDGER" >/dev/null
chk $? "print records agent.printed"
jq -e -s 'all(.[]; .event != "agent.spawned")' "$LEDGER" >/dev/null
chk $? "and never agent.spawned — a phantom session would be billed to the feature"

printf '\nunknown roles are refused:\n'
out="$("$ORCH" spawn nonesuch 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "spawning a role with no definition is refused"
contains "$out" "does not exist" "and says the definition is missing"

printf '\nnaming:\n'
out="$("$ORCH" spawn developer --suffix c2 2>&1)"
contains "$out" "-n developer-c2" "a suffix distinguishes best-of-N candidates"
out="$("$ORCH" spawn developer 2>&1)"
contains "$out" "-n developer " "and a bare role keeps the plain name"

finish launcher
