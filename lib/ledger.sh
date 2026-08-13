#!/bin/bash
# ledger.sh - the append-only event and cost record.
#
# A pipeline with no instrumentation cannot answer whether it helped, and
# agents typing "~13k (est.)" at each other is not instrumentation — neither is
# a cost report an LLM wrote from memory. Every number in `orch report` comes
# from this file or from a session transcript, and nothing in orch asks a model
# how much it spent.
#
# One ledger per feature at docs/features/<F>/ledger.jsonl, plus
# docs/features/_orch/ledger.jsonl for events that happen outside a feature.
# Appends are O_APPEND single writes, so concurrent agents do not interleave.

[ -n "${ORCH_LEDGER_SOURCED:-}" ] && return 0
ORCH_LEDGER_SOURCED=1

# shellcheck source=common.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ledger_path() {  # ledger_path [feature]
  local f="${1:-$(orch_current_feature)}"
  orch_valid_feature "$f" || f=_orch
  printf '%s/ledger.jsonl' "$(orch_feature_dir "$f")"
}

# ledger_append <event> [key value]...
#
# Never fails the caller. A ledger write that cannot happen is a lost
# observation, and losing an observation must not abort a run - the same
# discipline §4.1 applies to transcript parsing.
ledger_append() {
  local event="$1"; shift
  local feature line
  feature="${ORCH_LEDGER_FEATURE:-$(orch_current_feature)}"
  # by_role, not role: several events (agent.spawned, agent.recycled) carry a
  # `role` field meaning "the role this event is about", which is not the same
  # thing as the role of the session writing the row. by_role is the writer,
  # and it is what lets `orch report` split usage into coordination versus
  # production instead of asking anyone to estimate it.
  line="$(orch_json \
    ts "$(now_iso)" \
    event "$event" \
    actor "$(orch_actor)" \
    feature "$feature" \
    sha "$(orch_head_sha)" \
    session "${CLAUDE_CODE_SESSION_ID:-}" \
    by_role "${ORCH_ROLE:-}" \
    "$@" 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  orch_append_jsonl "$(ledger_path "$feature")" "$line" 2>/dev/null || true
  return 0
}

# Every ledger line for a feature, or for all features when given "--all".
ledger_read() {  # ledger_read <feature|--all>
  local f="$1" root
  root="$(orch_repo_root)/docs/features"
  [ -d "$root" ] || return 0
  if [ "$f" = "--all" ]; then
    find "$root" -name ledger.jsonl -type f 2>/dev/null | sort | while IFS= read -r p; do
      cat "$p" 2>/dev/null
    done
  else
    cat "$root/$f/ledger.jsonl" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------
#
# Real usage comes from the session transcripts under
# ~/.claude/projects/<slug>/<uuid>.jsonl, whose assistant events carry a usage
# object. That format is undocumented and the vendor's own guidance is to treat
# entries as opaque, so: tolerate unknown shapes, warn once, never abort.

ledger_transcript_dir() {
  printf '%s' "${ORCH_TRANSCRIPTS:-$HOME/.claude/projects}"
}

# Sum token usage for one session id across all project transcripts.
# Prints a JSON object; zeros when the transcript cannot be found or read.
ledger_session_usage() {  # ledger_session_usage <session-id>
  local sid="$1" dir out
  dir="$(ledger_transcript_dir)"
  if [ -z "$sid" ] || [ ! -d "$dir" ]; then
    printf '{"session":"%s","found":false,"input":0,"output":0,"cache_read":0,"cache_write":0}' "$sid"
    return 0
  fi
  out="$(find "$dir" -name "${sid}.jsonl" -type f 2>/dev/null | head -1)"
  if [ -z "$out" ]; then
    printf '{"session":"%s","found":false,"input":0,"output":0,"cache_read":0,"cache_write":0}' "$sid"
    return 0
  fi
  # `-R` + fromjson? guards against a partially-written final line, which is
  # normal for a live session.
  jq -Rrs --arg sid "$sid" '
    [ split("\n")[] | select(length>0) | (fromjson? // empty)
      | (.message.usage // .usage // empty) ]
    | {session: $sid, found: true,
       input:       ([.[].input_tokens]               | map(select(type=="number")) | add // 0),
       output:      ([.[].output_tokens]              | map(select(type=="number")) | add // 0),
       cache_read:  ([.[].cache_read_input_tokens]    | map(select(type=="number")) | add // 0),
       cache_write: ([.[].cache_creation_input_tokens]| map(select(type=="number")) | add // 0)}
  ' "$out" 2>/dev/null || printf '{"session":"%s","found":false,"input":0,"output":0,"cache_read":0,"cache_write":0}' "$sid"
}

# Usage for every session that appears in a feature's ledger.
ledger_feature_usage() {  # ledger_feature_usage <feature>
  local feature="$1" sid
  ledger_read "$feature" \
    | jq -r 'select(type=="object") | .session // empty' 2>/dev/null \
    | sort -u | while IFS= read -r sid; do
        [ -n "$sid" ] && ledger_session_usage "$sid"
      done | jq -s '
        {sessions: length,
         found: ([.[] | select(.found)] | length),
         input: (map(.input) | add // 0),
         output: (map(.output) | add // 0),
         cache_read: (map(.cache_read) | add // 0),
         cache_write: (map(.cache_write) | add // 0)}' 2>/dev/null \
    || printf '{"sessions":0,"found":0,"input":0,"output":0,"cache_read":0,"cache_write":0}'
}

# Output tokens split by the role that spent them, from by_role on the rows
# each session wrote. Coordination is director+auditor+tech-lead — the roles
# that ship nothing directly. The v1 post-mortem measured them at 28% of the
# session, by hand; this makes the same number fall out of the ledger.
ledger_feature_role_usage() {  # ledger_feature_role_usage <feature>
  local feature="$1" pairs sid role
  pairs="$(ledger_read "$feature" | jq -s -r '
    [.[] | select(type=="object" and (.session // "") != "" and (.by_role // "") != "")]
    | group_by(.session) | map("\(.[0].session) \(.[-1].by_role)") | .[]' 2>/dev/null)"
  if [ -z "$pairs" ]; then printf '{"attributed":0,"coordination":0,"production":0,"share":null}'; return 0; fi
  printf '%s\n' "$pairs" | while IFS=' ' read -r sid role; do
    [ -n "$sid" ] || continue
    ledger_session_usage "$sid" | jq -c --arg role "$role" '. + {role: $role}'
  done | jq -s '
    [.[] | select(.found)] as $f
    | ([$f[] | select(.role=="director" or .role=="auditor" or .role=="tech-lead") | .output] | add // 0) as $coord
    | ([$f[] | select(.role=="developer" or .role=="test-engineer" or .role=="code-reviewer") | .output] | add // 0) as $prod
    | {attributed: ($coord + $prod),
       coordination: $coord, production: $prod,
       share: (if ($coord + $prod) == 0 then null else (($coord * 100 / ($coord + $prod)) | floor) end)}' 2>/dev/null \
    || printf '{"attributed":0,"coordination":0,"production":0,"share":null}'
}
