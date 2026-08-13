#!/bin/bash
# gates.test.sh - build-order steps 2, 3 and 4: ledger, evidence, blocking gates.
#
# Acceptance (spec §14):
#   2. every SendMessage and its outcome appears in ledger.jsonl; a held-then-
#      expired message is logged as expired, not as delivered
#   3. an approval citing an unattested command is rejected; one citing a
#      non-zero exit while claiming success is rejected
#   4. a merge with the approval unmarked is blocked with a readable reason;
#      the same merge succeeds once marked; the sha check invalidates an
#      approval after the branch moves

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo gates
printf 'ledger, evidence, blocking gates\n\n'

export ORCH_FEATURE=F002-gates
"$ORCH" feature start F002-gates --request "test fixture" >/dev/null 2>&1

hook() {  # hook <script> <json>
  printf '%s' "$2" | "$ORCH_ROOT/hooks/$1"
}
LEDGER="$ORCH_REPO/docs/features/F002-gates/ledger.jsonl"

# --- message audit ---------------------------------------------------------
printf 'message audit:\n'
hook audit-message.sh '{"hook_event_name":"PreToolUse","tool_name":"SendMessage","tool_input":{"to":"developer","message":"start F002"}}'
grep -q '"event":"message.posted"' "$LEDGER"; chk $? "PreToolUse logs the message"
grep -q '"body":"start F002"' "$LEDGER"; chk $? "the body is logged, not just the fact of a message"

hook audit-message.sh '{"hook_event_name":"PostToolUse","tool_name":"SendMessage","tool_input":{"to":"developer"},"tool_response":{"status":"delivered"}}'
grep -q '"outcome":"delivered"' "$LEDGER"; chk $? "a delivered message is logged as delivered"

# The case worth asserting: a transport that dead-letters what it delivered,
# and had no way to record one it had NOT.
hook audit-message.sh '{"hook_event_name":"PostToolUse","tool_name":"SendMessage","tool_input":{"to":"code-reviewer"},"tool_response":{"status":"held","detail":"expired after dialogExpiry"}}'
n_exp="$(grep -c '"outcome":"expired"' "$LEDGER")"
n_del="$(grep -c '"outcome":"delivered"' "$LEDGER")"
[ "$n_exp" = "1" ] && [ "$n_del" = "1" ]
chk $? "a held-then-expired message is logged as expired, not delivered"

hook audit-message.sh '{"hook_event_name":"PostToolUse","tool_name":"SendMessage","tool_input":{"to":"x"},"tool_response":{"status":"something new"}}'
grep -q '"outcome":"unknown"' "$LEDGER"; chk $? "an unrecognised outcome degrades to unknown, never to delivered"

hook audit-message.sh '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}'
[ "$(grep -c 'message\.' "$LEDGER")" = "4" ]; chk $? "a non-SendMessage tool is not audited as a message"

# --- attested execution ----------------------------------------------------
printf '\nattested execution:\n'
out="$("$ORCH" run --feature F002-gates --label build -- sh -c 'echo compiled'; )"; rc=$?
chk_rc 0 "$rc" "orch run passes the exit code through"
contains "$out" "compiled" "orch run streams output unchanged"
"$ORCH" run --feature F002-gates --label tests -- sh -c 'echo "1 failed"; exit 1' >/dev/null 2>&1
chk_rc 1 "$?" "a failing command still exits non-zero through the tee"

ev="$ORCH_REPO/docs/features/F002-gates/evidence.jsonl"
[ "$(jq -s 'length' "$ev")" = "2" ]; chk $? "both runs were recorded"
jq -e -s '.[0] | has("stdout_sha256") and has("git_sha") and has("duration_s") and has("worktree")' "$ev" >/dev/null
chk $? "an evidence row carries the sha, the git sha, the duration and the worktree"

printf '\nunattested and contradicted claims:\n'
out="$("$ORCH" evidence verify --feature F002-gates --label lint --claim pass 2>&1)"; rc=$?
chk_rc 3 "$rc" "a claim citing a command that never ran is rejected"
contains "$out" "EVIDENCE_UNATTESTED" "rejection names the failure mode"

out="$("$ORCH" evidence verify --feature F002-gates --label tests --claim pass 2>&1)"; rc=$?
chk_rc 4 "$rc" "a claim of success over a non-zero exit is rejected"
contains "$out" "EVIDENCE_CONTRADICTED" "rejection names the failure mode"

