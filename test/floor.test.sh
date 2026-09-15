#!/bin/bash
# floor.test.sh - the verification floor: statement frozen, oracle frozen,
# evidence clean.
#
# What matters here (docs/VERIFICATION.md, gaps 1 and 2):
#   - the statement is hashed at feature start and tier confirm, and a gate
#     refuses STATEMENT_MOVED when a frozen file changes — by any tool
#   - the oracle is the test tree at the red-phase sha, and the green gate
#     refuses ORACLE_MOVED when that tree differs — by any tool, any worktree
#   - a run over uncommitted changes is recorded dirty and rejected by --fresh
#   - only the tech-lead may write the statement; the developer may add tests
#     under its own path and nowhere else in the test tree

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo floor
printf 'the verification floor\n\n'

hook() {  # hook <script> <json>
  printf '%s' "$2" | "$ORCH_ROOT/hooks/$1"
}
ws() {  # ws <path> <role>
  printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" \
    | ORCH_ROLE="$2" "$ORCH_ROOT/hooks/write-scope.sh" 2>&1
}
MERGE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git merge feature/x"}}'

# --- the statement ---------------------------------------------------------
printf 'the statement is frozen by hash:\n'
export ORCH_FEATURE=F040-stmt
"$ORCH" feature start F040-stmt --request "add a mean function" >/dev/null 2>&1
L="$ORCH_REPO/docs/features/F040-stmt/ledger.jsonl"
jq -e -s 'any(.[]; .event=="statement.frozen" and (.files | has("request.md")))' "$L" >/dev/null
chk $? "feature start freezes request.md"
out="$("$ORCH" statement check F040-stmt 2>&1)"; rc=$?
chk_rc 0 "$rc" "and the check passes while nothing has moved"

printf 'R1 mean of a non-empty list\nR2 empty list raises\n' > "$ORCH_REPO/docs/features/F040-stmt/requirements.md"
"$ORCH" tier recommend F040-stmt standard --why "logic" >/dev/null 2>&1
"$ORCH" tier confirm F040-stmt >/dev/null 2>&1
jq -e -s '[.[] | select(.event=="statement.frozen")] | last | .files | has("requirements.md")' "$L" >/dev/null
chk $? "tier confirm freezes requirements.md too"

printf 'R3 also sort it\n' >> "$ORCH_REPO/docs/features/F040-stmt/requirements.md"
out="$("$ORCH" statement check F040-stmt 2>&1)"; rc=$?
chk_rc 6 "$rc" "editing a frozen file is STATEMENT_MOVED"
contains "$out" "STATEMENT_MOVED" "and the failure is named"
contains "$out" "requirements.md" "and so is the file"
contains "$out" "orch statement freeze" "and the remedy is a re-freeze with a reason"
grep -q '"event":"statement.moved"' "$L"; chk $? "and the move is on the ledger"

BUILD='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: implement","metadata":{"orch":{"feature":"F040-stmt","requires":"tests-pass"}}}}'
out="$(hook task-guard.sh "$BUILD" 2>&1)"; rc=$?
chk_rc 2 "$rc" "no stage completes against a moved statement"
contains "$out" "statement moved" "and the guard says which boundary it hit"
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 2 "$rc" "and nothing merges against one"
contains "$out" "STATEMENT_MOVED" "for the stated reason"

out="$("$ORCH" statement freeze F040-stmt --why "R3 was always implied" 2>&1)"; rc=$?
chk_rc 0 "$rc" "a re-freeze with a reason is accepted"
out="$("$ORCH" statement check F040-stmt 2>&1)"; rc=$?
chk_rc 0 "$rc" "and the check passes again"
jq -e -s '[.[] | select(.event=="statement.frozen")] | last | .why == "R3 was always implied"' "$L" >/dev/null
chk $? "with the reason on the ledger, not in anyone's head"

printf '\nonly the tech-lead writes the statement:\n'
out="$(ws "$ORCH_REPO/docs/features/F040-stmt/requirements.md" tech-lead)"; rc=$?
chk_rc 0 "$rc" "the tech-lead may edit requirements.md"
for r in developer test-engineer director auditor; do
  out="$(ws "$ORCH_REPO/docs/features/F040-stmt/requirements.md" $r)"; rc=$?
  chk_rc 2 "$rc" "the $r may not"
done
contains "$out" "it is the statement" "and is told what it hit"
out="$(ws "$ORCH_REPO/docs/features/F040-stmt/request.md" developer)"; rc=$?
chk_rc 2 "$rc" "request.md is the statement too"
out="$(ws "$ORCH_REPO/docs/features/F040-stmt/design.md" developer)"; rc=$?
chk_rc 0 "$rc" "the developer still writes its own artifacts"

# --- the oracle -------------------------------------------------------------
printf '\nthe oracle is the test tree at the red-phase sha:\n'
export ORCH_FEATURE=F041-oracle
"$ORCH" feature start F041-oracle --request "mean" --tier strict >/dev/null 2>&1
L="$ORCH_REPO/docs/features/F041-oracle/ledger.jsonl"
printf 'from src.mean import mean\n\n\ndef test_mean():\n    assert mean([1, 2, 3]) == 2\n' > test/test_mean.py
git add -A && git commit -q -m "oracle: mean"
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 1' >/dev/null 2>&1
RED='{"hook_event_name":"TaskCompleted","task":{"subject":"test-engineer: red phase","metadata":{"orch":{"feature":"F041-oracle","requires":"tests-fail-correctly"}}}}'
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the red phase passes over a committed, failing oracle"
jq -e -s 'any(.[]; .event=="oracle.frozen" and .files==2)' "$L" >/dev/null
chk $? "and freezes the oracle: two test files, hashed at the red sha"
out="$("$ORCH" oracle check F041-oracle 2>&1)"; rc=$?
chk_rc 0 "$rc" "the check passes while the tree is unchanged"

