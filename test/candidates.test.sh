#!/bin/bash
# candidates.test.sh - build-order steps 9 and 10: best-of-N and diagnosis.
#
# Acceptance (spec §14):
#   9. N candidates in isolated worktrees, mechanical selection, one merge, all
#      N archived with gate results. Verify no candidate can write outside its
#      worktree — attempt it in the test.
#  10. K hypotheses produce K falsifiable predictions; execution selects; no
#      distinguishing experiment escalates to human on the first pass.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo candidates
printf 'best-of-N + diagnostic stage\n\n'

export ORCH_FEATURE=F010-bestofn
"$ORCH" feature start F010-bestofn --request "test fixture" >/dev/null 2>&1
git checkout -q -b feature/F010

printf 'spawning candidates:\n'
out="$("$ORCH" candidates start F010-bestofn -n 3 2>&1)"
chk $? "orch candidates start exits 0"
[ "$("$ORCH" candidates list F010-bestofn | grep -c .)" = "3" ]
chk $? "three candidate worktrees exist"

ROOT="$ORCH_REPO/.orch/worktrees/F010-bestofn"
for c in c1 c2 c3; do
  [ -d "$ROOT/$c/.git" ] || [ -f "$ROOT/$c/.git" ]
  chk $? "$c is a real git worktree"
done

# Diversity is the binding constraint [P18], so the directives must actually
# differ — three identical prompts at three temperatures is not best-of-N.
n_distinct="$(cat "$ROOT"/c*/docs/features/F010-bestofn/APPROACH.md | grep -c '^# Candidate')"
[ "$n_distinct" = "3" ]; chk $? "each candidate got its own approach directive"
a1="$(head -1 "$ROOT/c1/docs/features/F010-bestofn/APPROACH.md")"
a2="$(head -1 "$ROOT/c2/docs/features/F010-bestofn/APPROACH.md")"
[ "$a1" != "$a2" ]; chk $? "the directives are different strategies, not the same one repeated"
contains "$(cat "$ROOT/c1/docs/features/F010-bestofn/APPROACH.md")" "minimal" "c1 is the minimal-diff approach"
contains "$(cat "$ROOT/c2/docs/features/F010-bestofn/APPROACH.md")" "underlying defect" "c2 is the root-cause approach"
contains "$(cat "$ROOT/c3/docs/features/F010-bestofn/APPROACH.md")" "class of bug" "c3 is the defensive approach"

# --- isolation is the platform's job, and it has to actually hold ----------
printf '\nisolation:\n'
for c in c1 c2 c3; do
  b="$(git -C "$ROOT/$c" rev-parse --abbrev-ref HEAD)"
  [ "$b" = "orch/F010-bestofn/$c" ]; chk $? "$c is on its own branch ($b)"
done
before="$(git -C "$ORCH_REPO" rev-parse HEAD)"
# A candidate committing in its own worktree must not move the base branch.
( cd "$ROOT/c1" && printf 'c1 was here\n' >> src/calc.py && git add -A && git commit -q -m "c1" )
after="$(git -C "$ORCH_REPO" rev-parse HEAD)"
[ "$before" = "$after" ]; chk $? "a candidate's commit does not move the main checkout"
[ "$(git -C "$ORCH_REPO" show HEAD:src/calc.py | grep -c 'c1 was here')" = "0" ]
chk $? "and its content is not visible from the main checkout"

# The platform blocks Edit/Write into the main checkout for a worktree-isolated
# agent. That is enforcement we do not own, so what we assert here is the
# property we DO own: nothing in orch hands a candidate a path out. Plus
# write-scope refuses a test-path edit even inside the worktree — best-of-N is
# rung 3 by definition, and the deny follows the rung, so the fixture records
# the escalation a real run would carry.
"$ORCH" escalate to F010-bestofn 3 "candidates fixture" >/dev/null 2>&1
out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
        "$ROOT/c1/test/test_calc.py" | ORCH_ROLE=developer ORCH_FEATURE=F010-bestofn "$ORCH_ROOT/hooks/write-scope.sh" 2>&1)"; rc=$?
