#!/bin/bash
# waves.test.sh - parallel features: worktrees, the merge queue, the graph.
#
# What matters here:
#   - a feature lives in its own worktree and the checkout is left alone
#   - the merge queue lands an approved feature only if the merged result is
#     green; a red integration leaves the base where it was
#   - a conflict is a rejection with a reason, not a half-merge
#   - a feature declares what it depends on; it cannot be crewed until they
#     land; `waves next` refreshes it from the base and starts it

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo waves
export ORCH_LAUNCHER=print
printf 'parallel features\n\n'

attest_green() {  # attest_green <F> — in F's tree, commit, attest, approve
  enter_feature "$1" >/dev/null 2>&1
  git add -A && git commit -q -m "$1 work"
  "$ORCH" run --feature "$1" --label build -- sh -c 'exit 0' >/dev/null 2>&1
  "$ORCH" run --feature "$1" --label tests -- sh -c 'exit 0' >/dev/null 2>&1
  "$ORCH" approve "$1" --gate human >/dev/null 2>&1
  leave_feature >/dev/null 2>&1
}

printf 'features start in worktrees:\n'
HEAD0="$(git rev-parse HEAD)"
out="$("$ORCH" feature start F100-a --request "feature a" --tier quick 2>&1)"
contains "$out" ".orch/worktrees/F100-a/main" "the feature says where its tree is"
[ -d "$ORCH_REPO/.orch/worktrees/F100-a/main" ]; chk $? "and it exists"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] && [ "$(git rev-parse HEAD)" = "$HEAD0" ]; chk $? "the checkout was left alone"
[ "$(git -C "$ORCH_REPO/.orch/worktrees/F100-a/main" rev-parse --abbrev-ref HEAD)" = feature/F100-a ]; chk $? "the worktree is on feature/F100-a"
[ -r "$ORCH_REPO/.orch/worktrees/F100-a/main/docs/features/F100-a/request.md" ]; chk $? "and the request is frozen in the feature's tree"
[ ! -e "$ORCH_REPO/docs/features/F100-a" ]; chk $? "not in the checkout"
"$ORCH" feature start F101-b --request "feature b" --tier quick >/dev/null 2>&1
"$ORCH" feature start F103-d --request "feature d, which will conflict with a" --tier quick >/dev/null 2>&1
out="$("$ORCH" feature start F102-c --request "feature c, on a and b" --after F100-a,F101-b --tier quick 2>&1)"
contains "$out" "after F100-a,F101-b" "a feature declares what it depends on"
out="$("$ORCH" feature start F104-bad --request "x" --after F104-bad 2>&1)"; rc=$?
chk_rc 1 "$rc" "a feature cannot depend on itself"
out="$("$ORCH" team start --feature F100-a 2>&1)"
contains "$out" "cd $ORCH_REPO/.orch/worktrees/F100-a/main" "a crew is spawned with its cwd in the feature's worktree"

printf '\nthe graph:\n'
out="$("$ORCH" waves 2>&1)"
contains "$(printf '%s' "$out" | grep F102-c)" "blocked" "c is blocked"
contains "$(printf '%s' "$out" | grep F102-c)" "waiting for F100-a, F101-b" "by a and b"
contains "$(printf '%s' "$out" | grep F100-a)" "running" "a is running (its crew was spawned)"
contains "$(printf '%s' "$out" | grep F101-b)" "ready" "b is ready"
out="$("$ORCH" team start --feature F102-c 2>&1)"; rc=$?
chk_rc 1 "$rc" "a blocked feature cannot be crewed"
contains "$out" "waits for F100-a F101-b" "and the refusal names its blockers"

printf '\nwork happens in parallel trees:\n'
enter_feature F100-a >/dev/null 2>&1; printf 'A = 1\n' > src/a.py; leave_feature
enter_feature F103-d >/dev/null 2>&1; printf 'A = 2  # d disagrees\n' > src/a.py; leave_feature
enter_feature F101-b >/dev/null 2>&1; printf 'B = 1\n' > src/b.py; leave_feature
attest_green F100-a; attest_green F101-b; attest_green F103-d
[ ! -e src/a.py ] && [ ! -e src/b.py ]; chk $? "nothing has reached the checkout"
out="$("$ORCH" merge status 2>&1)"
[ "$(printf '%s' "$out" | grep -c 'approved — orch merge')" = "3" ]; chk $? "three features are approved and waiting"

