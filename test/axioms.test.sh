#!/bin/bash
# axioms.test.sh - the enumerated escape hatches, and requirement coverage.
#
# What matters here (docs/VERIFICATION.md, gaps 3 and 6):
#   - a new skip/ignore/disable in the diff is a blocking finding raised by
#     `axioms`, and the green gate holds until it is fixed or disputed
#   - a change to trusted configuration is one too
#   - a requirement id no oracle test cites blocks the red phase at strict
#   - the check is over the diff against the base, so pre-existing hatches
#     are not the developer's

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo axioms
printf 'escape hatches and coverage\n\n'

hook() { printf '%s' "$2" | "$ORCH_ROOT/hooks/$1"; }

# A pre-existing hatch on main is not the feature's.
printf 'import pytest\n\n\n@pytest.mark.skip\ndef test_old():\n    assert 0\n' > test/test_old.py
git add -A && git commit -q -m "a pre-existing skip"

printf 'escape hatches are counted against the base:\n'
export ORCH_FEATURE=F050-ax
"$ORCH" feature start F050-ax --request "mean" --tier strict >/dev/null 2>&1
out="$("$ORCH" axioms F050-ax 2>&1)"; rc=$?
chk_rc 0 "$rc" "a feature that changed nothing has no new hatches"
contains "$out" "no new escape hatches" "and says so"

printf 'def mean(xs):\n    return sum(xs) / len(xs)\n' > src/mean.py
git add -A && git commit -q -m "mean"
out="$("$ORCH" axioms F050-ax 2>&1)"; rc=$?
chk_rc 0 "$rc" "a clean implementation has none"

printf '    assert True\n' >> test/test_calc.py
printf 'import pytest\n\n\n@pytest.mark.skip\ndef test_new():\n    assert 0\n' > test/test_new.py
printf 'x = 1  # type: ignore\n' >> src/mean.py
git add -A && git commit -q -m "developer reaches for the hatches"
out="$("$ORCH" axioms F050-ax 2>&1)"; rc=$?
chk_rc 1 "$rc" "three new hatches are found"
contains "$out" "test/test_new.py:4" "the skip, with its line"
contains "$out" "pytest" "and its pattern"
contains "$out" "src/mean.py" "the type: ignore"
contains "$out" "test/test_calc.py" "the assert True"
not_contains "$out" "test_old.py" "the pre-existing skip on main is not counted"

printf '\nthe green gate holds on an open axioms finding:\n'
"$ORCH" run --feature F050-ax --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F050-ax --label tests -- sh -c 'exit 0' >/dev/null 2>&1
GREEN='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: implement","metadata":{"orch":{"feature":"F050-ax","requires":"tests-pass"}}}}'
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 2 "$rc" "blocked"
contains "$out" "escape hatch" "for the stated reason"
contains "$out" "orch findings dispute" "with the remedy"
n="$("$ORCH" findings list F050-ax | jq -s '[.[] | select(.raised_by=="axioms" and .severity=="blocking")] | length')"
[ "$n" = "3" ]; chk $? "three blocking findings raised by axioms (got $n)"
out="$(hook task-guard.sh "$GREEN" 2>&1)"
n="$("$ORCH" findings list F050-ax | jq -s '[.[] | select(.raised_by=="axioms")] | length')"
[ "$n" = "3" ]; chk $? "running the guard again raises no duplicates (still $n)"

for id in $("$ORCH" findings list F050-ax | jq -r 'select(.raised_by=="axioms") | .id'); do
  "$ORCH" findings dispute F050-ax "$id" --reason "test fixture" >/dev/null 2>&1
done
out="$(hook task-guard.sh "$GREEN" 2>&1)"; rc=$?
chk_rc 0 "$rc" "disputed findings do not hold the gate — a dispute is a claim the auditor can test"

printf '\ntrusted configuration is an axiom:\n'
mkdir -p .github/workflows && printf 'name: ci\n' > .github/workflows/ci.yml
git add -A && git commit -q -m "developer edits CI"
out="$("$ORCH" axioms F050-ax 2>&1)"; rc=$?
chk_rc 1 "$rc" "a CI change is flagged"
contains "$out" "CONFIG   .github/workflows/ci.yml" "by path"