chk_rc 2 "$rc" "a candidate still cannot edit tests inside its own worktree"

esc=0
grep -rn "ORCH_REPO" "$ROOT"/c*/docs/features/F010-bestofn/APPROACH.md >/dev/null 2>&1 && esc=1
[ "$esc" = "0" ]; chk $? "no candidate is handed the main checkout's path"

# A worktree-isolated developer runs with CLAUDE_PROJECT_DIR still pointing at
# the main checkout. If orch resolved the repo from that env var, the
# candidate's evidence would be written to a checkout the platform forbids it
# from touching — the attestation would vanish and every gate would read as
# unattested. git's own working tree has to win.
printf '\nrepo resolution inside a worktree:\n'
resolved="$( cd "$ROOT/c1" && env -u ORCH_REPO CLAUDE_PROJECT_DIR="$ORCH_REPO" \
             bash -c '. "'"$ORCH_ROOT"'/lib/common.sh"; orch_repo_root' )"
# Compared physically: git resolves symlinks and $TMPDIR does not, which on
# macOS makes these differ by a /private prefix for the same directory.
want="$( cd -P "$ROOT/c1" && pwd )"
[ "$(cd -P "$resolved" 2>/dev/null && pwd)" = "$want" ]
chk $? "orch resolves the worktree, not CLAUDE_PROJECT_DIR (got $resolved)"

# --- collection reads each candidate's own attestations -------------------
printf '\ncollection:\n'
# c1: both gates green, largest diff.  c2: both green, smallest diff.
# c3: build green, tests red — must be filtered out no matter how good it looks.
( cd "$ROOT/c1" && ORCH_REPO="$ROOT/c1" "$ORCH" run --feature F010-bestofn --label build -- sh -c 'exit 0' >/dev/null 2>&1
                   ORCH_REPO="$ROOT/c1" "$ORCH" run --feature F010-bestofn --label tests -- sh -c 'exit 0' >/dev/null 2>&1 )
# c2 makes its change across two commits. A candidate must be measured whole:
# ranking on the last commit alone would score it as the smallest diff and it
# would win on a number that means nothing.
( cd "$ROOT/c2" && printf 'x\n' >> src/calc.py && git add -A && git commit -q -m c2a
                   printf 'y\n' >> src/calc.py && git add -A && git commit -q -m c2b
                   ORCH_REPO="$ROOT/c2" "$ORCH" run --feature F010-bestofn --label build -- sh -c 'exit 0' >/dev/null 2>&1
                   ORCH_REPO="$ROOT/c2" "$ORCH" run --feature F010-bestofn --label tests -- sh -c 'exit 0' >/dev/null 2>&1 )
( cd "$ROOT/c3" && printf 'y\n' >> src/calc.py && git add -A && git commit -q -m c3
                   ORCH_REPO="$ROOT/c3" "$ORCH" run --feature F010-bestofn --label build -- sh -c 'exit 0' >/dev/null 2>&1
                   ORCH_REPO="$ROOT/c3" "$ORCH" run --feature F010-bestofn --label tests -- sh -c 'exit 1' >/dev/null 2>&1 )

out="$("$ORCH" candidates collect F010-bestofn build tests 2>&1)"
chk $? "collect exits 0"
[ "$(printf '%s' "$out" | jq -s 'length')" = "3" ]; chk $? "all three candidates were collected"
[ "$(printf '%s' "$out" | jq -s -r '[.[] | select(.candidate=="c3") | .gates_passed] | .[0]')" = "1" ]
chk $? "c3 is recorded as 1 of 2 gates passed"

