#!/bin/bash
# sensors.test.sh - diff coverage and mutation score as attested readings.
#
# What matters here (docs/AGENT-TDD.md, phase 4):
#   - diff coverage counts only the executable lines the diff touched, in
#     production code, and lists uncovered lines and unmeasured files
#   - a reading needs an attested run at the same sha, or it is a number
#     somebody typed
#   - mutation score reads Stryker and cargo-mutants reports restricted to
#     changed files, or the last number an attested run printed
#   - a sensor is a report line until its threshold is set, and a gate after

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo sensors
printf 'sensors\n\n'

hook() { printf '%s' "$2" | "$ORCH_ROOT/hooks/$1"; }
export ORCH_FEATURE=F060-sens
"$ORCH" feature start F060-sens --request "mean" --tier standard >/dev/null 2>&1
# Tool output is not source. A repo that commits its coverage report has a
# different problem; this one ignores it, as real ones do.
printf 'coverage/\nreports/\nmutants.out/\n' > .gitignore
git add -A && git commit -q -m "ignore tool output"

# The diff: four executable lines in src/mean.py, one changed line in a test.
cat > src/mean.py <<'PY'
def mean(xs):
    if not xs:
        raise ValueError("empty")
    total = sum(xs)
    return total / len(xs)
PY
printf '# a test change, not production\n' >> test/test_calc.py
git add -A && git commit -q -m "mean"
SHA="$(git rev-parse HEAD)"

printf 'diff coverage from an lcov report:\n'
mkdir -p coverage
cat > coverage/lcov.info <<LCOV
SF:$ORCH_REPO/src/mean.py
DA:1,1
DA:2,1
DA:3,0
DA:4,1
DA:5,1
end_of_record
SF:src/calc.py
DA:1,1
DA:2,1
end_of_record
LCOV
out="$("$ORCH" sensor coverage F060-sens 2>&1)"; rc=$?
chk_rc 1 "$rc" "a reading with no attested coverage run is refused"
contains "$out" "no attested" "and says what is missing"

"$ORCH" run --feature F060-sens --label coverage -- sh -c 'exit 0' >/dev/null 2>&1
out="$("$ORCH" sensor coverage F060-sens 2>&1)"; rc=$?
chk_rc 0 "$rc" "with an attested run at this sha, the reading is taken"
contains "$out" "80% of 5 changed executable lines" "4 of the 5 executable diff lines ran (the raise did not)"
contains "$out" "uncovered: src/mean.py:3" "and the uncovered line is named"
not_contains "$out" "test_calc" "the test file's change is not production code"
L="$ORCH_REPO/docs/features/F060-sens/ledger.jsonl"
jq -e -s --arg s "$SHA" 'any(.[]; .event=="sensor.diff_coverage" and .pct==80 and .at_sha==$s)' "$L" >/dev/null
chk $? "and it is on the ledger at the sha it describes"

printf 'def helper():\n    return 1\n' > src/helper.py
git add -A && git commit -q -m "an unmeasured module"
"$ORCH" run --feature F060-sens --label coverage -- sh -c 'exit 0' >/dev/null 2>&1
out="$("$ORCH" sensor coverage F060-sens 2>&1)"
contains "$out" "unmeasured (no test imported them): src/helper.py" "a changed file the report never saw is unmeasured, not silently uncovered"
contains "$out" "80% of 5" "and does not distort the percentage"

printf '\nthe gate follows the threshold:\n'
"$ORCH" run --feature F060-sens --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F060-sens --label tests -- sh -c 'exit 0' >/dev/null 2>&1
GREEN='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: implement","metadata":{"orch":{"feature":"F060-sens","requires":"tests-pass"}}}}'
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "with no threshold set, coverage is a report line and the gate passes"
out="$(ORCH_T_DIFF_COV=100 hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 2 "$rc" "with ORCH_T_DIFF_COV=100, 80% blocks"
contains "$out" "SENSOR_BELOW" "and names the failure"
contains "$out" "src/mean.py:3" "and the line to cover"
git rm -q src/helper.py && git commit -q -m "drop the unmeasured module"
"$ORCH" run --feature F060-sens --label coverage -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" sensor coverage F060-sens >/dev/null 2>&1
"$ORCH" run --feature F060-sens --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F060-sens --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$(ORCH_T_DIFF_COV=70 hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "with ORCH_T_DIFF_COV=70, 80% passes"
git commit -q --allow-empty -m "branch moves"
"$ORCH" run --feature F060-sens --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F060-sens --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$(ORCH_T_DIFF_COV=70 hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 2 "$rc" "a reading at an older sha is no reading"
contains "$out" "SENSOR_MISSING" "and says so"

printf '\nmutation score from a Stryker report:\n'
mkdir -p reports/mutation
cat > reports/mutation/mutation.json <<'JSON'
{"files": {
  "src/mean.py": {"mutants": [{"status":"Killed"},{"status":"Killed"},{"status":"Survived"},{"status":"Timeout"},{"status":"NoCoverage"}]},
  "src/other.py": {"mutants": [{"status":"Survived"},{"status":"Survived"},{"status":"Survived"}]}
}}
JSON
out="$("$ORCH" sensor mutation F060-sens 2>&1)"; rc=$?
chk_rc 0 "$rc" "the report is read"
contains "$out" "60% (stryker, scope changed, 3/5 killed)" "restricted to the changed file: 3 killed of 5"
jq -e -s 'any(.[]; .event=="sensor.mutation" and .pct==60 and .scope=="changed")' "$L" >/dev/null
chk $? "and on the ledger"

printf '\nmutation score from a cargo-mutants report:\n'
mkdir -p mutants.out
cat > mutants.out/outcomes.json <<'JSON'
{"outcomes": [
  {"scenario": {"Mutant": {"file": "src/mean.py"}}, "summary": "CaughtMutant"},
  {"scenario": {"Mutant": {"file": "src/mean.py"}}, "summary": "MissedMutant"},
  {"scenario": {"Mutant": {"file": "src/mean.py"}}, "summary": "Unviable"},
  {"scenario": "Baseline", "summary": "Success"}
]}
JSON
out="$("$ORCH" sensor mutation F060-sens --from cargo-mutants 2>&1)"; rc=$?
chk_rc 0 "$rc" "the report is read"
contains "$out" "50% (cargo-mutants, scope changed, 1/2 killed)" "unviable mutants do not count either way"

printf '\nmutation score from an attested run:\n'
out="$("$ORCH" sensor mutation F060-sens --from evidence 2>&1)"; rc=$?
chk_rc 1 "$rc" "no attested mutation run, no reading"
"$ORCH" run --feature F060-sens --label mutation -- sh -c 'echo "12 mutants"; echo "The mutation score is 0.75"' >/dev/null 2>&1
out="$("$ORCH" sensor mutation F060-sens --from evidence 2>&1)"; rc=$?
chk_rc 0 "$rc" "the last number the run printed is the score"
contains "$out" "75% (evidence" "a fraction is read as a percentage"

printf '\nthe mutation gate:\n'
"$ORCH" run --feature F060-sens --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F060-sens --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$(ORCH_T_MUTATION=80 hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 2 "$rc" "75% is below an 80% threshold"
contains "$out" "does not notice when it is wrong" "and the message says what a low score means"
out="$(ORCH_T_MUTATION=70 hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "and above a 70% one"

printf '\nthe report shows the readings:\n'
out="$("$ORCH" report F060-sens 2>&1)"
contains "$out" "diff coverage 80% of 5 lines" "coverage"
contains "$out" "mutation 75% (all)" "and mutation, latest reading"

finish sensors