printf '\nrequirement coverage at the red phase:\n'
export ORCH_FEATURE=F051-cov
"$ORCH" feature start F051-cov --request "mean" >/dev/null 2>&1
printf -- '- R1 mean of a non-empty list\n- **R2** empty list raises ValueError\n3. R3 accepts ints and floats\n' \
  > docs/features/F051-cov/requirements.md
"$ORCH" tier recommend F051-cov strict --why "logic" >/dev/null 2>&1
"$ORCH" tier confirm F051-cov >/dev/null 2>&1
printf 'def test_mean_r1():\n    """R1"""\n    assert 1\n\n\ndef test_empty():  # R2\n    assert 1\n' > test/test_mean.py
git add -A && git commit -q -m "oracle: R1, R2"
out="$("$ORCH" spec coverage F051-cov 2>&1)"; rc=$?
chk_rc 1 "$rc" "one requirement is uncovered"
contains "$out" "R1  test/test_mean.py" "R1 is cited"
contains "$out" "R2  test/test_mean.py" "R2 is cited, bold or not"
contains "$out" "R3  UNCOVERED" "R3 is not"

"$ORCH" run --feature F051-cov --label tests -- sh -c 'exit 1' >/dev/null 2>&1
RED='{"hook_event_name":"TaskCompleted","task":{"subject":"test-engineer: red phase","metadata":{"orch":{"feature":"F051-cov","requires":"tests-fail-correctly"}}}}'
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 2 "$rc" "the red phase is blocked while R3 is cited by nothing"
contains "$out" "R3" "and names it"
contains "$out" "requirements.md:3" "at its line in requirements.md"
jq -e -s 'any(.[]; .raised_by=="coverage" and .severity=="blocking")' docs/features/F051-cov/findings.jsonl >/dev/null
chk $? "as a blocking finding raised by coverage"
jq -e -s 'any(.[]; .event=="oracle.frozen")' docs/features/F051-cov/ledger.jsonl >/dev/null; rc=$?
[ "$rc" != "0" ]; chk $? "and the oracle is not frozen with a hole in it"

printf '\n\ndef test_types():\n    """R3"""\n    assert 1\n' >> test/test_mean.py
git add -A && git commit -q -m "oracle: R3"
"$ORCH" run --feature F051-cov --label tests -- sh -c 'exit 1' >/dev/null 2>&1
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 0 "$rc" "with R3 cited, the red phase passes"
jq -e -s 'any(.[]; .event=="oracle.frozen")' docs/features/F051-cov/ledger.jsonl >/dev/null
chk $? "and the oracle is frozen"

printf '\nrequirements without ids cannot be checked, and say so:\n'
export ORCH_FEATURE=F052-noid
"$ORCH" feature start F052-noid --request "mean" >/dev/null 2>&1
printf 'the mean of a list\n' > docs/features/F052-noid/requirements.md
"$ORCH" tier recommend F052-noid strict --why "x" >/dev/null 2>&1
"$ORCH" tier confirm F052-noid >/dev/null 2>&1
git add -A && git commit -q -m "no ids"
out="$("$ORCH" spec coverage F052-noid 2>&1)"; rc=$?
chk_rc 0 "$rc" "coverage of nothing is not a failure"
contains "$out" "defines no requirement ids" "but it is said"
"$ORCH" run --feature F052-noid --label tests -- sh -c 'exit 1' >/dev/null 2>&1
RED='{"hook_event_name":"TaskCompleted","task":{"subject":"test-engineer: red phase","metadata":{"orch":{"feature":"F052-noid","requires":"tests-fail-correctly"}}}}'
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the red phase is not blocked"
jq -e -s 'any(.[]; .event=="spec.unchecked")' docs/features/F052-noid/ledger.jsonl >/dev/null
chk $? "and the ledger records that coverage went unchecked"

finish axioms
