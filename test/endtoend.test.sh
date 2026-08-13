#!/bin/bash
# endtoend.test.sh - build-order step 5: rung 0 solo, end to end.
#
# Acceptance (spec §14.5): a real feature merges with gates enforced and full
# ledger coverage. This is also the ablation baseline — rung 0 is what every
# other rung has to beat.
#
# There is no model in this test. A stub "developer" edits the file; every gate,
# every attestation and every block is the real code path. What this proves is
# that the protocol holds and that a feature cannot reach the base branch
# without passing through it — not that an LLM follows the prompts.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo e2e
printf 'rung 0, end to end\n\n'

# guard <hook> <json> -> sets GOUT and RC.
#
# Deliberately NOT `out="$(guard ...)"`: that runs the function in a subshell,
# so its `RC=$?` never reaches the caller and every exit-code assertion silently
# compares a stale value. Setting both as globals is the version that works.
guard() {
  GOUT="$(printf '%s' "$2" | "$ORCH_ROOT/hooks/$1" 2>&1)"; RC=$?
}

# The artifacts orch writes are real files in the tree. A director commits them
# as part of the stage; the test does the same, so branch switches later on are
# not fighting a dirty worktree.
commit_artifacts() {
  git add -A >/dev/null 2>&1
  git diff --cached --quiet || git commit -q -m "orch: ${1:-artifacts}"
}
MERGE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git merge --squash feature/F001"}}'
TASK_BUILD='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: implement F001","metadata":{"orch":{"feature":"F001-mean","requires":"tests-pass"}}}}'
TASK_REVIEW='{"hook_event_name":"TaskCompleted","task":{"subject":"review F001","metadata":{"orch":{"feature":"F001-mean","requires":"review-clean"}}}}'

printf '__pycache__/\n*.pyc\n' > .gitignore

# A test command the fixture can actually run: mean() of an empty list must not
# raise, which the seeded implementation does.
cat > runtests.sh <<'EOF'
#!/bin/sh
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from src.calc import mean
try:
    assert mean([1, 2, 3]) == 2
    assert mean([]) == 0
except Exception as e:
    print("FAIL:", e); sys.exit(1)
print("ok")
PY
EOF
chmod +x runtests.sh
git add -A && git commit -q -m "add the test runner"

export ORCH_FEATURE=F001-mean

printf 'plan:\n'
"$ORCH" feature start F001-mean >/dev/null 2>&1
chk $? "the feature starts"
[ "$("$ORCH" escalate rung F001-mean)" = "0" ]; chk $? "at rung 0 — the default, and where most features should end"
mkdir -p docs/features/F001-mean
cat > docs/features/F001-mean/requirements.md <<'EOF'
# F001-mean
1. mean([1,2,3]) == 2
2. mean([]) == 0, and does not raise
EOF
git add -A && git commit -q -m "requirements"

printf '\nred phase:\n'
git checkout -q -b feature/F001
"$ORCH" run --feature F001-mean --label tests -- ./runtests.sh >/dev/null 2>&1
RC=$?
[ "$RC" != "0" ]; chk $? "the tests fail before the implementation exists"
guard task-guard.sh '{"hook_event_name":"TaskCompleted","task":{"subject":"test-engineer: red phase","metadata":{"orch":{"feature":"F001-mean","requires":"tests-fail-correctly"}}}}' >/dev/null
chk_rc 0 "$RC" "and the red phase is therefore attested"

printf '\nno merge before anything else:\n'
guard gate-guard.sh "$MERGE"
chk_rc 2 "$RC" "a merge attempt here is blocked"

printf '\nbuild:\n'
guard task-guard.sh "$TASK_BUILD" >/dev/null
chk_rc 2 "$RC" "the developer cannot mark its task done while the oracle is red"

# The stub developer does the work.
cat > src/calc.py <<'EOF'
def add(a, b):
    return a + b


def mean(xs):
    if not xs:
        return 0
    return sum(xs) / len(xs)
EOF
git add -A && git commit -q -m "F001: mean() handles the empty list"

