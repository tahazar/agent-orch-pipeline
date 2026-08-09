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
  --session "$SESSION" --agents "orch,principal" >/dev/null 2>&1
check $? "start exits 0"

[ -f "$STATE/registry.json" ]; check $? "registry.json created"
[ -f "$STATE/messages.log" ];  check $? "messages.log created"
[ -f "$STATE/events.jsonl" ];  check $? "events.jsonl created"
[ -f "$STATE/token" ];         check $? "channel token minted"

n="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' 2>/dev/null | grep -c .)"
[ "$n" = "2" ]; check $? "two panes exist (got ${n:-0})"

r="$(jq -r '.agents.orch.role' "$STATE/registry.json" 2>/dev/null)"
[ "$r" = "orch" ]; check $? "orch registered with role"
m="$(jq -r '.agents.principal.model' "$STATE/registry.json" 2>/dev/null)"
[ "$m" = "opus" ]; check $? "principal defaulted to opus"
e="$(jq -r '.agents.principal.effort' "$STATE/registry.json" 2>/dev/null)"
[ "$e" = "xhigh" ]; check $? "principal defaulted to xhigh effort"

sleep 1

# --- tell -----------------------------------------------------------------
printf '\ntell:\n'
out="$("$PIPELINE" tell orch "hello orch [SIGNAL:STATUS_REQUEST]" --session "$SESSION" 2>&1)"
rc=$?
[ "$rc" = "0" ]; check $? "tell exits 0"
printf '%s' "$out" | grep -q '^Message sent to orch (msg=1)$'
check $? "prints the confirmation line with msg id"

sleep 1
grep -q 'hello orch' "$STATE/received-orch.log" 2>/dev/null
check $? "message body reached the agent"
grep -q '\[PIPELINE:' "$STATE/received-orch.log" 2>/dev/null
check $? "delivered line carries the channel token"
grep -q 'msg=1' "$STATE/received-orch.log" 2>/dev/null
check $? "delivered line carries the msg id"
grep -q 'hello orch' "$STATE/messages.log" 2>/dev/null
check $? "message appended to messages.log"
jq -e 'select(.kind == "tell" and .signal == "[SIGNAL:STATUS_REQUEST]")' \
  "$STATE/events.jsonl" >/dev/null 2>&1
check $? "signal recorded in events.jsonl"

# A2: leading slash must not be typed as a slash command.
"$PIPELINE" tell principal "/status is not a command here" --session "$SESSION" >/dev/null 2>&1
sleep 1
grep -q '/status is not a command here' "$STATE/received-principal.log" 2>/dev/null
check $? "leading-slash message delivered intact (A2)"
grep -qE '\] +/status' "$STATE/received-principal.log" 2>/dev/null
check $? "leading slash was space-guarded (A2)"

# Multi-line messages spill to the inbox, signal preserved on the sent line.
"$PIPELINE" tell orch "line one
line two [SIGNAL:PLAN_READY feature=F001-demo]" --session "$SESSION" >/dev/null 2>&1
sleep 1
ls "$STATE"/inbox/orch-*.md >/dev/null 2>&1
check $? "multi-line message spilled to inbox file"
grep -q 'SIGNAL:PLAN_READY feature=F001-demo' "$STATE/received-orch.log" 2>/dev/null
check $? "signal preserved on the delivered one-liner"
grep -q 'line two' "$STATE"/inbox/orch-*.md 2>/dev/null
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
printf '%s' "$s" | grep -q 'orch .*alive'
check $? "status reports orch pane alive"
printf '%s' "$s" | grep -qE 'AGENT-STATE'
check $? "status has an agent-state column"

# --- kill -----------------------------------------------------------------
printf '\nkill:\n'
"$PIPELINE" kill principal --session "$SESSION" >/dev/null 2>&1
check $? "kill exits 0"
st="$(jq -r '.agents.principal.status' "$STATE/registry.json" 2>/dev/null)"
[ "$st" = "dead" ]; check $? "registry marks principal dead"
"$PIPELINE" tell principal "you are gone" --session "$SESSION" >/dev/null 2>&1
[ $? != 0 ]; check $? "tell to killed agent fails loudly"

# --- report ---------------------------------------------------------------
printf '\nreport:\n'
"$PIPELINE" report --session "$SESSION" 2>&1 | grep -q 'Signals in order'
check $? "report renders a timeline"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
