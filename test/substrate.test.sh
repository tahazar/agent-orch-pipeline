#!/bin/bash
# substrate.test.sh - build-order step 1: the seam, the shared list, doctor.
#
# Acceptance (spec §14.1): two sessions sharing a task-list ID see each other's
# tasks; doctor catches a deliberately mismatched permission-mode class and a
# cross-container unreachable peer.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo substrate
printf 'substrate + seam\n\n'

. "$ORCH_ROOT/lib/substrate/base.sh"

# --- the six-plus-one operations exist ------------------------------------
printf 'seam:\n'
for op in roster post claim_task release_task set_gate read_gate probe; do
  declare -f "substrate_$op" >/dev/null 2>&1
  chk $? "substrate_$op is defined"
done
[ "$(substrate_name)" = "messaging" ]; chk $? "default substrate is messaging"

out="$(ORCH_SUBSTRATE=teams bash -c ". '$ORCH_ROOT/lib/substrate/base.sh'; substrate_roster" 2>&1)"; rc=$?
chk_rc 78 "$rc" "teams substrate refuses rather than half-works"
contains "$out" "not an implementation" "teams stub explains why it is a stub"

# Nothing above lib/substrate/ may reach around the seam. This is the whole
# point of having one: when the substrate moves, exactly one directory moves.
printf '\nno reach-around:\n'
# Patterns are deliberately written to match INVOCATIONS, not mentions. Naming
# the platform in a help string or a warning is fine and often necessary; what
# must not exist above lib/substrate/ is code that runs it. Backtick command
# substitution is not matched because it is indistinguishable from markdown in
# a help string — the codebase uses $( ) throughout, and adding a backtick call
# to dodge this check would be a deliberate act rather than an accident.
leak=0
for f in "$ORCH_ROOT/bin/orch" "$ORCH_ROOT"/lib/*.sh "$ORCH_ROOT"/hooks/*.sh; do
  if grep -nE '(\$\(claude agents|^[[:space:]]*claude agents|\.claude/tasks|\$\{?CLAUDE_CODE_MESSAGING_SOCKET|/tmp/cc-socks)' "$f" \
     >/dev/null 2>&1; then
    bad "$(basename "$f") reaches around the substrate seam:"
    grep -nE '(\$\(claude agents|^[[:space:]]*claude agents|\.claude/tasks|\$\{?CLAUDE_CODE_MESSAGING_SOCKET|/tmp/cc-socks)' "$f" | sed 's/^/         /'
    leak=1
  fi
done
[ "$leak" = "0" ] && ok "no file above lib/substrate/ touches the platform directly"

# --- two sessions share one list ------------------------------------------
printf '\nshared task list:\n'
"$ORCH" feature start F001-alpha --request "test fixture" >/dev/null 2>&1
"$ORCH" approve F001-alpha --gate plan-approved >/dev/null 2>&1
# A second "session" is a second process with the same task-list id and a
# different session id. If sharing works, it sees the first one's gate.
seen="$(CLAUDE_CODE_SESSION_ID=other-session "$ORCH" gate read F001-alpha plan-approved 2>/dev/null | jq -r '.state')"
[ "$seen" = "met" ]; chk $? "a second session sees the first session's gate"

private="$(CLAUDE_CODE_TASK_LIST_ID=orch-somewhere-else "$ORCH" gate read F001-alpha plan-approved 2>/dev/null | jq -r '.state')"
[ "$private" = "absent" ]; chk $? "a session with a different task-list id shares nothing"

# --- id allocation is race-free -------------------------------------------
printf '\nid allocation:\n'
for i in 1 2 3 4 5 6; do
  ( "$ORCH" approve F001-alpha --gate "race-$i" >/dev/null 2>&1 ) &
done
wait
n_files="$(ls "$ORCH_TASKS_ROOT/$CLAUDE_CODE_TASK_LIST_ID"/*.json 2>/dev/null | grep -c .)"
n_ids="$(cat "$ORCH_TASKS_ROOT/$CLAUDE_CODE_TASK_LIST_ID"/*.json 2>/dev/null | jq -r '.id' | sort -u | grep -c .)"
[ "$n_files" = "$n_ids" ] && [ "$n_files" -ge 7 ]
chk $? "6 concurrent writers produced $n_files tasks with $n_ids distinct ids (no lost write)"

# --- gates are sha-bound --------------------------------------------------
printf '\ngate sha binding:\n'
"$ORCH" approve F001-alpha --gate human >/dev/null 2>&1
"$ORCH" gate check F001-alpha human >/dev/null 2>&1
chk $? "gate met at the current sha passes"
printf 'moved\n' >> README.md && git add -A && git commit -q -m "move the tip"
out="$("$ORCH" gate check F001-alpha human 2>&1)"; rc=$?
chk_rc 1 "$rc" "the same approval fails once the branch tip moves"
contains "$out" "does not carry across" "stale approval explains itself"

# --- gates survive the process --------------------------------------------
printf '\ndurability:\n'
state="$(cat "$ORCH_TASKS_ROOT/$CLAUDE_CODE_TASK_LIST_ID"/*.json | jq -s -r '[.[] | select(.metadata.orch.gate=="human")] | .[0].status')"
[ "$state" = "completed" ]; chk $? "the approval is on disk, not in a process"

# --- doctor ----------------------------------------------------------------
printf '\ndoctor:\n'
out="$(ORCH_NO_COLOR=1 "$ORCH" doctor 2>&1)"; rc=$?
contains "$out" "coordination:" "doctor reports on coordination"
contains "$out" "platform:" "doctor reports on the platform"

# doctor must fail, not shrug, when this session shares no task list.
out="$(env -u CLAUDE_CODE_TASK_LIST_ID ORCH_NO_COLOR=1 "$ORCH" doctor 2>&1)"; rc=$?
chk_rc 1 "$rc" "doctor fails when CLAUDE_CODE_TASK_LIST_ID is unset"
contains "$out" "coordinates with nobody" "doctor names the consequence, not just the setting"

# A mismatched permission-mode class and an unreachable peer are the two §1
# constraints that fail silently in production, so both are asserted against a
# synthetic roster rather than trusted to a live one.
printf '\ndoctor, injected failures:\n'
fake="$WORK/fake-claude"
cat > "$fake" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --version) echo "2.1.228 (Claude Code)" ;;
  agents) cat "$FAKE_ROSTER" ;;
esac
EOF
chmod +x "$fake"
mkdir -p "$WORK/bin" && cp "$fake" "$WORK/bin/claude"

# Two peers, two classes: one prompting (this test process) and one bypassing.
cat > "$WORK/roster-mixed.json" <<EOF
[{"pid":$$,"cwd":"$ORCH_REPO","kind":"interactive","sessionId":"a","name":"peer-a"},
 {"pid":1,"cwd":"$ORCH_REPO","kind":"interactive","sessionId":"b","name":"peer-b"}]
EOF
out="$(PATH="$WORK/bin:$PATH" FAKE_ROSTER="$WORK/roster-mixed.json" \
       ORCH_SOCKET_DIR="$WORK/socks" ORCH_NO_COLOR=1 "$ORCH" doctor 2>&1)"
contains "$out" "no messaging socket" "doctor catches peers with no socket"

# A peer whose cwd this machine cannot see is a peer in another container.
cat > "$WORK/roster-remote.json" <<EOF
[{"pid":$$,"cwd":"/nonexistent/other-container","kind":"interactive","sessionId":"c","name":"peer-c"}]
EOF
out="$(PATH="$WORK/bin:$PATH" FAKE_ROSTER="$WORK/roster-remote.json" \
       ORCH_NO_COLOR=1 "$ORCH" doctor 2>&1)"
contains "$out" "cannot see" "doctor catches a cross-container unreachable peer"
contains "$out" "must share a filesystem" "doctor explains the same-filesystem constraint"

finish substrate
