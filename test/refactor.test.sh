#!/bin/bash
# refactor.test.sh - the refactor pass: mechanical trigger, frozen invariant,
# mechanical exit.
#
# What matters here (docs/AGENT-TDD.md, phase 5):
#   - the pass starts only from green, clean, oracle-as-frozen
#   - it runs in its own worktree on a fresh developer session
#   - kept only if tests green, oracle unchanged, no new hatch, diff no
#     larger than the feature's, metrics no worse; otherwise discarded and
#     the pre-refactor commit stands
#   - the trigger: always at strict; diff size or a metric at standard

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo refactor
export ORCH_LAUNCHER=print
printf 'the refactor pass\n\n'

export ORCH_FEATURE=F070-ref
"$ORCH" feature start F070-ref --request "mean" --tier strict >/dev/null 2>&1
printf 'from src.mean import mean\n\n\ndef test_mean():  # R1\n    assert mean([2, 4]) == 3\n' > test/test_mean.py
git add -A && git commit -q -m "oracle"
"$ORCH" oracle freeze F070-ref >/dev/null 2>&1
cat > src/mean.py <<'PY'
def mean(xs):
    total = 0
    for x in xs:
        total = total + x
    count = 0
    for x in xs:
        count = count + 1
    return total / count
PY
git add -A && git commit -q -m "a green, ugly implementation"
green() {  # green [repo]
  ORCH_REPO="${1:-$ORCH_REPO}" "$ORCH" run --feature F070-ref --label build -- sh -c 'exit 0' >/dev/null 2>&1
  ORCH_REPO="${1:-$ORCH_REPO}" "$ORCH" run --feature F070-ref --label tests -- sh -c 'exit 0' >/dev/null 2>&1
}
L="$ORCH_REPO/docs/features/F070-ref/ledger.jsonl"
WT="$ORCH_REPO/.orch/worktrees/F070-ref/refactor"

printf 'the pass starts from green or not at all:\n'
out="$("$ORCH" refactor start F070-ref 2>&1)"; rc=$?
chk_rc 1 "$rc" "no attested green, no pass"
contains "$out" "not attested green" "and it says so"
green
out="$("$ORCH" refactor check F070-ref 2>&1)"; rc=$?
chk_rc 0 "$rc" "at strict the trigger always fires"
contains "$out" "rung 2" "for that reason"
out="$("$ORCH" refactor start F070-ref 2>&1)"; rc=$?
chk_rc 0 "$rc" "from green, the pass starts"
[ -d "$WT" ]; chk $? "in its own worktree"
[ -r "$WT/docs/features/F070-ref/REFACTOR.md" ]; chk $? "with its orders written there"
contains "$out" "ORCH_ROLE=developer" "a developer is spawned"
contains "$out" "developer-refactor" "as a distinct session — fresh context"
contains "$out" "ORCH_PHASE=refactor" "told it is the refactor pass"
contains "$out" "cd $WT" "with its cwd in the worktree"
PRE="$(git rev-parse HEAD)"
jq -e -s --arg p "$PRE" 'any(.[]; .event=="refactor.started" and .pre_sha==$p and .pre_diff_lines > 0)' "$L" >/dev/null
chk $? "the pre-refactor sha and diff size are on the ledger"
out="$("$ORCH" refactor start F070-ref 2>&1)"; rc=$?
chk_rc 1 "$rc" "a second start while one is underway is refused"

printf '\na good pass is kept:\n'
cat > "$WT/src/mean.py" <<'PY'
def mean(xs):
    return sum(xs) / len(xs)
PY
git -C "$WT" add -A && git -C "$WT" commit -q -m "refactor: the obvious form"
out="$("$ORCH" refactor finish F070-ref 2>&1)"; rc=$?
chk_rc 1 "$rc" "not attested in the worktree, not kept"
contains "$out" "DISCARDED" "discarded"
contains "$out" "not attested green" "for the stated reason"
[ ! -d "$WT" ]; chk $? "and the worktree is gone"
[ "$(git rev-parse HEAD)" = "$PRE" ]; chk $? "and the pre-refactor commit stands"
jq -e -s 'any(.[]; .event=="refactor.discarded")' "$L" >/dev/null; chk $? "on the ledger"

"$ORCH" refactor start F070-ref >/dev/null 2>&1
cat > "$WT/src/mean.py" <<'PY'
def mean(xs):
    return sum(xs) / len(xs)
PY
git -C "$WT" add -A && git -C "$WT" commit -q -m "refactor: the obvious form"
green "$WT"
out="$("$ORCH" refactor finish F070-ref 2>&1)"; rc=$?
chk_rc 0 "$rc" "attested green in the worktree, oracle untouched, smaller: kept"
contains "$out" "KEPT" "kept"
[ "$(git rev-parse HEAD)" != "$PRE" ]; chk $? "the feature branch was fast-forwarded"
grep -q 'return sum(xs) / len(xs)' src/mean.py; chk $? "to the refactored code"
[ ! -d "$WT" ]; chk $? "and the worktree is gone"
jq -e -s 'any(.[]; .event=="refactor.kept" and .post_diff_lines <= .pre_diff_lines)' "$L" >/dev/null
chk $? "with the numbers on the ledger"