out="$("$ORCH" evidence verify --feature F002-gates --label tests --claim fail 2>&1)"; rc=$?
chk_rc 0 "$rc" "the red phase — a run required to fail, that failed — verifies"

printf 'x\n' >> README.md && git add -A && git commit -q -m move
out="$("$ORCH" evidence verify --feature F002-gates --label build --claim pass --fresh 2>&1)"; rc=$?
chk_rc 5 "$rc" "evidence taken before the branch moved is stale"
contains "$out" "EVIDENCE_STALE" "staleness names the failure mode"

# --- the merge gate --------------------------------------------------------
printf '\nmerge gate:\n'
MERGE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git merge --squash feature/x"}}'
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 2 "$rc" "a merge with no approval is blocked"
contains "$out" "BLOCKED" "the block is legible"
contains "$out" "orch approve F002-gates --gate human" "the block says exactly how to unblock it"

out="$(hook gate-guard.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}' 2>&1)"; rc=$?
chk_rc 0 "$rc" "an unrelated Bash command is not blocked"

out="$(hook gate-guard.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git merge --abort"}}' 2>&1)"; rc=$?
chk_rc 0 "$rc" "git merge --abort is not blocked — stranding a half-merged tree is worse"

"$ORCH" approve F002-gates --gate human >/dev/null 2>&1
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the same merge passes once approved"

printf 'y\n' >> README.md && git add -A && git commit -q -m "move after approval"
out="$(hook gate-guard.sh "$MERGE" 2>&1)"; rc=$?
chk_rc 2 "$rc" "the approval is void once the branch tip moves"
contains "$out" "no longer describes what you are about to merge" "the sha block explains why"

for c in "git push origin main" "gh pr create --title x"; do
  rc=0; hook gate-guard.sh "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}" >/dev/null 2>&1 || rc=$?
  chk_rc 2 "$rc" "\`$c\` is gated too"
done

# --- a broken guard fails open --------------------------------------------
printf '\nfailure mode of the guard itself:\n'
# The hook derives ORCH_HOME from its own location, so the only honest way to
# break it is to put it somewhere that has no lib/ next to it — which is
# exactly what a partial install or a copied hook looks like in the wild.
mkdir -p "$WORK/orphan/hooks"
cp "$ORCH_ROOT/hooks/gate-guard.sh" "$WORK/orphan/hooks/"
out="$(printf '%s' "$MERGE" | "$WORK/orphan/hooks/gate-guard.sh" 2>&1)"; rc=$?
chk_rc 0 "$rc" "a guard that cannot load its libraries does not paralyse the session"
contains "$out" "NOT blocking" "and it says so loudly instead of failing silently"

# --- TaskCompleted guard ---------------------------------------------------
printf '\ntask guard:\n'
RED='{"hook_event_name":"TaskCompleted","task":{"subject":"test-engineer: red phase for F002","metadata":{"orch":{"feature":"F002-gates","requires":"tests-fail-correctly"}}}}'
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the red phase passes when the tests are attested failing"

"$ORCH" run --feature F002-gates --label tests -- sh -c 'exit 0' >/dev/null 2>&1
out="$(hook task-guard.sh "$RED" 2>&1)"; rc=$?
chk_rc 2 "$rc" "the red phase is blocked when the tests pass before the code exists"
contains "$out" "would be testing nothing" "and explains why that is the test's fault"

out="$(hook task-guard.sh '{"hook_event_name":"TaskCompleted","stop_hook_active":true,"task":{"subject":"test-engineer: red phase","metadata":{"orch":{"feature":"F002-gates","requires":"tests-fail-correctly"}}}}' 2>&1)"; rc=$?
chk_rc 0 "$rc" "stop_hook_active is honoured, so a guard cannot trap a session"

BUILD='{"hook_event_name":"TaskCompleted","task":{"subject":"developer: implement F002","metadata":{"orch":{"feature":"F002-gates","requires":"tests-pass"}}}}'
"$ORCH" run --feature F002-gates --label build -- sh -c 'exit 0' >/dev/null 2>&1
out="$(hook task-guard.sh "$BUILD" 2>&1)"; rc=$?
chk_rc 0 "$rc" "the developer's task completes when build and tests are attested green"

"$ORCH" run --feature F002-gates --label build -- sh -c 'exit 7' >/dev/null 2>&1
out="$(hook task-guard.sh "$BUILD" 2>&1)"; rc=$?
chk_rc 2 "$rc" "and is blocked the moment the oracle goes red"

