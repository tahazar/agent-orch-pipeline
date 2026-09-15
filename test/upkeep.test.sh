#!/bin/bash
# upkeep.test.sh - layers, and the upkeep layer.
#
# What matters here:
#   - a repo names its layers; a command from a layer that is off refuses
#     with one line; floor is always on; the default is floor and crew
#   - the census is mechanical and ranked: escape hatches and stale tests
#     weigh most; test files and non-source are not candidates
#   - plan turns the top files into features with requests written from
#     the numbers; night starts one refactor pass per file, each in its own
#     worktree with its own session, landing on a branch, not on HEAD
#   - morning shows what held; keep merges into the base; discard archives

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo upkeep
export ORCH_LAUNCHER=print
printf 'layers and upkeep\n\n'

printf 'layers:\n'
out="$("$ORCH" layers 2>&1)"
contains "$out" "layers on: floor crew" "the default is floor and crew"
out="$("$ORCH" upkeep scan 2>&1)"; rc=$?
chk_rc 1 "$rc" "an upkeep command refuses while the layer is off"
contains "$out" "layer is off" "and says so"
contains "$out" "orch init --profile service" "and names the profile that turns it on"
"$ORCH" init --profile service >/dev/null 2>&1
[ "$(jq -r '.layers | join(" ")' .claude/orch.json)" = "floor crew upkeep" ]; chk $? "init --profile service writes the layers file"
out="$("$ORCH" layers 2>&1)"; contains "$out" "floor crew upkeep" "and layers reports them"
printf '{"layers": ["upkeep"]}\n' > .claude/orch.json
out="$("$ORCH" layers 2>&1)"; contains "$out" "layers on: floor upkeep" "floor is always on, whatever the file says"
out="$("$ORCH" team status 2>&1)"; rc=$?
chk_rc 1 "$rc" "with crew off, a crew command refuses"
"$ORCH" init --profile service >/dev/null 2>&1
git add -A && git commit -q -m "layers"

printf '\nthe census:\n'
mkdir -p src
cat > src/hairy.py <<'PY'
import pytest  # noqa
def a():
    return 1  # type: ignore
def b():
    return 2  # type: ignore
# TODO: split this up
PY
printf 'def tidy():\n    return 1\n' > src/tidy.py
printf 'from src.tidy import tidy\n\n\ndef test_tidy():\n    assert tidy() == 1\n' > test/test_tidy.py
printf 'from src.hairy import a\n\n\ndef test_hairy():\n    assert a() == 1\n' > test/test_hairy.py
git add -A && git commit -q -m "two modules"
sleep 1
printf 'def c():\n    return 3\n' >> src/hairy.py
git add -A && git commit -q -m "hairy changes without its test"
out="$("$ORCH" upkeep scan --top 5 2>/dev/null)"; rc=$?
chk_rc 0 "$rc" "the scan runs"
first="$(printf '%s' "$out" | head -1)"
contains "$first" "src/hairy.py" "the file with hatches, a stale test and a TODO ranks first"
contains "$first" "3 hatch(es)" "counting its escape hatches"
contains "$first" "tests older than source" "and the stale test"
contains "$first" "1 TODO" "and the TODO"
not_contains "$out" "test_hairy" "test files are not candidates"
not_contains "$out" "README" "nor is prose"
jq -e -s 'any(.[]; .event=="upkeep.scanned")' docs/features/_orch/ledger.jsonl >/dev/null; chk $? "the scan is on the run ledger"
"$ORCH" run --feature _orch --label upkeep-metrics -- sh -c 'echo "40 src/tidy.py"; echo "5 src/hairy.py"' >/dev/null 2>&1
out="$("$ORCH" upkeep scan --top 5 2>&1)"
contains "$(printf '%s' "$out" | grep tidy)" "metric 40" "an attested per-file metric is read into the census"

printf '\nplan writes features from the numbers:\n'
out="$("$ORCH" upkeep plan --top 1 2>&1)"; rc=$?
chk_rc 0 "$rc" "plan runs"
id="$(printf '%s' "$out" | awk '{print $1}' | head -1)"
case "$id" in F9*-upkeep-src-hairy*) ok "the feature is $id — an F9xx upkeep id named for the file" ;; *) bad "unexpected feature id '$id'" ;; esac
contains "$(cat "$(fdir $id)/request.md")" "3 escape hatch(es)" "the request carries the census"
contains "$(cat "$(fdir $id)/request.md")" "R3 no new skip" "and requirement ids"
[ "$("$ORCH" tier show $id | jq -r .running)" = standard ]; chk $? "at the upkeep tier"

