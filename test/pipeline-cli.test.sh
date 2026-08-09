#!/bin/bash
# Harness check for the `pipeline` CLI against real tmux panes.
#
# Panes run a trivial line-echo loop instead of `claude`, so this exercises the
# real send-keys/capture-pane delivery path deterministically and for free.

set -u

HERE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"
PIPELINE="$ROOT/pipeline"
SESSION="pipeline-clitest-$$"
STATE="/tmp/pipeline-$SESSION"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$STATE"
  rm -f "$ECHO_AGENT"
}

ECHO_AGENT="$(mktemp "/tmp/pipeline-echo-agent.XXXXXX")"
cat > "$ECHO_AGENT" <<'EOF'
#!/bin/bash
# Minimal stand-in for an agent pane: echoes each received line to a file.
role="${1:-unknown}"
out="$PIPELINE_DIR/received-$PIPELINE_ALIAS.log"
: > "$out"
printf 'ready role=%s alias=%s\n' "$role" "$PIPELINE_ALIAS"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$out"
done
EOF
chmod +x "$ECHO_AGENT"
trap cleanup EXIT

printf 'pipeline CLI harness test (session %s)\n\n' "$SESSION"

# --- start ----------------------------------------------------------------
printf 'start:\n'
PIPELINE_AGENT_CMD="$ECHO_AGENT" "$PIPELINE" start \
  --session "$SESSION" --agents "conductor,arbiter" >/dev/null 2>&1
check $? "start exits 0"

[ -f "$STATE/registry.json" ]; check $? "registry.json created"
[ -f "$STATE/messages.log" ];  check $? "messages.log created"
[ -f "$STATE/events.jsonl" ];  check $? "events.jsonl created"
[ -f "$STATE/token" ];         check $? "channel token minted"

n="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' 2>/dev/null | grep -c .)"
[ "$n" = "2" ]; check $? "two panes exist (got ${n:-0})"

r="$(jq -r '.agents.conductor.role' "$STATE/registry.json" 2>/dev/null)"
[ "$r" = "conductor" ]; check $? "conductor registered with role"
m="$(jq -r '.agents.arbiter.model' "$STATE/registry.json" 2>/dev/null)"
[ "$m" = "opus" ]; check $? "arbiter defaulted to opus"
e="$(jq -r '.agents.arbiter.effort' "$STATE/registry.json" 2>/dev/null)"
[ "$e" = "xhigh" ]; check $? "arbiter defaulted to xhigh effort"

sleep 1

# --- tell -----------------------------------------------------------------
printf '\ntell:\n'
out="$("$PIPELINE" tell conductor "hello conductor [SIGNAL:STATUS_REQUEST]" --session "$SESSION" 2>&1)"
rc=$?
[ "$rc" = "0" ]; check $? "tell exits 0"
printf '%s' "$out" | grep -q '^Message sent to conductor (msg=1)$'
check $? "prints the confirmation line with msg id"

sleep 1
grep -q 'hello conductor' "$STATE/received-conductor.log" 2>/dev/null
check $? "message body reached the agent"
grep -q '\[PIPELINE:' "$STATE/received-conductor.log" 2>/dev/null
check $? "delivered line carries the channel token"
grep -q 'msg=1' "$STATE/received-conductor.log" 2>/dev/null
check $? "delivered line carries the msg id"
grep -q 'hello conductor' "$STATE/messages.log" 2>/dev/null
check $? "message appended to messages.log"
jq -e 'select(.kind == "tell" and .signal == "[SIGNAL:STATUS_REQUEST]")' \
  "$STATE/events.jsonl" >/dev/null 2>&1
check $? "signal recorded in events.jsonl"

# A2: leading slash must not be typed as a slash command.
"$PIPELINE" tell arbiter "/status is not a command here" --session "$SESSION" >/dev/null 2>&1
sleep 1
grep -q '/status is not a command here' "$STATE/received-arbiter.log" 2>/dev/null
check $? "leading-slash message delivered intact (A2)"
grep -qE '\] +/status' "$STATE/received-arbiter.log" 2>/dev/null
check $? "leading slash was space-guarded (A2)"

# Multi-line messages spill to the inbox, signal preserved on the sent line.
"$PIPELINE" tell conductor "line one
line two [SIGNAL:PLAN_READY feature=F001-demo]" --session "$SESSION" >/dev/null 2>&1
sleep 1
ls "$STATE"/inbox/conductor-*.md >/dev/null 2>&1
check $? "multi-line message spilled to inbox file"
grep -q 'SIGNAL:PLAN_READY feature=F001-demo' "$STATE/received-conductor.log" 2>/dev/null
check $? "signal preserved on the delivered one-liner"
grep -q 'line two' "$STATE"/inbox/conductor-*.md 2>/dev/null
check $? "inbox file holds the full body"

