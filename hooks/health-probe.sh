#!/bin/bash
# health-probe.sh - PostToolUse / PostToolUseFailure / PostCompact.
#
# The sensor for the escalation ladder. Every observation it writes is
# mechanical: a tool name, a normalized argument hash, a file and a line range,
# a success bit. Nothing here calls a model, because a detector that needs LLM
# budget to decide whether to spend LLM budget has already lost the argument.
#
# Two standing rules, both from §4.1:
#   - the transcript format is undocumented and unstable. Warn on shapes we do
#     not recognise, and never let a parse failure abort a run.
#   - this hook always exits 0. It observes; it does not gate.

set -u
ORCH_PROG=health-probe
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/health.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"
feature="$(orch_current_feature)"

# --------------------------------------------------------------------------
# Context pressure, read from the transcript.
#
# The vendor's guidance is to treat transcript entries as opaque, so this reads
# only the one field it needs, from the last entry that has it, and gives up
# silently rather than guessing at a shape it does not recognise.
# --------------------------------------------------------------------------
observe_context_pressure() {
  local tp used window pct
  tp="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)"
  [ -n "$tp" ] && [ -r "$tp" ] || return 0
  used="$(tail -n 200 "$tp" 2>/dev/null | jq -s -r '
    [ .[] | select(type=="object")
          | (.message.usage // .usage // empty)
          | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) ]
    | if length==0 then empty else max end' 2>/dev/null)"
  case "$used" in ''|*[!0-9]*) return 0 ;; esac
  window="${ORCH_CONTEXT_WINDOW:-200000}"
  pct=$(( used * 100 / window ))
  health_observe "$feature" context pct:raw "$pct" used:raw "$used" window:raw "$window"
}

case "$event" in

  PostCompact)
    # The strongest single signal in §4.1, and free: the context was exhausted.
    health_observe "$feature" compaction \
      trigger "$(printf '%s' "$payload" | jq -r '.trigger // "unknown"' 2>/dev/null)"
    ORCH_LEDGER_FEATURE="$feature" ledger_append health.compaction
    ;;

  PostToolUse|PostToolUseFailure)
    ok=true
    [ "$event" = "PostToolUseFailure" ] && ok=false

    # step_repetition: identical tool + normalized arguments. Normalizing means
    # dropping volatile keys so "the same call" is not defeated by a timestamp
    # or a changing description field.
    step_key="$(printf '%s' "$payload" | jq -r --arg t "$tool" '
      ($t + " " + ((.tool_input // {})
        | del(.description, .timeout, .run_in_background, .thought)
        | tojson))' 2>/dev/null | cut -c1-400)"
    health_observe "$feature" tool tool "$tool" ok "$ok" step_key "$step_key"

    # edit_churn: same file, overlapping range. Line numbers are not in the
    # tool input, so we locate the edit in the file on disk. When we cannot
    # (the string moved, the file is gone, Write replaced everything), the
    # range is left empty and health.sh falls back to same-file recurrence and
    # labels the finding as the weaker one.
    case "$tool" in
      Edit|Write|NotebookEdit|MultiEdit)
        file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)"
        if [ -n "$file" ]; then
          old="$(printf '%s' "$payload" | jq -r '.tool_input.old_string // ""' 2>/dev/null)"
          ls_line=''; le_line=''
          if [ -n "$old" ] && [ -r "$file" ]; then
            first="$(printf '%s' "$old" | head -1)"
            n="$(printf '%s' "$old" | grep -c '' 2>/dev/null || printf 1)"
            ls_line="$(grep -n -F -m1 -- "$first" "$file" 2>/dev/null | cut -d: -f1)"
            case "$ls_line" in ''|*[!0-9]*) ls_line='' ;; *) le_line=$(( ls_line + ${n:-1} - 1 )) ;; esac
          fi
          health_observe "$feature" edit file "$file" tool "$tool" \
            line_start "${ls_line:-}" line_end "${le_line:-}"
        fi
        ;;
    esac

    observe_context_pressure
    ;;

  *)
    # An event we were not wired for. Record it once so drift is visible in the
    # health file rather than silently ignored.
    health_observe "$feature" unknown_event event "$event"
    ;;
esac

exit 0
