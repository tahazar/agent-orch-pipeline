#!/bin/bash
# holdout.test.sh - the read-back, the contract gate, and the holdout.
#
# What matters here:
#   - the read-back session is blind: the artifact guard denies it every
#     artifact, and its record is bound to the oracle sha it describes
#   - the contract gate: stubs that build and touch no oracle; once met,
#     the red phase must build at its own sha
#   - the holdout: designated by the test-engineer, denied to the developer
#     by read, write and executor, run in a clean worktree at HEAD, a merge
#     gate when present, and a failure escalates rather than repairs

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo holdout
export ORCH_LAUNCHER=print
printf 'read-back, contract, holdout\n\n'

hook() { printf '%s' "$2" | "$ORCH_ROOT/hooks/$1"; }
rd() {  # rd <path> <role> [lens]
  printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1" \
    | ORCH_ROLE="$2" ORCH_LENS="${3:-}" "$ORCH_ROOT/hooks/artifact-scope.sh" 2>&1
}
ws() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" \
    | ORCH_ROLE="$2" "$ORCH_ROOT/hooks/write-scope.sh" 2>&1
}
MERGE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git merge feature/x"}}'

export ORCH_FEATURE=F080-rb
"$ORCH" feature start F080-rb --request "mean" >/dev/null 2>&1
enter_feature F080-rb >/dev/null 2>&1 || true
printf -- '- R1 mean of a list\n' > docs/features/F080-rb/requirements.md
printf 'def mean(xs: list[float]) -> float: ...\n' > docs/features/F080-rb/contract.md
"$ORCH" tier recommend F080-rb strict --why x >/dev/null 2>&1 && "$ORCH" tier confirm F080-rb >/dev/null 2>&1
git add -A && git commit -q -m "statement"
L="$ORCH_REPO/docs/features/F080-rb/ledger.jsonl"

# --- the contract gate --------------------------------------------------------
printf 'the contract gate — the statement, made compilable:\n'
CONTRACT='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: contract stubs","metadata":{"orch":{"feature":"F080-rb","requires":"contract-compiles"}}}}'
out="$(hook task-guard.sh "$CONTRACT" 2>&1)"; rc=$?
chk_rc 2 "$rc" "no attested build, no contract"
contains "$out" "does not build" "and the guard says so"
printf 'def mean(xs):\n    raise NotImplementedError\n' > src/mean.py
git add -A && git commit -q -m "stubs"
"$ORCH" run --feature F080-rb --label build -- sh -c 'exit 0' >/dev/null 2>&1
out="$(hook task-guard.sh '{"hook_event_name":"TaskCompleted","task":{"subject":"developer: contract stubs"}}' 2>&1)"; rc=$?
chk_rc 0 "$rc" "stubs that build meet the gate — inferred from the subject, too"
[ "$("$ORCH" gate read F080-rb contract | jq -r .state)" = met ]; chk $? "and the contract gate is set"

printf '\nonce the contract compiles, the red phase must too:\n'
printf 'from src.mean import mean\n\n\ndef test_mean():  # R1\n    assert mean([2, 4]) == 3\n' > test/test_mean.py
git add -A && git commit -q -m "oracle"
"$ORCH" run --feature F080-rb --label tests -- sh -c 'exit 1' >/dev/null 2>&1
RED='{"hook_event_name":"TaskCompleted","task":{"subject":"test-engineer: red phase","metadata":{"orch":{"feature":"F080-rb","requires":"tests-fail-correctly"}}}}'
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 2 "$rc" "a red run with no build at its sha is refused"
contains "$out" "does not compile" "because the sketch must type-check"
"$ORCH" run --feature F080-rb --label build -- sh -c 'exit 0' >/dev/null 2>&1
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 0 "$rc" "build green and tests red at the same sha: the red phase passes"
jq -e -s 'any(.[]; .event=="oracle.frozen")' "$L" >/dev/null; chk $? "and the oracle is frozen"

# --- the read-back ------------------------------------------------------------
printf '\nthe read-back is blind:\n'
out="$("$ORCH" readback start F080-rb 2>&1)"
contains "$out" "ORCH_LENS=readback" "a code-reviewer session with the readback lens"
contains "$out" "--effort low" "at low effort — translation, not judgement"
not_contains "$out" "--model" "on the role's own model"
contains "$out" "orch readback files F080-rb" "told where the tests are"
out="$("$ORCH" readback files F080-rb 2>&1)"
contains "$out" "test/test_mean.py" "which lists the oracle files"
out="$(rd "$ORCH_REPO/docs/features/F080-rb/requirements.md" code-reviewer readback)"; rc=$?
chk_rc 2 "$rc" "requirements.md is denied to it"
contains "$out" "written blind" "for the stated reason"
out="$(rd "$ORCH_REPO/docs/features/F080-rb/contract.md" code-reviewer readback)"; rc=$?
chk_rc 2 "$rc" "so is contract.md"
out="$(rd "$ORCH_REPO/docs/features/F080-rb/requirements.md" code-reviewer correctness)"; rc=$?
chk_rc 0 "$rc" "while a review lens still reads its criteria"
out="$(rd "$ORCH_REPO/test/test_mean.py" code-reviewer readback)"; rc=$?
chk_rc 0 "$rc" "and the read-back reads the tests"