# --- ack ------------------------------------------------------------------
printf '\nack:\n'
"$PIPELINE" ack 1 --session "$SESSION" >/dev/null 2>&1
[ -f "$STATE/acks/1" ]; check $? "ack recorded"

# --- dead letter ----------------------------------------------------------
printf '\ndead letter:\n'
"$PIPELINE" tell nosuchagent "into the void" --session "$SESSION" >/dev/null 2>&1
rc=$?
[ "$rc" != "0" ]; check $? "tell to unknown alias exits non-zero"
grep -q 'unknown-alias' "$STATE/dead-letter.log" 2>/dev/null
check $? "unknown alias dead-lettered"

# --- status ---------------------------------------------------------------
printf '\nstatus:\n'
s="$("$PIPELINE" status --session "$SESSION" 2>&1)"
printf '%s' "$s" | grep -q 'conductor .*alive'
check $? "status reports conductor pane alive"
printf '%s' "$s" | grep -qE 'AGENT-STATE'
check $? "status has an agent-state column"

# --- kill -----------------------------------------------------------------
printf '\nkill:\n'
"$PIPELINE" kill arbiter --session "$SESSION" >/dev/null 2>&1
check $? "kill exits 0"
st="$(jq -r '.agents.arbiter.status' "$STATE/registry.json" 2>/dev/null)"
[ "$st" = "dead" ]; check $? "registry marks arbiter dead"
"$PIPELINE" tell arbiter "you are gone" --session "$SESSION" >/dev/null 2>&1
[ $? != 0 ]; check $? "tell to killed agent fails loudly"

# --- report ---------------------------------------------------------------
printf '\nreport:\n'
"$PIPELINE" report --session "$SESSION" 2>&1 | grep -q 'Signals in order'
check $? "report renders a timeline"

# --- an agent that dies on startup ---------------------------------------
# The regression this suite previously missed: `tmux new-session -d` returns 0
# the moment the session exists, so an agent whose command exits at once (a
# missing binary, an unknown flag, bad settings) was reported as "Spawned" -
# and the next split-window then failed against a server that had already gone.
printf '\ndead agent on startup:\n'

FAIL_AGENT="$(mktemp "/tmp/pipeline-fail-agent.XXXXXX")"
cat > "$FAIL_AGENT" <<'EOF'
#!/bin/bash
echo "error: unknown option '--name'" >&2
exit 3
EOF
chmod +x "$FAIL_AGENT"

DEAD_SESSION="pipeline-deadtest-$$"
DEAD_STATE="/tmp/pipeline-$DEAD_SESSION"
out="$(PIPELINE_AGENT_CMD="$FAIL_AGENT" "$PIPELINE" start \
       --session "$DEAD_SESSION" --agents "conductor,arbiter" 2>&1)"
rc=$?

[ "$rc" != "0" ]; check $? "start exits non-zero when the first agent dies"
printf '%s' "$out" | grep -q 'exited immediately'
check $? "reports that the agent exited immediately"
printf '%s' "$out" | grep -qF "unknown option '--name'"
check $? "surfaces what the pane actually printed"
printf '%s' "$out" | grep -q '^Spawned'
[ $? != 0 ]; check $? "never claims 'Spawned' for an agent that died"
tmux has-session -t "$DEAD_SESSION" 2>/dev/null
[ $? != 0 ]; check $? "leaves no half-created tmux session"
[ ! -d "$DEAD_STATE" ]; check $? "leaves no stale state directory"

# Cleanup must be good enough that an immediate re-run works.
PIPELINE_AGENT_CMD="$ECHO_AGENT" "$PIPELINE" start \
  --session "$DEAD_SESSION" --agents "conductor,arbiter" >/dev/null 2>&1
check $? "a re-run after a failed start succeeds"
tmux kill-session -t "$DEAD_SESSION" 2>/dev/null; rm -rf "$DEAD_STATE"

# The same must hold when it is the SECOND agent that dies.
SECOND_AGENT="$(mktemp "/tmp/pipeline-second-agent.XXXXXX")"
cat > "$SECOND_AGENT" <<'EOF'
#!/bin/bash
# Healthy as the conductor, fatal as anything else.
if [ "${1:-}" = "conductor" ]; then
  echo "ready"; while IFS= read -r l; do :; done
