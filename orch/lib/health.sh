#!/bin/bash
# health.sh - the degradation detector.
#
# This is the sensor for the control law in §4. The matched-budget ablation
# [P20] found single-agent matched or beat multi-agent at every thinking-token
# budget tested across five topologies and four models, and multi-agent
# overtook only when context was deliberately corrupted to ~70%. Read plainly,
# orchestration is worth its cost exactly when the solo agent's context is
# already degraded. So orch measures that condition instead of assuming it.
#
# Every signal here is mechanical. None costs a model call. That matters: a
# detector that needs an LLM to decide whether to spend LLM budget has already
# lost the argument.

[ -n "${ORCH_HEALTH_SOURCED:-}" ] && return 0
ORCH_HEALTH_SOURCED=1

# shellcheck source=ledger.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ledger.sh"
# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"

# Thresholds. Defaults are the numbers §4.1 argues for; each is overridable so
# `escalation_precision` can actually be tuned rather than merely reported.
: "${ORCH_T_CONTEXT_PCT:=70}"       # [P20]'s literal condition
: "${ORCH_T_REPETITION:=3}"         # MAST's most frequent failure mode, 15.7% [P9]
: "${ORCH_T_FAILURE_PCT:=25}"
: "${ORCH_T_FAILURE_WINDOW:=20}"
: "${ORCH_T_OSCILLATION:=2}"
: "${ORCH_T_EDIT_CHURN:=3}"
: "${ORCH_HEALTH_WINDOW:=80}"       # observations considered "recent"

health_path() { printf '%s/health.jsonl' "$(orch_feature_dir "$1")"; }

# health_observe <feature> <kind> [key value]...
health_observe() {
  local feature="$1" kind="$2"; shift 2
  local line
  line="$(orch_json ts "$(now_iso)" kind "$kind" session "${CLAUDE_CODE_SESSION_ID:-}" "$@" 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  orch_append_jsonl "$(health_path "$feature")" "$line" 2>/dev/null || true
  return 0
}