printf '\nthe exit is mechanical — each condition discards:\n'
discard_case() {  # discard_case <label> <expected reason fragment> <shell to run in worktree>
  green
  "$ORCH" refactor start F070-ref >/dev/null 2>&1
  ( cd "$WT" && eval "$3" ) >/dev/null 2>&1
  git -C "$WT" add -A && git -C "$WT" commit -q -m "refactor attempt" >/dev/null 2>&1
  green "$WT"
  out="$("$ORCH" refactor finish F070-ref 2>&1)"; rc=$?
  chk_rc 1 "$rc" "$1"
  contains "$out" "$2" "  because: $2"
  [ "$(git rev-parse HEAD)" = "$PRE2" ]; chk $? "  and the branch did not move"
}
PRE2="$(git rev-parse HEAD)"
discard_case "editing the oracle" "ORACLE_MOVED" "printf '    assert True\n' >> test/test_mean.py"
discard_case "adding an escape hatch" "escape hatch" "printf 'x = 1  # type: ignore\n' >> src/mean.py"
discard_case "a rewrite larger than the feature" "larger than the feature" "for i in \$(seq 1 40); do printf 'def f%s():\n    return %s\n\n' \$i \$i >> src/mean.py; done"
discard_case "nothing changed" "nothing changed outside docs/features" "true"

printf '\nmetrics, when attested, must be re-attested and not worse:\n'
"$ORCH" run --feature F070-ref --label complexity -- sh -c 'echo 7' >/dev/null 2>&1
green
"$ORCH" refactor start F070-ref >/dev/null 2>&1
jq -e -s '[.[] | select(.event=="refactor.started")] | last | .metrics.complexity == 7' "$L" >/dev/null
chk $? "the pre-pass complexity is recorded"
printf '# tidy\n' >> "$WT/src/mean.py"; git -C "$WT" add -A && git -C "$WT" commit -q -m "tidy"
green "$WT"
out="$("$ORCH" refactor finish F070-ref 2>&1)"; rc=$?
chk_rc 1 "$rc" "a pass that does not re-attest the metric is discarded"
contains "$out" "not after" "for that reason"
green
"$ORCH" refactor start F070-ref >/dev/null 2>&1
printf '# tidy\n' >> "$WT/src/mean.py"; git -C "$WT" add -A && git -C "$WT" commit -q -m "tidy"
green "$WT"
ORCH_REPO="$WT" "$ORCH" run --feature F070-ref --label complexity -- sh -c 'echo 9' >/dev/null 2>&1
out="$("$ORCH" refactor finish F070-ref 2>&1)"; rc=$?
chk_rc 1 "$rc" "a pass that makes the metric worse is discarded"
contains "$out" "got worse: 7 -> 9" "with both numbers"
green
"$ORCH" refactor start F070-ref >/dev/null 2>&1
printf '# tidy\n' >> "$WT/src/mean.py"; git -C "$WT" add -A && git -C "$WT" commit -q -m "tidy"
green "$WT"
ORCH_REPO="$WT" "$ORCH" run --feature F070-ref --label complexity -- sh -c 'echo 5' >/dev/null 2>&1
out="$("$ORCH" refactor finish F070-ref 2>&1)"; rc=$?
chk_rc 0 "$rc" "a pass that improves it is kept"
jq -e -s '[.[] | select(.event=="refactor.kept")] | last | .metrics_before.complexity == 7 and .metrics_after.complexity == 5' "$L" >/dev/null
chk $? "with before and after on the ledger"

printf '\nthe trigger at standard:\n'
export ORCH_FEATURE=F071-std
"$ORCH" feature start F071-std --request "small" --tier standard >/dev/null 2>&1
printf 'x = 1\n' > src/small.py && git add -A && git commit -q -m "small"
out="$("$ORCH" refactor check F071-std 2>&1)"; rc=$?
chk_rc 1 "$rc" "a small standard-tier diff does not trigger"
contains "$out" "no trigger fired" "and says so"
jq -e -s 'any(.[]; .event=="refactor.skipped")' docs/features/F071-std/ledger.jsonl >/dev/null; chk $? "recorded as skipped"
out="$(ORCH_T_REFACTOR_LINES=0 "$ORCH" refactor check F071-std 2>&1)"; rc=$?
chk_rc 0 "$rc" "over the diff-size threshold it does"
"$ORCH" run --feature F071-std --label duplication -- sh -c 'echo 12' >/dev/null 2>&1
out="$(ORCH_T_DUPLICATION=10 "$ORCH" refactor check F071-std 2>&1)"; rc=$?
chk_rc 0 "$rc" "so does an attested duplication over its threshold"
contains "$out" "duplication 12 > 10" "naming the number"
out="$(ORCH_REFACTOR=never "$ORCH" refactor check F071-std 2>&1)"; rc=$?
chk_rc 1 "$rc" "and ORCH_REFACTOR=never switches it off"

finish refactor
