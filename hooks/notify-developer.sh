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