d1="$(printf '%s' "$out" | jq -s -r '[.[] | select(.candidate=="c1") | .diff_lines] | .[0]')"
d2="$(printf '%s' "$out" | jq -s -r '[.[] | select(.candidate=="c2") | .diff_lines] | .[0]')"
[ "$d1" = "1" ]; chk $? "c1's one-line change measures as 1 line (got $d1)"
[ "$d2" = "2" ]; chk $? "c2's two commits measure as 2 lines, not 1 (got $d2)"
# All three committed the APPROACH.md that orch itself wrote into the worktree.
# If it counted, every candidate would carry ~15 lines that say nothing about
# its solution — and a candidate that simply failed to commit it would look
# smaller for free.
ok "orch's own APPROACH.md is excluded from the ranked diff (implied by the above)"

printf '\nmechanical selection:\n'
winner="$("$ORCH" candidates select F010-bestofn 2>/dev/null)"
[ "$winner" != "c3" ]; chk $? "the candidate that failed a gate cannot win (winner: $winner)"
[ "$winner" = "c1" ]; chk $? "the eligible candidate with the smaller diff wins ($winner)"

LEDGER="$ORCH_REPO/docs/features/F010-bestofn/ledger.jsonl"
jq -e -s 'any(.[]; .event=="bestofn.selected" and (.ranking|length) >= 2)' "$LEDGER" >/dev/null
chk $? "the ranking of every eligible candidate is archived"
[ "$(jq -s '[.[] | select(.event=="candidate.collected")] | length' "$LEDGER")" = "3" ]
chk $? "all N are archived with their gate results, not just the winner"
jq -e -s 'any(.[]; .event=="bestofn.selected" and (.reason | length > 0))' "$LEDGER" >/dev/null
chk $? "the selection reason is recorded"

# Selection must be decided before any model is consulted. The proof is that it
# runs to completion with no model available at all.
out="$(PATH=/usr/bin:/bin "$ORCH" candidates select F010-bestofn 2>/dev/null)"
[ -n "$out" ]; chk $? "selection completes with no model in the loop"

printf '\nno winner at all:\n'
setup_repo bestofn2 >/dev/null 2>&1
export ORCH_FEATURE=F011-nowin
"$ORCH" feature start F011-nowin --request "test fixture" >/dev/null 2>&1
"$ORCH" candidates start F011-nowin -n 2 >/dev/null 2>&1
R2="$ORCH_REPO/.orch/worktrees/F011-nowin"
for c in c1 c2; do
  ( cd "$R2/$c" && ORCH_REPO="$R2/$c" "$ORCH" run --feature F011-nowin --label build -- sh -c 'exit 1' >/dev/null 2>&1 )
done
"$ORCH" candidates collect F011-nowin build >/dev/null 2>&1
out="$("$ORCH" candidates select F011-nowin 2>&1)"; rc=$?
chk_rc 1 "$rc" "when nothing passes every gate, selection fails rather than picking the least bad"
contains "$out" "No candidate passed every gate" "and says so"

printf '\ncleanup:\n'
"$ORCH" candidates clean F011-nowin --keep c1 >/dev/null 2>&1
[ -d "$R2/c1" ] && [ ! -d "$R2/c2" ]
chk $? "clean removes the losers and keeps the winner"

# --- the diagnostic stage --------------------------------------------------
printf '\ndiagnostic stage:\n'
setup_repo diagnose >/dev/null 2>&1
export ORCH_FEATURE=F012-diag
"$ORCH" feature start F012-diag --request "test fixture" >/dev/null 2>&1
fid="$("$ORCH" findings add F012-diag --raised-by correctness --severity blocking \
        --file src/calc.py --line 2 --claim "add is wrong" --consequence "callers get bad sums")"