# --- write scope -----------------------------------------------------------
printf '\nwrite scope:\n'
ws() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" \
       | ORCH_ROLE="$2" "$ORCH_ROOT/hooks/write-scope.sh" 2>&1; }
out="$(ws "$ORCH_REPO/src/calc.py" director)"; rc=$?
chk_rc 2 "$rc" "the director cannot edit source"
contains "$out" "outside this role's write scope" "and is told why"
out="$(ws "$ORCH_REPO/docs/features/F002-gates/design.md" director)"; rc=$?
chk_rc 0 "$rc" "the director can write its own artifacts"
out="$(ws "$ORCH_REPO/test/test_calc.py" developer)"; rc=$?
chk_rc 2 "$rc" "the developer cannot edit the tests it must satisfy"
contains "$out" "make it green" "and is told what that would let it do"
out="$(ws "$ORCH_REPO/src/calc.py" developer)"; rc=$?
chk_rc 0 "$rc" "the developer can edit source"
out="$(ws "$ORCH_REPO/src/calc.py" code-reviewer)"; rc=$?
chk_rc 2 "$rc" "a code-reviewer contributes information, never actions"
out="$(ws "$ORCH_REPO/src/calc.py" '')"; rc=$?
chk_rc 0 "$rc" "an unroled session is not confined by accident"

# The path the agent supplies and the path git reports are not always spelled
# the same. On macOS /var is a symlink to /private/var, so a repo under $TMPDIR
# is reported by git with a /private prefix the tool input does not have. An
# unresolved string compare leaves the path absolute, matches no allow glob, and
# refuses a write the role is entitled to make — on one platform only.
printf '\nwrite scope through a symlinked path:\n'
ln -s "$ORCH_REPO" "$WORK/link-to-repo" 2>/dev/null
out="$(ws "$WORK/link-to-repo/docs/features/F002-gates/design.md" director)"; rc=$?
chk_rc 0 "$rc" "an allowed path reached through a symlink is still allowed"
out="$(ws "$WORK/link-to-repo/src/calc.py" director)"; rc=$?
chk_rc 2 "$rc" "and a denied path reached through a symlink is still denied"

# --- task scope ------------------------------------------------------------
#
# Sharing one task list is what gives the team locking and auto-unblock.
# Reading all of it is a different thing, and for two roles it is the thing
# that destroys what they are for.
printf '\ntask scope:\n'
ts() {  # ts <role> <tool> [feature] [owner-role]
  printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"metadata":{"orch":{"feature":"%s","role":"%s"}}}}' \
    "$2" "${3:-}" "${4:-}" \
  | ORCH_ROLE="$1" ORCH_FEATURE=F002-gates "$ORCH_ROOT/hooks/task-scope.sh" 2>&1
}

out="$(ts director TaskList)"; rc=$?
chk_rc 0 "$rc" "the director sees the whole board"
out="$(ts auditor TaskGet)"; rc=$?
chk_rc 0 "$rc" "so does the auditor — hiding work from an adjudicator is how it approves what it could not see"

out="$(ts code-reviewer TaskList)"; rc=$?
chk_rc 2 "$rc" "a code-reviewer cannot read the task list at all"
contains "$out" "second opinion" "and is told why its independence is the point"
contains "$out" "orch findings add" "and how to report instead"

out="$(ts developer TaskGet F002-gates)"; rc=$?
chk_rc 0 "$rc" "the developer reads its own feature's tasks"
out="$(ts developer TaskGet F099-other)"; rc=$?
chk_rc 2 "$rc" "but not another feature's"
contains "$out" "serial" "and is told features are separate contexts on purpose"

out="$(ts test-engineer TaskGet F002-gates test-engineer)"; rc=$?
chk_rc 0 "$rc" "the test-engineer reads its own tasks"
out="$(ts test-engineer TaskGet F002-gates developer)"; rc=$?
chk_rc 2 "$rc" "but never the developer's — a test written against the implementation checks nothing"
contains "$out" "requirements.md" "and is pointed back at the requirements"

out="$(ts developer Read F002-gates)"; rc=$?
chk_rc 0 "$rc" "an unrelated tool is not intercepted"
out="$(printf '{"tool_name":"TaskList","tool_input":{}}' | "$ORCH_ROOT/hooks/task-scope.sh" 2>&1)"; rc=$?
chk_rc 0 "$rc" "an unroled session is not confined by accident"

finish gates
