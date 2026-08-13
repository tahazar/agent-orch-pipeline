#!/bin/bash
# escalate.sh - the control law.
#
# The ladder is shared with lib/tier.sh: rungs 0-2 are the three tiers a
# developer can choose up front, and rungs 3-5 are configurations only the
# evidence can ask for. Escalation is one-way within a feature, always logged
# with the signal that fired, and always reset for the next feature: persistent
# escalation across many features is a fact about the codebase or the prompts,
# not about the feature, and it belongs in the report rather than in a silently
# ratcheting counter.
#
#   0  quick        developer-chosen  the developer writes its own tests
#   1  standard     developer-chosen  + an independent code-reviewer
#   2  strict       developer-chosen  + a test-engineer writing tests blind
#   3  best-of-N    signal-forced     a failed repair cycle, or test_oscillation
#   4  diagnose     signal-forced     a second repair cycle failing on one finding
#   5  human        signal-forced     rung 4 produced no distinguishing experiment
#
# Signals can raise a developer-chosen tier too — asking for `quick` does not
# buy immunity from the evidence, it just sets the floor to start from.
#
# Rung 5's trigger is the one worth defending: we escalate to a human when no
# falsifiable experiment can be constructed, not when a try counter runs out.
# Under invariant 5 that is the only correct stopping condition, and it is a
# better use of the human than "three attempts failed".

[ -n "${ORCH_ESCALATE_SOURCED:-}" ] && return 0
ORCH_ESCALATE_SOURCED=1

# shellcheck source=health.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/health.sh"

: "${ORCH_T_DIFF_FILES:=3}"
ORCH_MAX_RUNG=5

escalate_rung_name() {
  case "$1" in
    0) printf 'quick' ;;
    1) printf 'standard' ;;
    2) printf 'strict' ;;
    3) printf 'best-of-N' ;;
    4) printf 'diagnose' ;;
    5) printf 'human' ;;
    *) printf 'unknown' ;;
  esac
}

