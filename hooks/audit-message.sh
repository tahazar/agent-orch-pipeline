#!/bin/bash
# audit-message.sh - PreToolUse + PostToolUse on SendMessage.
#
# The usual argument for building a bespoke message bus is that you want a
# durable, greppable audit log. You do not have to build one: SendMessage is a
# tool, and tools are hookable.
#
# Hooking both sides is what makes this better than an audit log a sender writes
# for itself, because PostToolUse captures the OUTCOME. A message that was held
# and then expired is logged as expired, not as delivered. A sender-side log
# cannot tell those apart, and a pipeline that cannot tell them apart eventually
# dead-letters messages it has already delivered.
#
# Messages are ephemeral by design and nothing durable depends on them. This
# hook exists so `orch report` can tell you how much of your coordination was
# riding on the lossy path — which is the number that tells you whether the
# discipline in §3 is actually being kept.

set -u
ORCH_PROG=audit-message
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/ledger.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"

case "$tool" in SendMessage|mcp__*__SendMessage) ;; *) exit 0 ;; esac

to="$(printf '%s' "$payload" | jq -r '.tool_input.to // ""' 2>/dev/null)"
body="$(printf '%s' "$payload" | jq -r '.tool_input.message // .tool_input.body // ""' 2>/dev/null)"

case "$event" in
  PreToolUse)
    ledger_append message.posted transport tool to "$to" \
      bytes:raw "${#body}" body "$body"
    ;;
  PostToolUse|PostToolUseFailure)
    # The tool result reports held / refused / expired to the sender. We
    # classify from whatever shape it arrives in rather than assuming one: the
    # result envelope is not a documented contract, and a parse miss must
    # degrade to "unknown", never to a confident "delivered".
    resp="$(printf '%s' "$payload" | jq -r '.tool_response // "" | if type=="string" then . else tojson end' 2>/dev/null)"
    outcome=unknown
    case "$resp" in
      *expired*|*Expired*)     outcome=expired ;;
      *refused*|*Refused*|*denied*|*Denied*) outcome=refused ;;
      *held*|*Held*|*pending\ approval*)     outcome=held ;;
      *delivered*|*Delivered*|*sent*|*Sent*) outcome=delivered ;;
    esac
    [ "$event" = "PostToolUseFailure" ] && [ "$outcome" = "unknown" ] && outcome=refused
    ledger_append message.outcome transport tool to "$to" \
      outcome "$outcome" response "$resp"
    ;;
esac

exit 0