_health_recent() {  # _health_recent <feature>
  local f; f="$(health_path "$1")"
  [ -r "$f" ] || return 0
  tail -n "$ORCH_HEALTH_WINDOW" "$f" 2>/dev/null | jq -c 'select(type=="object")' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
#
# health_signals prints a JSON array of firing signals:
#   [{"signal":"step_repetition","value":4,"threshold":3,"detail":"Bash …"}]
# Empty array on a clean run.
#
# A rule and its consequence: §4.1 says a parse failure must never abort a run,
# so every query here is allowed to fail. But a query that fails silently is
# worse than one that fails loudly - a broken detector reports a clean run,
# which is indistinguishable from a healthy one and is exactly how a control
# law stops controlling anything. So a failed query warns on stderr, names
# itself, and the remaining signals are still returned.

# _hs <name> <jq-prog> [jq-args...]  - run one signal query over stdin.
_hs() {
  local name="$1" prog="$2"; shift 2
  local out
  if ! out="$(jq -s -c "$@" "$prog" 2>/dev/null)" || [ -z "$out" ]; then
    warn "health: the $name query failed; that signal is NOT being evaluated"
    printf '[]'
    return 0
  fi
  printf '%s' "$out"
}

_hs_merge() {  # _hs_merge <accumulator> <addition>
  printf '%s %s' "$1" "$2" | jq -s -c 'add' 2>/dev/null || printf '%s' "$1"
}

health_signals() {  # health_signals <feature>
  local feature="$1" obs sigs='[]' add ev

  obs="$(_health_recent "$feature")"

  # compaction - the strongest single signal, and free.
  add="$(printf '%s' "$obs" | _hs compaction '
    [.[] | select(.kind=="compaction")] as $c
    | if ($c|length) > 0
      then [{signal:"compaction", value:($c|length), threshold:1,
             detail:"context was exhausted and compacted"}]
      else [] end')"
  sigs="$(_hs_merge "$sigs" "$add")"

  # context_pressure - the literal [P20] condition.
  add="$(printf '%s' "$obs" | _hs context_pressure '
    ([.[] | select(.kind=="context") | (.pct|tonumber?) // 0] | max // 0) as $m
    | if $m > $t
      then [{signal:"context_pressure", value:$m, threshold:$t,
             detail:("transcript usage at \($m)% of the window")}]
      else [] end' --argjson t "$ORCH_T_CONTEXT_PCT")"
  sigs="$(_hs_merge "$sigs" "$add")"

  # step_repetition - identical tool + normalized args, N times.
  add="$(printf '%s' "$obs" | _hs step_repetition '
    [.[] | select(.kind=="tool") | select((.step_key // "") != "") | .step_key]
    | group_by(.) | map({k: .[0], n: length}) | map(select(.n >= $t))
    | if length > 0
      then (sort_by(-.n)[0]) as $w
        | [{signal:"step_repetition", value:$w.n, threshold:$t,
            detail:("same tool call repeated \($w.n)x: \($w.k)")}]
      else [] end' --argjson t "$ORCH_T_REPETITION")"
  sigs="$(_hs_merge "$sigs" "$add")"

  # tool_failure_rate - thrashing, over a trailing window. The window is fixed
  # rather than "everything so far" so that a long healthy run cannot dilute a
  # burst of failures into invisibility.
  add="$(printf '%s' "$obs" | _hs tool_failure_rate '
    [.[] | select(.kind=="tool")] as $all
    | if ($all | length) >= $w
      then ($all[-$w:]) as $win
        | ([$win[] | select(.ok=="false")] | length) as $bad
        | (($bad * 100) / $w) as $rate
        | if $rate > $t
          then [{signal:"tool_failure_rate", value:($rate|floor), threshold:$t,
                 detail:("\($bad) of the last \($w) tool calls failed")}]
          else [] end
      else [] end' --argjson t "$ORCH_T_FAILURE_PCT" --argjson w "$ORCH_T_FAILURE_WINDOW")"
  sigs="$(_hs_merge "$sigs" "$add")"

  # edit_churn - repair without understanding. Ranges come from the hook when
  # it could locate the edit; when it could not, same-file recurrence is the
  # weaker fallback and is labelled as such rather than quietly promoted.
  add="$(printf '%s' "$obs" | _hs edit_churn '
    [.[] | select(.kind=="edit") | select((.file // "") != "")]
    | group_by(.file)
    | map({file: .[0].file, n: length,
           overlaps: ([ .[] | select((.line_start // "") != "") ]
                      | sort_by(.line_start|tonumber)
                      | [ range(0; length-1) as $i
                          | select((.[$i].line_end|tonumber) >= (.[$i+1].line_start|tonumber)) ]
                      | length)})
    | map(select(.n >= $t))
    | if length > 0
      then (sort_by(-.n)[0]) as $w
        | [{signal:"edit_churn", value:$w.n, threshold:$t,
            detail:("\($w.file) edited \($w.n)x" +
                    (if $w.overlaps > 0 then " with \($w.overlaps) overlapping ranges"
                     else " (ranges unknown; same-file fallback)" end))}]
      else [] end' --argjson t "$ORCH_T_EDIT_CHURN")"
  sigs="$(_hs_merge "$sigs" "$add")"

  # test_oscillation - read from attested runs, not from observations. If a
  # label went pass -> fail -> pass, the loop is not converging on anything.
  ev="$(evidence_path "$feature")"
  if [ -r "$ev" ]; then
    add="$(_hs test_oscillation '
      [.[] | select(type=="object")]
      | group_by(.label)
      | map({label: .[0].label,
             flips: ([.[] | (if (.exit_code // 1) == 0 then "p" else "f" end)]
                     | [ range(0; length-1) as $i | select(.[$i] != .[$i+1]) ] | length)})
      | map(select(.flips >= $t))
      | if length > 0
        then (sort_by(-.flips)[0]) as $w
          | [{signal:"test_oscillation", value:$w.flips, threshold:$t,
              detail:("\($w.label) flipped result \($w.flips)x across attested runs")}]
        else [] end' --argjson t "$ORCH_T_OSCILLATION" < "$ev")"
    sigs="$(_hs_merge "$sigs" "$add")"
  fi

  printf '%s' "${sigs:-[]}"
}

health_signal_count() { health_signals "$1" | jq 'length' 2>/dev/null || printf '0'; }

health_has_signal() {  # health_has_signal <feature> <name>
  health_signals "$1" | jq -e --arg s "$2" 'any(.[]; .signal==$s)' >/dev/null 2>&1
}
