#!/bin/bash
# Colour an agent's tmux pane to reflect its state.
#
#   running  blue    the agent is working
#   waiting  yellow  the agent needs the developer
#   done     green   the agent is idle
#
# Invoked from settings/role-*.json hooks. No-ops silently outside a pipeline
# session, so the settings file is safe to reuse anywhere.

set -u

state="${1:-running}"

[ -n "${PIPELINE_ALIAS:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
[ -n "${TMUX:-}${TMUX_PANE:-}" ] || exit 0

case "$state" in
  running) colour="colour24" ;;   # blue
  waiting) colour="colour136" ;;  # yellow
  done)    colour="colour22" ;;   # green
  *)       exit 0 ;;
esac

pane="${TMUX_PANE:-}"
if [ -z "$pane" ] && [ -n "${PIPELINE_DIR:-}" ] && [ -f "$PIPELINE_DIR/registry.json" ] \
   && command -v jq >/dev/null 2>&1; then
  pane="$(jq -r --arg a "$PIPELINE_ALIAS" '.agents[$a].pane // empty' \
    "$PIPELINE_DIR/registry.json" 2>/dev/null)"
fi
[ -n "$pane" ] || exit 0

tmux select-pane -t "$pane" -P "bg=$colour" >/dev/null 2>&1 || true
exit 0