printf '\nthe merge queue:\n'
out="$("$ORCH" merge F102-c 2>&1)"; rc=$?
chk_rc 1 "$rc" "an unapproved feature does not land"
contains "$out" "no human approval" "for the stated reason"
# a suite that passes for a alone and fails once b is there too
export ORCH_TEST_CMD='test ! -f src/b.py'
out="$("$ORCH" merge F100-a 2>&1)"; rc=$?
chk_rc 0 "$rc" "a lands"
contains "$out" "landed F100-a on main" "on the base"
[ -f src/a.py ] && [ "$(cat src/a.py)" = "A = 1" ]; chk $? "and the checkout, on main, was fast-forwarded to it"
jq -e -s 'any(.[]; .event=="merge.landed")' "$(fdir F100-a)/ledger.jsonl" >/dev/null; chk $? "recorded on a's ledger"
jq -e -s 'any(.[]; .event=="merge.landed" and .feature=="F100-a")' docs/features/_orch/ledger.jsonl >/dev/null; chk $? "and the run's"
out="$("$ORCH" merge F100-a 2>&1)"; rc=$?
chk_rc 1 "$rc" "a cannot land twice"

BASE1="$(git rev-parse main)"
out="$("$ORCH" merge F103-d 2>&1)"; rc=$?
chk_rc 1 "$rc" "d, which also created src/a.py, conflicts"
contains "$out" "conflicts with main" "and is told so"
[ "$(git rev-parse main)" = "$BASE1" ]; chk $? "the base did not move"
jq -e -s 'any(.[]; .event=="merge.rejected" and .reason=="conflict")' "$(fdir F103-d)/ledger.jsonl" >/dev/null; chk $? "recorded as a conflict"

out="$("$ORCH" merge F101-b 2>&1)"; rc=$?
chk_rc 1 "$rc" "b is green alone and red with a: rejected"
contains "$out" "green alone and red merged" "and told exactly that"
[ "$(git rev-parse main)" = "$BASE1" ]; chk $? "the base did not move"
[ ! -e src/b.py ]; chk $? "and b's file is not on the checkout"
jq -e -s 'any(.[]; .event=="merge.rejected" and .reason=="integration_red")' "$(fdir F101-b)/ledger.jsonl" >/dev/null; chk $? "recorded as integration red"
jq -e -s 'any(.[]; .label=="integration-F101-b" and .exit_code!=0)' docs/features/_orch/evidence.jsonl >/dev/null; chk $? "with the integration run attested under the run ledger"
contains "$("$ORCH" merge status 2>&1 | grep F101-b)" "rejected at this head" "merge status says so"
[ ! -e .orch/worktrees/_integration ]; chk $? "the integration worktree is gone"

export ORCH_TEST_CMD='true'
out="$("$ORCH" merge F101-b --close 2>&1)"; rc=$?
chk_rc 0 "$rc" "with the suite fixed, b lands"
[ -f src/b.py ]; chk $? "onto the checkout"
[ ! -d .orch/worktrees/F101-b/main ]; chk $? "and --close removed its worktree"
git rev-parse --verify --quiet feature/F101-b >/dev/null; chk $? "keeping the branch for the record"

printf '\nthe next wave:\n'
out="$("$ORCH" waves 2>&1)"
contains "$(printf '%s' "$out" | grep F102-c)" "ready" "with a and b landed, c is ready"
out="$("$ORCH" waves next 2>&1)"
contains "$out" "ready: F102-c" "waves next names it"
contains "$out" "orch team start --feature F102-c" "with the command to start it"
[ -f .orch/worktrees/F102-c/main/src/a.py ] && [ -f .orch/worktrees/F102-c/main/src/b.py ]; chk $? "and its branch now carries what it depends on"
jq -e -s 'any(.[]; .event=="wave.refreshed")' "$(fdir F102-c)/ledger.jsonl" >/dev/null; chk $? "recorded"
out="$("$ORCH" waves next --start 2>&1)"
contains "$out" "ORCH_ROLE=developer" "--start spawns the crew"
contains "$out" "cd $ORCH_REPO/.orch/worktrees/F102-c/main" "in c's worktree"
contains "$("$ORCH" waves 2>&1 | grep F102-c)" "running" "and c is running"
out="$("$ORCH" waves next 2>&1)"
contains "$out" "nothing is ready" "nothing else is ready"

finish waves
