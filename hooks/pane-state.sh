#!/bin/bash
# Show an agent's state on its tmux pane.
#
#   running  blue    the agent is working
#   waiting  amber   the agent needs the developer
#   done     green   the agent is idle
#
# The state is shown on the pane BORDER, never behind the pane's text. Claude
# Code's TUI chooses its foreground colours assuming a dark terminal
# background; filling the pane with a saturated colour (which this hook used to
# do via `select-pane -P bg=`) destroys the contrast it was designed for.
#
# Set PIPELINE_PANE_STYLE to choose:
#   border  (default) colour the border and label it "<alias> - <state>"
#   bg                the old behaviour: paint the pane background
#   none              no pane styling at all
#
# Invoked from settings/role-*.json hooks. No-ops silently outside a pipeline
# session, so the settings file is safe to reuse anywhere.

set -u

state="${1:-running}"
style="${PIPELINE_PANE_STYLE:-border}"

[ "$style" = "none" ] && exit 0
[ -n "${PIPELINE_ALIAS:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
[ -n "${TMUX:-}${TMUX_PANE:-}" ] || exit 0

case "$state" in
  running) colour="colour33" ;;   # blue
  waiting) colour="colour214" ;;  # amber - the one that wants your attention
  done)    colour="colour71" ;;   # green
  *)       exit 0 ;;
esac

pane="${TMUX_PANE:-}"
if [ -z "$pane" ] && [ -n "${PIPELINE_DIR:-}" ] && [ -f "$PIPELINE_DIR/registry.json" ] \
   && command -v jq >/dev/null 2>&1; then
  pane="$(jq -r --arg a "$PIPELINE_ALIAS" '.agents[$a].pane // empty' \
    "$PIPELINE_DIR/registry.json" 2>/dev/null)"
fi
[ -n "$pane" ] || exit 0

if [ "$style" = "bg" ]; then
  tmux select-pane -t "$pane" -P "bg=$colour" >/dev/null 2>&1 || true
  exit 0
fi

# Border style is set for both the active and inactive cases: tmux picks
# pane-active-border-style for whichever pane has focus, so setting only the
# inactive one would leave the focused agent with no state colour.
tmux set -p -t "$pane" @pipeline_state "$state" >/dev/null 2>&1 || true
tmux set -p -t "$pane" pane-border-style "fg=$colour" >/dev/null 2>&1 || true
tmux set -p -t "$pane" pane-active-border-style "fg=$colour,bold" >/dev/null 2>&1 || true
exit 0