else
  echo "boom: bad settings file" >&2; exit 9
fi
EOF
chmod +x "$SECOND_AGENT"
out="$(PIPELINE_AGENT_CMD="$SECOND_AGENT" "$PIPELINE" start \
       --session "$DEAD_SESSION" --agents "conductor,arbiter" 2>&1)"
rc=$?
[ "$rc" != "0" ]; check $? "start fails when the second agent dies"
printf '%s' "$out" | grep -qF 'boom: bad settings file'
check $? "surfaces the second agent's error"
tmux has-session -t "$DEAD_SESSION" 2>/dev/null
[ $? != 0 ]; check $? "tears the whole session down, not just the dead pane"
[ ! -d "$DEAD_STATE" ]; check $? "removes the state directory too"
rm -f "$FAIL_AGENT" "$SECOND_AGENT"

# --- pane state must not touch the pane's own background -----------------
# The hook used to paint the pane background a saturated colour, which wrecked
# the contrast of Claude Code's TUI (it picks foreground colours assuming a
# dark background). State belongs on the border, around the content.
printf '\npane state styling:\n'
conductor_pane="$(jq -r '.agents.conductor.pane' "$STATE/registry.json")"

PIPELINE_ALIAS=conductor PIPELINE_DIR="$STATE" TMUX_PANE="$conductor_pane" \
  bash "$ROOT/hooks/pane-state.sh" waiting >/dev/null 2>&1
check $? "pane-state.sh runs against a live pane"

bg="$(tmux display-message -p -t "$conductor_pane" '#{pane_bg}' 2>/dev/null)"
[ "$bg" = "default" ]
check $? "pane background is left alone (got '$bg')"

st="$(tmux display-message -p -t "$conductor_pane" '#{@pipeline_state}' 2>/dev/null)"
[ "$st" = "waiting" ]
check $? "state recorded on the pane as @pipeline_state (got '$st')"

tmux show-options -p -t "$conductor_pane" pane-border-style 2>/dev/null | grep -q 'fg='
check $? "border colour set for the inactive case"
tmux show-options -p -t "$conductor_pane" pane-active-border-style 2>/dev/null | grep -q 'fg='
check $? "border colour set for the active case too"

tmux show-options -w -t "$SESSION" pane-border-status 2>/dev/null | grep -q 'top'
check $? "session shows the border label"
tmux show-options -w -t "$SESSION" pane-border-format 2>/dev/null | grep -q 'pane_title'
check $? "border label includes the agent alias"

# Opt-outs.
PIPELINE_PANE_STYLE=none PIPELINE_ALIAS=conductor PIPELINE_DIR="$STATE" \
  TMUX_PANE="$conductor_pane" bash "$ROOT/hooks/pane-state.sh" done >/dev/null 2>&1
st="$(tmux display-message -p -t "$conductor_pane" '#{@pipeline_state}' 2>/dev/null)"
[ "$st" = "waiting" ]
check $? "PIPELINE_PANE_STYLE=none changes nothing"

PIPELINE_PANE_STYLE=bg PIPELINE_ALIAS=conductor PIPELINE_DIR="$STATE" \
  TMUX_PANE="$conductor_pane" bash "$ROOT/hooks/pane-state.sh" done >/dev/null 2>&1
bg="$(tmux display-message -p -t "$conductor_pane" '#{pane_bg}' 2>/dev/null)"
[ "$bg" != "default" ]
check $? "PIPELINE_PANE_STYLE=bg restores the old behaviour"
tmux select-pane -t "$conductor_pane" -P 'bg=default' >/dev/null 2>&1

( unset PIPELINE_ALIAS; bash "$ROOT/hooks/pane-state.sh" waiting ) >/dev/null 2>&1
check $? "pane-state.sh no-ops cleanly outside a session"

# --- mouse and scrollback -------------------------------------------------
printf '\nmouse and scrollback:\n'
tmux show-options -t "$SESSION" mouse 2>/dev/null | grep -q 'on'
check $? "mouse is on for the session"

# history-limit only applies to panes created AFTER it is set, so assert on an
# actual agent pane rather than on the session default.
hl="$(tmux display-message -p -t "$conductor_pane" '#{history_limit}' 2>/dev/null)"
[ "$hl" = "50000" ]
check $? "an agent pane got the larger scrollback (got '$hl')"