"$ORCH" run --feature F001-mean --label build -- sh -c 'python3 -m compileall -q src' >/dev/null 2>&1
chk $? "build is attested green"
"$ORCH" run --feature F001-mean --label tests -- ./runtests.sh >/dev/null 2>&1
chk $? "tests are attested green"
guard task-guard.sh "$TASK_BUILD" >/dev/null
chk_rc 0 "$RC" "the developer's task now completes"

printf '\nreview:\n'
fid="$("$ORCH" findings add F001-mean --raised-by correctness --severity blocking \
        --file src/calc.py --line 6 --claim "mean([]) returns 0, but the requirement does not say 0 is meaningful" \
        --consequence "a caller cannot distinguish an empty input from a genuine mean of 0")"
guard task-guard.sh "$TASK_REVIEW" >/dev/null
chk_rc 2 "$RC" "review cannot be marked clean with a blocking finding open"
guard gate-guard.sh "$MERGE"
chk_rc 2 "$RC" "and the merge is still blocked"

out="$("$ORCH" findings deliver F001-mean)"
contains "$out" "cannot distinguish an empty input" "the finding reaches the developer verbatim"

"$ORCH" findings dispute F001-mean "$fid" --reason "requirement 2 states 0 explicitly; raising a defect against the spec is out of scope for this feature" >/dev/null 2>&1
guard task-guard.sh "$TASK_REVIEW" >/dev/null
chk_rc 0 "$RC" "a disputed finding — with a reason — unblocks review"

printf '\napproval:\n'
guard gate-guard.sh "$MERGE"
chk_rc 2 "$RC" "still no merge without a human"
"$ORCH" approve F001-mean --gate human >/dev/null 2>&1
guard gate-guard.sh "$MERGE"
chk_rc 0 "$RC" "the merge is allowed once a human approves at this sha"

printf '\nthe merge:\n'
commit_artifacts "F001 evidence and findings"
sha="$(git rev-parse HEAD)"
git checkout -q main
git merge -q --squash feature/F001 && git commit -q -m "F001: mean() handles the empty list"
chk $? "the reviewed sha squash-merges to main"
./runtests.sh >/dev/null 2>&1
chk $? "and main is green afterwards"

# The approval was scoped to a sha. Anything after it needs a new one.
git checkout -q feature/F001
printf '# drive-by\n' >> src/calc.py && git add -A && git commit -q -m "unrelated change"
guard gate-guard.sh "$MERGE"
chk_rc 2 "$RC" "a change after approval needs a new approval"

printf '\nledger coverage:\n'
L="docs/features/F001-mean/ledger.jsonl"
commit_artifacts "post-merge ledger"
git checkout -q main
[ -s "$L" ]; chk $? "the ledger exists"
for e in feature.started run.attested gate.checked gate.blocked gate.set finding.raised finding.status; do
  jq -e -s --arg e "$e" 'any(.[]; .event==$e)' "$L" >/dev/null
  chk $? "$e is recorded"
done
n_blocked="$(jq -s '[.[] | select(.event=="gate.blocked")] | length' "$L")"
[ "$n_blocked" -ge 5 ]; chk $? "$n_blocked gate blocks were recorded — the gates did work, and it is provable"
jq -e -s 'all(.[]; has("ts") and has("actor") and has("feature") and has("sha"))' "$L" >/dev/null
chk $? "every ledger row carries ts, actor, feature and sha"

printf '\nno guessed numbers anywhere:\n'
# The whole reason for the ledger. The alternative is agents typing
# "~13k (est.)" at each other. Nothing in the artifacts may contain an estimate.
if grep -rn 'est\.\|~[0-9]*k tokens\|approximately [0-9]* tokens' docs/features/ 2>/dev/null; then
  bad "an estimated number leaked into the artifacts"
else
  ok "no estimated token counts anywhere in docs/features/"
fi

out="$("$ORCH" report F001-mean 2>&1)"
contains "$out" "F001-mean" "the report renders the completed feature"
contains "$out" "0·solo" "at rung 0 — the ablation baseline every other rung has to beat"

finish endtoend