printf 'def mean(xs):\n    return sum(xs) / len(xs)\n' > src/mean.py
git add -A && git commit -q -m "implement mean"
"$ORCH" run --feature F041-oracle --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 0' >/dev/null 2>&1
GREEN='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: implement","metadata":{"orch":{"feature":"F041-oracle","requires":"tests-pass"}}}}'
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the green gate passes when the oracle is the one that failed"

printf '    assert True\n' >> test/test_mean.py
git add -A && git commit -q -m "developer weakens the oracle"
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 2 "$rc" "an edited oracle test is ORACLE_MOVED — however it was edited"
contains "$out" "ORACLE_MOVED" "and the failure is named"
contains "$out" "test/test_mean.py" "and so is the file"
contains "$out" "orch findings dispute" "and the remedy is a dispute, not an edit"
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 2 "$rc" "and nothing merges against a moved oracle"
contains "$out" "ORACLE_MOVED" "for the stated reason"

git checkout HEAD~1 -- test/test_mean.py   # restore the frozen oracle file
mkdir -p test/dev && printf 'def test_extra():\n    assert 1\n' > test/dev/test_extra.py
git add -A && git commit -q -m "developer adds its own test"
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the developer's own tests under test/dev do not move the oracle"

printf '\nthe developer may add tests, not edit the oracle:\n'
out="$(ws "$ORCH_REPO/test/test_mean.py" developer)"; rc=$?
chk_rc 2 "$rc" "at strict the oracle is denied to the developer"
contains "$out" "test/dev" "and the deny names where its own tests go"
out="$(ws "$ORCH_REPO/test/dev/test_more.py" developer)"; rc=$?
chk_rc 0 "$rc" "which is allowed"
out="$(ws "$ORCH_REPO/test/dev/test_more.py" test-engineer)"; rc=$?
chk_rc 2 "$rc" "and denied to the test-engineer, whose tests must be in the oracle"
out="$(ws "$ORCH_REPO/.github/workflows/ci.yml" developer)"; rc=$?
chk_rc 2 "$rc" "at strict the CI workflow is trusted configuration"
contains "$out" "trusted configuration" "and the deny says so"
out="$(ws "$ORCH_REPO/jest.config.js" developer)"; rc=$?
chk_rc 2 "$rc" "so is the runner config"
out="$(ws "$ORCH_REPO/src/mean.py" developer)"; rc=$?
chk_rc 0 "$rc" "source is still the developer's"

# --- clean evidence ---------------------------------------------------------
printf '\nevidence over uncommitted changes is dirty:\n'
printf '# tweak\n' >> src/mean.py
"$ORCH" run --feature F041-oracle --label build -- sh -c 'exit 0' >/dev/null 2>&1
ev="$ORCH_REPO/docs/features/F041-oracle/evidence.jsonl"
jq -e -s 'last | .dirty == true and .dirty_files == 1' "$ev" >/dev/null
chk $? "the row records the dirty tree and how many files"
out="$("$ORCH" evidence verify --feature F041-oracle --label build --claim pass --fresh 2>&1)"; rc=$?
chk_rc 6 "$rc" "--fresh rejects it"
contains "$out" "EVIDENCE_DIRTY" "and names the failure mode"
out="$("$ORCH" evidence verify --feature F041-oracle --label build --claim pass 2>&1)"; rc=$?
chk_rc 0 "$rc" "a plain verify still accepts the exit code"
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 2 "$rc" "the green gate does not"
contains "$out" "uncommitted" "and says why"
git add -A && git commit -q -m "tweak"
"$ORCH" run --feature F041-oracle --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 0' >/dev/null 2>&1
jq -e -s 'last | .dirty == false' "$ev" >/dev/null
chk $? "a run after the commit is clean"
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "and the gate passes"

printf '\nthe red phase must be committed, and must postdate the statement:\n'
printf 'def test_more():\n    assert 0\n' > test/test_more.py
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 1' >/dev/null 2>&1
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 2 "$rc" "a red run over an uncommitted test file is refused"
contains "$out" "Commit the tests" "and told to commit first"
git add -A && git commit -q -m "more oracle"
sleep 1
"$ORCH" statement freeze F041-oracle --why "clarified R2" >/dev/null 2>&1
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 1' >/dev/null 2>&1
# The run above postdates the freeze; fake an older one by checking the
# guard against a freeze made after it.
sleep 1
"$ORCH" statement freeze F041-oracle --why "clarified R2 again" >/dev/null 2>&1
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 2 "$rc" "a red run older than the last re-freeze is refused"
contains "$out" "predates the statement" "because the tests describe the old statement"
"$ORCH" run --feature F041-oracle --label tests -- sh -c 'exit 1' >/dev/null 2>&1
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 0 "$rc" "and a fresh red run after the freeze passes"

finish floor