"$PIPELINE" mouse off --session "$SESSION" >/dev/null 2>&1
tmux show-options -t "$SESSION" mouse 2>/dev/null | grep -q 'off'
check $? "pipeline mouse off works on a live session"
"$PIPELINE" mouse on --session "$SESSION" >/dev/null 2>&1
tmux show-options -t "$SESSION" mouse 2>/dev/null | grep -q 'on'
check $? "pipeline mouse on works on a live session"
"$PIPELINE" mouse --session "$SESSION" 2>&1 | grep -q 'mouse is on'
check $? "pipeline mouse with no argument reports state"

MOUSE_OFF_SESSION="pipeline-mouseoff-$$"
PIPELINE_MOUSE=off PIPELINE_AGENT_CMD="$ECHO_AGENT" "$PIPELINE" start \
  --session "$MOUSE_OFF_SESSION" --agents "conductor" >/dev/null 2>&1
tmux show-options -A -t "$MOUSE_OFF_SESSION" mouse 2>/dev/null | grep -q 'off'
check $? "PIPELINE_MOUSE=off is honoured at start"
tmux kill-session -t "$MOUSE_OFF_SESSION" 2>/dev/null
rm -rf "/tmp/pipeline-$MOUSE_OFF_SESSION"

# --- peek -----------------------------------------------------------------
# The interface that works from a phone over SSH: no tmux UI, no mouse.
printf '\npeek:\n'
"$PIPELINE" peek conductor --session "$SESSION" 2>&1 | grep -q 'ready role=conductor'
check $? "peek prints the agent's screen without attaching"
"$PIPELINE" peek conductor --lines 1 --session "$SESSION" 2>&1 | grep -c . | grep -q '^2$'
check $? "--lines bounds the output"
"$PIPELINE" peek nosuchagent --session "$SESSION" >/dev/null 2>&1
[ $? != 0 ]; check $? "peek on an unknown alias fails clearly"

# --- panes can reach the pipeline CLI -------------------------------------
# Agents coordinate ONLY by shelling out to `pipeline`. A pane that cannot
# resolve it has no message channel at all, and the failure is near-silent.
# Panes otherwise inherit the launching shell's PATH, which is not dependable:
# a second terminal, a login vs non-login shell, or an already-running tmux
# server can each differ. Note tmux ignores `-e PATH=` (it honours -e for other
# variables), so this has to be set on the pane command itself.
printf '\npane PATH:\n'
PROBE="$(mktemp "/tmp/pipeline-probe.XXXXXX")"
PROBE_OUT="$(mktemp "/tmp/pipeline-probe-out.XXXXXX")"
cat > "$PROBE" <<EOF
#!/bin/bash
{ command -v pipeline || echo "PIPELINE-NOT-FOUND"; } > "$PROBE_OUT"
while IFS= read -r l; do :; done
EOF
chmod +x "$PROBE"

PATH_SESSION="pipeline-pathtest-$$"
# Deliberately launch with a PATH that cannot see the pipeline CLI.
env PATH=/usr/bin:/bin PIPELINE_AGENT_CMD="$PROBE" "$PIPELINE" start \
  --session "$PATH_SESSION" --agents "conductor" >/dev/null 2>&1
sleep 2
grep -q 'PIPELINE-NOT-FOUND' "$PROBE_OUT" 2>/dev/null
[ $? != 0 ]; check $? "a pane resolves 'pipeline' even when the launching shell cannot"
grep -q '/pipeline$' "$PROBE_OUT" 2>/dev/null
check $? "and it resolves to the real CLI"
tmux kill-session -t "$PATH_SESSION" 2>/dev/null
rm -rf "/tmp/pipeline-$PATH_SESSION" "$PROBE" "$PROBE_OUT"

# --- doctor ---------------------------------------------------------------
printf '\ndoctor:\n'
"$PIPELINE" doctor >/dev/null 2>&1
check $? "doctor exits 0 on a healthy install"
"$PIPELINE" doctor 2>&1 | grep -q 'the command a conductor pane runs'
check $? "doctor prints the exact pane command"
"$PIPELINE" doctor 2>&1 | grep -qE 'yes  --|no   --'
check $? "doctor reports which optional flags this build supports"

mv "$ROOT/prompts/conductor.md" "$ROOT/prompts/conductor.md.bak"
out="$("$PIPELINE" doctor 2>&1)"; rc=$?
mv "$ROOT/prompts/conductor.md.bak" "$ROOT/prompts/conductor.md"
[ "$rc" != "0" ]; check $? "doctor exits non-zero when a prompt is missing"
printf '%s' "$out" | grep -q 'FAIL conductor'
check $? "doctor names the role whose files are missing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