# The ledger is the only rung state. Deriving it rather than caching it means
# there is no second copy to fall out of sync, and `orch report` reads the same
# rows the ladder acted on.
escalate_rung() {  # escalate_rung <feature>
  local r
  r="$(ledger_read "$1" | jq -s -r '
    [.[] | select(type=="object" and .event=="escalation") | (.rung|tonumber?) // 0]
    | max // 0' 2>/dev/null)"
  printf '%s' "${r:-0}"
}

# The branch a feature is measured against. Explicit override, then the
# remote's own idea of its default, then whatever `.orch/base-branch` recorded
# at `feature start`, then main. Guessing "main" first is how a repo whose
# default is `master` or `trunk` silently reports a zero-file diff and never
# escalates.
escalate_base_branch() {
  local b
  if [ -n "${ORCH_BASE_BRANCH:-}" ]; then printf '%s' "$ORCH_BASE_BRANCH"; return 0; fi
  b="$(git -C "${ORCH_REPO:-.}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$b" ] || b="$(head -1 "${ORCH_REPO:-.}/.orch/base-branch" 2>/dev/null | tr -d ' \t\r\n')"
  if [ -z "$b" ]; then
    for b in main master trunk; do
      git -C "${ORCH_REPO:-.}" rev-parse --verify --quiet "$b" >/dev/null 2>&1 && break
      b=''
    done
  fi
  printf '%s' "${b:-main}"
}

# Files the feature branch changes against its base. Escalation criterion for
# rung 1, and cheap enough to evaluate on every check.
escalate_diff_files() {
  local base n
  base="$(escalate_base_branch)"
  n="$(git -C "${ORCH_REPO:-.}" diff --name-only "$base...HEAD" 2>/dev/null | grep -c . || true)"
  printf '%s' "${n:-0}"
}

_ledger_count() {  # _ledger_count <feature> <event>
  local n
  n="$(ledger_read "$1" | jq -s -r --arg e "$2" '[.[] | select(type=="object" and .event==$e)] | length' 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# Repair cycles that failed on the same finding, worst finding wins. This is
# what separates rung 3 from rung 4: one failure means try other approaches,
# two on the same finding means stop generating and start diagnosing.
_repeat_repair_failures() {  # _repeat_repair_failures <feature>
  local n
  n="$(ledger_read "$1" | jq -s -r '
    [.[] | select(type=="object" and .event=="repair.failed") | .finding // "unknown"]
    | group_by(.) | map(length) | max // 0' 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# escalate_required <feature> -> prints the rung the evidence supports.
# Never lower than the current rung; escalation is one-way.
escalate_required() {
  local feature="$1" cur sigs n want=0
  cur="$(escalate_rung "$feature")"
  sigs="$(health_signals "$feature")"
  n="$(printf '%s' "$sigs" | jq 'length' 2>/dev/null || printf '0')"

  [ "${n:-0}" -ge 1 ] && want=1
  [ "$(escalate_diff_files)" -gt "$ORCH_T_DIFF_FILES" ] && want=1
  [ "${n:-0}" -ge 2 ] && want=2
  [ "$(_ledger_count "$feature" review.blocking)" -gt 0 ] && want=2
  [ "$(_ledger_count "$feature" repair.failed)" -gt 0 ] && want=3
  printf '%s' "$sigs" | jq -e 'any(.[]; .signal=="test_oscillation")' >/dev/null 2>&1 && want=3
  [ "$(_repeat_repair_failures "$feature")" -ge 2 ] && want=4
  [ "$(_ledger_count "$feature" diagnose.inconclusive)" -gt 0 ] && want=5

  [ "$want" -lt "$cur" ] && want="$cur"
  printf '%s' "$want"
}

# Why we are where we are: the firing signals plus the ledger events that
# crossed a criterion. Logged with every escalation so the report can compute
# escalation_precision against a reason, not a bare number.
escalate_reason() {  # escalate_reason <feature> <target-rung>
  local feature="$1" target="$2" sigs parts=''
  sigs="$(health_signals "$feature" | jq -r '[.[].signal] | join(",")' 2>/dev/null)"
  [ -n "$sigs" ] && parts="signals=$sigs"
  case "$target" in
    1) [ "$(escalate_diff_files)" -gt "$ORCH_T_DIFF_FILES" ] && parts="${parts:+$parts; }diff_files=$(escalate_diff_files)" ;;
    2) [ "$(_ledger_count "$feature" review.blocking)" -gt 0 ] && parts="${parts:+$parts; }review.blocking" ;;
    3) [ "$(_ledger_count "$feature" repair.failed)" -gt 0 ] && parts="${parts:+$parts; }repair.failed" ;;
    4) parts="${parts:+$parts; }repair.failed x$(_repeat_repair_failures "$feature") on one finding" ;;
    5) parts="${parts:+$parts; }no distinguishing experiment" ;;
  esac
  printf '%s' "${parts:-no signal}"
}

# escalate_to <feature> <rung> [reason] - one-way, idempotent, always logged.
escalate_to() {
  local feature="$1" rung="$2" reason="${3:-}" cur
  case "$rung" in ''|*[!0-9]*) die "escalate: rung must be a number" ;; esac
  [ "$rung" -le "$ORCH_MAX_RUNG" ] || die "escalate: rung $rung above the ladder (max $ORCH_MAX_RUNG)"
  cur="$(escalate_rung "$feature")"
  if [ "$rung" -le "$cur" ]; then
    printf '%s is at rung %s (%s); nothing to do.\n' "$feature" "$cur" "$(escalate_rung_name "$cur")"
    return 0
  fi
  [ -n "$reason" ] || reason="$(escalate_reason "$feature" "$rung")"
  ORCH_LEDGER_FEATURE="$feature" ledger_append escalation \
    rung:raw "$rung" from_rung:raw "$cur" rung_name "$(escalate_rung_name "$rung")" reason "$reason" \
    signals "$(health_signals "$feature" | jq -c '.' 2>/dev/null)"
  printf '%s escalated %s -> %s (%s): %s\n' \
    "$feature" "$cur" "$rung" "$(escalate_rung_name "$rung")" "$reason"
}

# The default entry point: evaluate the evidence and escalate if it warrants.
escalate_check() {  # escalate_check <feature>
  local feature="$1" cur want
  cur="$(escalate_rung "$feature")"
  want="$(escalate_required "$feature")"
  if [ "$want" -gt "$cur" ]; then
    escalate_to "$feature" "$want"
    return 0
  fi
  printf '%s stays at rung %s (%s).\n' "$feature" "$cur" "$(escalate_rung_name "$cur")"
}