printf '\nnight starts one pass per file, landing on branches:\n'
out="$(ORCH_TEST_CMD='exit 0' "$ORCH" upkeep night --top 2 2>&1)"; rc=$?
chk_rc 0 "$rc" "night runs"
[ "$("$ORCH" upkeep morning | grep -c "F9")" = "2" ]; chk $? "the file planned earlier is not planned again — two features, not three"
n_started="$(printf '%s' "$out" | grep -c 'refactor pass for .* started')"
[ "$n_started" = "2" ]; chk $? "two passes started (got $n_started)"
n_sess="$(printf '%s' "$out" | grep -c 'ORCH_ROLE=developer')"
[ "$n_sess" = "2" ]; chk $? "two developer sessions"
[ "$(printf '%s' "$out" | grep -o 'developer-refactor-F9[0-9]*-[a-z-]*' | sort -u | wc -l | tr -d ' ')" = "2" ]; chk $? "with distinct names"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ]; chk $? "the checkout is left where it was"
ids="$(ls -d .orch/worktrees/F9*-upkeep-* | xargs -n1 basename)"
for i in $ids; do [ -d "$(sub_wt $i refactor)" ]; chk $? "$i has its worktree"; done

printf '\nmorning, keep, discard:\n'
first_id="$(printf '%s\n' $ids | head -1)"; second_id="$(printf '%s\n' $ids | tail -1)"
WT="$(sub_wt $first_id refactor)"
f="$(jq -r -s '[.[] | select(.event=="upkeep.planned")] | last | .file' "$(fdir $first_id)/ledger.jsonl")"
printf 'def a():\n    return 1\n' > "$WT/$f"
git -C "$WT" add -A && git -C "$WT" commit -q -m "upkeep: simplify"
ORCH_REPO="$WT" "$ORCH" run --feature "$first_id" --label build -- sh -c 'exit 0' >/dev/null 2>&1
ORCH_REPO="$WT" "$ORCH" run --feature "$first_id" --label tests -- sh -c 'exit 0' >/dev/null 2>&1
HEAD0="$(git rev-parse HEAD)"
out="$("$ORCH" refactor finish "$first_id" 2>&1)"; rc=$?
chk_rc 0 "$rc" "a good pass is kept"
contains "$out" "on branch orch/$first_id/kept" "on its own branch"
[ "$(git rev-parse HEAD)" = "$HEAD0" ]; chk $? "and HEAD did not move"
git rev-parse --verify --quiet "orch/$first_id/kept" >/dev/null; chk $? "the branch exists"
out="$("$ORCH" upkeep morning 2>&1)"
contains "$out" "KEPT      $first_id" "morning lists the kept pass"
contains "$out" "OPEN      $second_id" "and the one still open"
contains "$out" "orch upkeep keep $first_id" "with the verbs"
out="$("$ORCH" upkeep keep "$first_id" 2>&1)"; rc=$?
chk_rc 0 "$rc" "keep merges it"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ]; chk $? "into main"
grep -q 'return 1' "src/hairy.py" && ! grep -q 'type: ignore' src/hairy.py; chk $? "and the simplified file is on main"
jq -e -s 'any(.[]; .event=="upkeep.kept")' "$(fdir $first_id)/ledger.jsonl" >/dev/null; chk $? "recorded"
out="$("$ORCH" upkeep discard "$second_id" --why "not worth it" 2>&1)"; rc=$?
chk_rc 0 "$rc" "discard records the decision"
jq -e -s 'any(.[]; .event=="upkeep.discarded" and .why=="not worth it")' "$(fdir $second_id)/ledger.jsonl" >/dev/null; chk $? "with the reason"
out="$("$ORCH" upkeep morning 2>&1)"
contains "$out" "done      $first_id  kept" "morning now shows both as done"
contains "$out" "done      $second_id  discarded" ""

finish upkeep