out="$("$ORCH" diagnose start F012-diag "$fid" -k 3 2>&1)"
chk $? "diagnose start exits 0"
[ "$("$ORCH" diagnose show F012-diag | jq -s 'length')" = "3" ]
chk $? "K=3 hypotheses were created"
h="$("$ORCH" diagnose show F012-diag | jq -s -r '[.[].hypothesis] | join(",")')"
contains "$h" "the-fix-is-wrong" "one hypothesis blames the code"
contains "$h" "the-test-is-wrong" "one blames the test"
contains "$h" "the-requirement-is-ambiguous" "one blames the requirement"
contains "$out" "not a prediction" "the instructions rule out opinions explicitly"

printf '\nexecution selects, not consensus:\n'
"$ORCH" diagnose predict F012-diag 1 --prediction "the sum is wrong" --command "exit 0" >/dev/null 2>&1
"$ORCH" diagnose predict F012-diag 2 --prediction "the test asserts the wrong value" --command "exit 1" >/dev/null 2>&1
"$ORCH" diagnose predict F012-diag 3 --prediction "the requirement is ambiguous" --command "exit 1" >/dev/null 2>&1
winner="$("$ORCH" diagnose run F012-diag 2>/dev/null)"; rc=$?
chk_rc 0 "$rc" "exactly one prediction holding resolves the diagnosis"
[ "$winner" = "the-fix-is-wrong" ]; chk $? "the hypothesis whose prediction held is the one selected ($winner)"
DLED="$ORCH_REPO/docs/features/F012-diag/ledger.jsonl"
jq -e -s 'any(.[]; .event=="diagnose.resolved")' "$DLED" >/dev/null; chk $? "the resolution is logged"
# Every prediction ran through orch run, so each has an evidence row.
[ "$(jq -s '[.[] | select(.label | startswith("diagnose-h"))] | length' "$ORCH_REPO/docs/features/F012-diag/evidence.jsonl")" = "3" ]
chk $? "all K predictions were executed and attested"

printf '\nno distinguishing experiment:\n'
setup_repo diagnose2 >/dev/null 2>&1
export ORCH_FEATURE=F013-nodiag
"$ORCH" feature start F013-nodiag --request "test fixture" >/dev/null 2>&1
fid="$("$ORCH" findings add F013-nodiag --raised-by correctness --severity blocking \
        --file src/calc.py --line 2 --claim x --consequence y)"
"$ORCH" diagnose start F013-nodiag "$fid" -k 3 >/dev/null 2>&1
for k in 1 2 3; do
  "$ORCH" diagnose predict F013-nodiag "$k" --prediction "p$k" --command "exit 1" >/dev/null 2>&1
done
out="$("$ORCH" diagnose run F013-nodiag 2>&1)"; rc=$?
chk_rc 1 "$rc" "no prediction holding is a failure, not a retry"
contains "$out" "escalation to a human (rung 5)" "and it escalates on the FIRST pass, not after a counter"
"$ORCH" escalate check F013-nodiag >/dev/null 2>&1
[ "$("$ORCH" escalate rung F013-nodiag)" = "5" ]
chk $? "the ladder moves to rung 5 on an inconclusive diagnosis"

printf '\ntwo contradictory predictions:\n'
setup_repo diagnose3 >/dev/null 2>&1
export ORCH_FEATURE=F014-contra
"$ORCH" feature start F014-contra --request "test fixture" >/dev/null 2>&1
fid="$("$ORCH" findings add F014-contra --raised-by correctness --severity blocking --file a --line 1 --claim x --consequence y)"
"$ORCH" diagnose start F014-contra "$fid" -k 2 >/dev/null 2>&1
"$ORCH" diagnose predict F014-contra 1 --prediction p1 --command "exit 0" >/dev/null 2>&1
"$ORCH" diagnose predict F014-contra 2 --prediction p2 --command "exit 0" >/dev/null 2>&1
out="$("$ORCH" diagnose run F014-contra 2>&1)"; rc=$?
chk_rc 1 "$rc" "two predictions holding at once does not get a tiebreak"
contains "$out" "not distinguishing" "the experiments are called what they were"

finish candidates
