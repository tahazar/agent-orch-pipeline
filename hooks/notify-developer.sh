#!/bin/bash
# Tell the developer that a pipeline session needs them.
#
# Four gates in the workflow block on a human (decomposition approval, per-
# feature plan approval, deadlock arbitration, design deviations). Without a
# notification those gates stall silently until someone thinks to look.
#
# Invoked from settings/role-*.json Notification hooks and from
# `pipeline watch`. No-ops silently outside a pipeline session.

set -u

msg="${1:-}"
if [ -z "$msg" ]; then
  # Hook invocations pass the event payload on stdin as JSON.
  if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null || true)"
    if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
      msg="$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null)"
    fi
  fi
fi
[ -n "$msg" ] || msg="An agent needs your input"

alias_name="${PIPELINE_ALIAS:-agent}"
session="${PIPELINE_SESSION:-pipeline}"
title="pipeline/$session: $alias_name"

# Terminal bell first - it works everywhere and costs nothing.
printf '\a' >&2

# Desktop-notification escape sequence. Agent-aware terminals (cmux among them)
# ring the pane and light up its tab on OSC 9. Agents run inside tmux panes, and
# tmux drops OSC sequences it does not recognise, so wrap it for passthrough
# when we are inside tmux - `pipeline start` enables allow-passthrough on its
# own session for exactly this.
emit_osc9() {
  local msg="$1" seq
  seq="$(printf '\033]9;%s\007' "$msg")"
  if [ -n "${TMUX:-}" ]; then
    seq="$(printf '\033Ptmux;\033%s\033\\' "$seq")"
  fi
  # Group the redirection so a failure to open /dev/tty (no controlling
  # terminal - cron, a CI runner, a detached hook) is swallowed too: bash
  # applies redirections left to right, so a trailing 2>/dev/null would come
  # too late to suppress the open error itself.
  if { printf '%s' "$seq" > /dev/tty; } 2>/dev/null; then
    return 0
  fi
  printf '%s' "$seq" >&2
}
emit_osc9 "$title: $msg"

# If the terminal ships a CLI for this, use it too. Guarded and failure-ignored,
# so an unexpected signature can never break a gate notification.
if command -v cmux >/dev/null 2>&1; then
  cmux notify "$title: $msg" >/dev/null 2>&1 || true
fi

if command -v osascript >/dev/null 2>&1; then
  # Keep the payload out of the AppleScript source: embed via a quoted string
  # with escaping, so a message containing quotes cannot break the script.
  esc_msg="$(printf '%s' "$msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')"
  esc_title="$(printf '%s' "$title" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  osascript -e "display notification \"$esc_msg\" with title \"$esc_title\"" \
    >/dev/null 2>&1 || true
fi

if [ -n "${PIPELINE_DIR:-}" ] && [ -d "$PIPELINE_DIR" ]; then
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$alias_name" "$msg" \
    >> "$PIPELINE_DIR/notifications.log" 2>/dev/null || true
fi

exit 0