printf 'test_mean: passes iff mean([2, 4]) returns exactly 3. Nothing constrains an empty list.\n' \
  | "$ORCH" readback record F080-rb - >/dev/null 2>&1
[ "$("$ORCH" readback status F080-rb)" = current ]; chk $? "a recorded read-back is current"
out="$("$ORCH" packet F080-rb 2>&1)"
contains "$out" "Nothing constrains an empty list" "and the packet shows it beside the requirements"
printf '\n\ndef test_empty():  # R1\n    assert mean([]) == 0\n' >> test/test_mean.py
git add -A && git commit -q -m "oracle grows"
"$ORCH" oracle freeze F080-rb >/dev/null 2>&1
[ "$("$ORCH" readback status F080-rb)" = stale ]; chk $? "after the oracle changes, the read-back is stale"
out="$("$ORCH" packet F080-rb 2>&1)"
contains "$out" "STALE" "and the packet says so rather than showing it as current"

# --- the holdout --------------------------------------------------------------
printf '\nthe holdout is chosen by the test-engineer and never shown to the developer:\n'
printf 'from src.mean import mean\n\n\ndef test_big():  # R1\n    assert mean([1e300, 1e300]) == 1e300\n' > test/test_edge.py
git add -A && git commit -q -m "an edge test"
out="$(ORCH_ROLE=developer "$ORCH" holdout add F080-rb test/test_edge.py 2>&1)"; rc=$?
chk_rc 1 "$rc" "the developer cannot designate a holdout"
out="$(ORCH_ROLE=test-engineer "$ORCH" holdout add F080-rb test/test_edge.py 2>&1)"; rc=$?
chk_rc 0 "$rc" "the test-engineer can"
[ ! -e test/test_edge.py ]; chk $? "the file leaves the tree"
[ -r "$MAIN/.orch/holdout/F080-rb/test/test_edge.py" ]; chk $? "and lives under .orch/holdout"
git add -A && git commit -q -m "held out"
[ "$("$ORCH" holdout list F080-rb)" = "test/test_edge.py" ]; chk $? "and is listed"
out="$(rd "$MAIN/.orch/holdout/F080-rb/test/test_edge.py" developer)"; rc=$?
chk_rc 2 "$rc" "the developer cannot read it"
out="$(ws "$MAIN/.orch/holdout/F080-rb/test/test_edge.py" developer)"; rc=$?
chk_rc 2 "$rc" "or write it"
out="$(ORCH_ROLE=developer "$ORCH" run --feature F080-rb --label peek -- cat .orch/holdout/F080-rb/test/test_edge.py 2>&1)"; rc=$?
chk_rc 1 "$rc" "or run a command that names it"
contains "$out" "not shown" "and is told why"
out="$(rd "$MAIN/.orch/holdout/F080-rb/test/test_edge.py" auditor)"; rc=$?
chk_rc 0 "$rc" "the auditor can read it"

printf '\nthe holdout runs clean at HEAD and gates the merge:\n'
printf 'def mean(xs):\n    return sum(xs) / len(xs)\n' > src/mean.py
git add -A && git commit -q -m "implement"
"$ORCH" run --feature F080-rb --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F080-rb --label tests -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" approve F080-rb --gate human >/dev/null 2>&1
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 2 "$rc" "approved, but the holdout has not run: no merge"
contains "$out" "has a holdout" "for the stated reason"
HEAD0="$(git rev-parse HEAD)"
out="$("$ORCH" holdout run F080-rb -- sh -c 'test -f test/test_edge.py && test -f test/test_mean.py && exit 0; exit 3' 2>&1)"; rc=$?
chk_rc 0 "$rc" "the holdout file is present in the clean worktree alongside the oracle"
contains "$out" "PASSED" "and passed"
[ "$(git rev-parse HEAD)" = "$HEAD0" ]; chk $? "the feature branch did not move"
[ ! -e "$(sub_wt F080-rb holdout)" ]; chk $? "and the worktree is gone"
[ "$("$ORCH" gate read F080-rb holdout | jq -r .state)" = met ]; chk $? "the holdout gate is met"
jq -e -s --arg s "$HEAD0" 'any(.[]; .label=="holdout" and .exit_code==0 and .git_sha==$s)' docs/features/F080-rb/evidence.jsonl >/dev/null
chk $? "with evidence attributed to the approved sha"
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 0 "$rc" "and now the merge is allowed"
out="$("$ORCH" packet F080-rb 2>&1)"
contains "$out" "holdout: PASSED at HEAD" "the packet says so"

printf '\na failing holdout escalates, it does not repair:\n'
git commit -q --allow-empty -m "moves"
"$ORCH" run --feature F080-rb --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F080-rb --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$("$ORCH" holdout run F080-rb -- sh -c 'exit 5' 2>&1)"; rc=$?
chk_rc 1 "$rc" "a failing holdout fails"
contains "$out" "Escalated to rung 3" "and escalates to best-of-N"
[ "$("$ORCH" escalate rung F080-rb)" = "3" ]; chk $? "the rung is 3"
jq -e -s 'any(.[]; .event=="holdout.failed")' "$L" >/dev/null; chk $? "on the ledger"
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 2 "$rc" "and the merge is blocked again at the new sha"

finish holdout
