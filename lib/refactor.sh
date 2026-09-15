#!/bin/bash
# refactor.sh - the refactor pass (docs/AGENT-TDD.md, phase 5).
#
# Red-green-refactor's third step is where design comes from, and it is the
# step an agent skips: it feels no duplication, so nothing pushes it back
# into the code once the tests are green. Böckeler's traces [P42] show
# exactly that — locally minimal changes, early design hardening, no return.
# This file makes the step unskippable by making it a separate pass with a
# mechanical trigger, a frozen invariant and a mechanical exit.
#
#   trigger    always at strict; at standard when an attested metric
#              (complexity, duplication) or the feature's diff size is over
#              its threshold. Every threshold is ours and unvalidated.
#   invariant  the oracle is frozen (ORACLE_MOVED applies), the statement is
#              frozen, and no new escape hatch may appear.
#   exit       build and tests attested green and clean at the refactor
#              head; the oracle unchanged; the axiom count not up; the
#              refactor's own diff no larger than the feature's diff was;
#              every metric attested before is attested after and not worse.
#              If any of that fails the pass is DISCARDED — the pre-refactor
#              commit stands, the numbers go on the ledger. No repair loop.
#
# The pass runs in its own worktree on a fresh developer context, for the
# same reason a reviewer gets fresh context: an agent asked to refactor its
# own code is anchored to the reasons it wrote it that way.

[ -n "${ORCH_REFACTOR_SOURCED:-}" ] && return 0
ORCH_REFACTOR_SOURCED=1

# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"
# shellcheck source=statement.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statement.sh"
# shellcheck source=axioms.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/axioms.sh"
# shellcheck source=escalate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/escalate.sh"

: "${ORCH_REFACTOR:=trigger}"          # always | never | trigger
: "${ORCH_T_REFACTOR_LINES:=200}"      # feature diff lines that trigger a pass at standard
: "${ORCH_T_COMPLEXITY:=}"             # attested `complexity` number; empty = not a trigger
: "${ORCH_T_DUPLICATION:=}"            # attested `duplication` number; empty = not a trigger
ORCH_REFACTOR_METRICS="complexity duplication"

refactor_root()   { printf '%s/.orch/worktrees/%s/refactor' "${ORCH_REPO:-$(orch_repo_root)}" "$1"; }
refactor_branch() { printf 'orch/%s/refactor' "$1"; }

_refactor_last() {  # _refactor_last <feature> <event> -> row or nothing
  ledger_read "$1" | jq -c -s --arg e "$2" '
    [.[] | select(type=="object" and .event==$e)] | if length==0 then empty else .[-1] end' 2>/dev/null
}

# The number a metric run printed last, at a given repo (main checkout or a
# worktree), or empty. Same rule as best-of-N: the command has to print it.
_refactor_metric() {  # _refactor_metric <repo> <feature> <label>
  ORCH_REPO="$1" evidence_latest "$2" "$3" 2>/dev/null \
    | jq -r 'select(.exit_code==0) | .stdout_tail // ""' 2>/dev/null \
    | tr -d '\r' | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1
}

_refactor_diff_lines() {  # _refactor_diff_lines <from> <to>
  git -C "${ORCH_REPO:-$(orch_repo_root)}" diff --numstat "$1" "$2" -- . ':(exclude)docs/features' 2>/dev/null \
    | awk '{a+=$1; d+=$2} END {print (a+d)+0}'
}

# refactor_should_run <feature> -> prints the reason and returns 0, or
# prints why not and returns 1. Records the decision either way.
refactor_should_run() {
  local feature="$1" rung reason='' base lines m v
  rung="$(escalate_rung "$feature")"
  case "$ORCH_REFACTOR" in
    never)  reason='' ;;
    always) reason='ORCH_REFACTOR=always' ;;
    *)
      if [ "${rung:-0}" -ge 2 ]; then
        reason="rung $rung"
      else
        base="$(git -C "$ORCH_REPO" merge-base "$(escalate_base_branch)" HEAD 2>/dev/null || escalate_base_branch)"
        lines="$(_refactor_diff_lines "$base" HEAD)"
        [ "${lines:-0}" -gt "$ORCH_T_REFACTOR_LINES" ] && reason="diff $lines lines > $ORCH_T_REFACTOR_LINES"
        for m in $ORCH_REFACTOR_METRICS; do
          v="$(_refactor_metric "$ORCH_REPO" "$feature" "$m")"
          [ -n "$v" ] || continue
          case "$m" in
            complexity)  [ -n "$ORCH_T_COMPLEXITY" ]  && [ "${v%%.*}" -gt "$ORCH_T_COMPLEXITY" ]  && reason="${reason:+$reason; }complexity $v > $ORCH_T_COMPLEXITY" ;;
            duplication) [ -n "$ORCH_T_DUPLICATION" ] && [ "${v%%.*}" -gt "$ORCH_T_DUPLICATION" ] && reason="${reason:+$reason; }duplication $v > $ORCH_T_DUPLICATION" ;;
          esac
        done
      fi ;;
  esac
  if [ -n "$reason" ]; then
    ORCH_LEDGER_FEATURE="$feature" ledger_append refactor.triggered reason "$reason"
    printf 'refactor pass for %s: yes — %s\n' "$feature" "$reason"
    return 0
  fi
  ORCH_LEDGER_FEATURE="$feature" ledger_append refactor.skipped reason "no trigger fired (ORCH_REFACTOR=$ORCH_REFACTOR, rung ${rung:-0})"
  printf 'refactor pass for %s: no — no trigger fired at rung %s\n' "$feature" "${rung:-0}"
  return 1
}

# refactor_start <feature>
#
# Preconditions are the invariant: green, clean, oracle as frozen. Creates
# the worktree, writes its orders, records the numbers the exit is judged
# against, and prints the spawn for a fresh developer whose cwd is the
# worktree.
refactor_start() {
  local feature="$1" wt br pre base pre_lines metrics='{}' m v msg
  orch_valid_feature "$feature" || die "refactor: invalid feature '$feature'"
  for m in build tests; do
    msg="$(evidence_verify "$feature" "$m" --claim pass --fresh 2>&1)" \
      || die "refactor start: $m is not attested green and clean at HEAD — the pass starts from green or not at all
$msg"
  done
  msg="$(oracle_check "$feature" 2>&1)" || die "refactor start: $msg"
  msg="$(statement_check "$feature" 2>&1)" || die "refactor start: $msg"

  wt="$(refactor_root "$feature")"; br="$(refactor_branch "$feature")"
  [ ! -e "$wt" ] || die "refactor start: a pass is already underway at $wt — finish or discard it first"
  pre="$(orch_head_sha)"
  base="$(git -C "$ORCH_REPO" merge-base "$(escalate_base_branch)" "$pre" 2>/dev/null || escalate_base_branch)"
  pre_lines="$(_refactor_diff_lines "$base" "$pre")"
  for m in $ORCH_REFACTOR_METRICS; do
    v="$(_refactor_metric "$ORCH_REPO" "$feature" "$m")"
    [ -n "$v" ] && metrics="$(printf '%s' "$metrics" | jq -c --arg m "$m" --arg v "$v" '.[$m]=($v|tonumber)')"
  done

  mkdir -p "$(dirname "$wt")"
  git -C "$ORCH_REPO" branch -D "$br" >/dev/null 2>&1 || true
  git -C "$ORCH_REPO" worktree add -q -b "$br" "$wt" "$pre" || die "refactor start: could not create worktree $wt"
  mkdir -p "$wt/docs/features/$feature"
  cat > "$wt/docs/features/$feature/REFACTOR.md" <<EOM
# Refactor pass — $feature

You are a fresh developer with one job: **design**. The feature is green at
$(printf '%s' "$pre" | cut -c1-12). Make the code better without changing what it does.

## The invariant

- Every test — the oracle and test/dev — is green before you start and green
  when you finish. Attest both in THIS worktree:
      orch run --feature $feature --label build -- <build command>
      orch run --feature $feature --label tests -- <test command>
- You do not touch the oracle, the statement, or trusted configuration.
- No new skip, ignore, disabled lint or changed test config.

## The exit

The pass is KEPT only if all of these hold at your final commit; otherwise it
is discarded and the pre-refactor commit stands. There is no repair loop.

- build and tests attested green, over a committed tree
- the oracle tree is unchanged (ORACLE_MOVED discards)
- no new escape hatch (the axiom count is not up)
- your diff against $(printf '%s' "$pre" | cut -c1-12) is no larger than the feature's diff was: $pre_lines lines
$(printf '%s' "$metrics" | jq -r 'to_entries[] | "- \(.key) attested again and not above \(.value)"')

Commit, attest, then tell the director:  orch refactor finish $feature
EOM
  ORCH_LEDGER_FEATURE="$feature" ledger_append refactor.started \
    pre_sha "$pre" base_sha "$base" pre_diff_lines:raw "$pre_lines" metrics:raw "$metrics" worktree "$wt" branch "$br"
  printf 'refactor pass for %s started at %s\n  worktree %s\n  exit: tests green, oracle unchanged, no new axioms, diff <= %s lines%s\n' \
    "$feature" "$(printf '%s' "$pre" | cut -c1-12)" "$wt" "$pre_lines" \
    "$(printf '%s' "$metrics" | jq -r 'if length==0 then "" else ", " + (to_entries | map("\(.key) <= \(.value)") | join(", ")) end')"
}

# refactor_finish <feature>
#
# Judges the pass at the worktree's HEAD against the numbers recorded at
# start. Keeps it by advancing the feature branch (fast-forward only) or
# discards it; either way the worktree is removed and the verdict is on the
# ledger with every number it rested on.
refactor_finish() {
  local feature="$1" wt br row pre base pre_lines metrics post post_lines reason='' m pre_v post_v n_ax msg cur after
  wt="$(refactor_root "$feature")"; br="$(refactor_branch "$feature")"
  row="$(_refactor_last "$feature" refactor.started)"
  [ -n "$row" ] && [ -d "$wt" ] || die "refactor finish: no pass underway for $feature (orch refactor start)"
  pre="$(printf '%s' "$row" | jq -r .pre_sha)"; base="$(printf '%s' "$row" | jq -r .base_sha)"
  pre_lines="$(printf '%s' "$row" | jq -r .pre_diff_lines)"; metrics="$(printf '%s' "$row" | jq -c .metrics)"
  post="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"

  post_lines="$(_refactor_diff_lines "$pre" "$post")"
  if [ "$post" = "$pre" ] || [ "${post_lines:-0}" = "0" ]; then
    reason="nothing changed outside docs/features — a pass that changes nothing is not kept, it is skipped"
  fi
  if [ -z "$reason" ]; then
    for m in build tests; do
      msg="$(ORCH_REPO="$wt" evidence_verify "$feature" "$m" --claim pass --fresh 2>&1)" \
        || { reason="$m not attested green and clean at the refactor head: $(printf '%s' "$msg" | head -1)"; break; }
    done
  fi
  if [ -z "$reason" ]; then
    msg="$(oracle_check "$feature" "$post" 2>&1)" || reason="$(printf '%s' "$msg" | head -1)"
  fi
  if [ -z "$reason" ]; then
    n_ax="$(axioms_scan "$pre" "$post" | jq 'length')"
    [ "${n_ax:-0}" = "0" ] || reason="$n_ax new escape hatch(es) in the refactor"
  fi
  if [ -z "$reason" ]; then
    [ "${post_lines:-0}" -le "${pre_lines:-0}" ] \
      || reason="the refactor's diff ($post_lines lines) is larger than the feature's was ($pre_lines) — that is a rewrite"
  fi
  if [ -z "$reason" ]; then
    for m in $(printf '%s' "$metrics" | jq -r 'keys[]'); do
      pre_v="$(printf '%s' "$metrics" | jq -r --arg m "$m" '.[$m]')"
      post_v="$(_refactor_metric "$wt" "$feature" "$m")"
      [ -n "$post_v" ] || { reason="$m was attested before the pass and not after"; break; }
      awk -v a="$post_v" -v b="$pre_v" 'BEGIN { exit !(a+0 <= b+0) }' \
        || { reason="$m got worse: $pre_v -> $post_v"; break; }
    done
  fi

  if [ -n "$reason" ]; then
    ORCH_LEDGER_FEATURE="$feature" ledger_append refactor.discarded \
      pre_sha "$pre" post_sha "$post" reason "$reason" post_diff_lines:raw "${post_lines:-0}"
    git -C "$ORCH_REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$ORCH_REPO" branch -m "$br" "$br-discarded-$(date -u +%Y%m%dT%H%M%S)" >/dev/null 2>&1 || true
    printf 'refactor pass for %s DISCARDED: %s\nThe pre-refactor commit %s stands. The branch is kept for the record.\n' \
      "$feature" "$reason" "$(printf '%s' "$pre" | cut -c1-12)" >&2
    return 1
  fi

  # Keep: advance the feature branch to the refactor head, fast-forward only.
  # The after-metrics live in the worktree's evidence; read them before it goes.
  after="$(for m in $(printf '%s' "$metrics" | jq -r 'keys[]'); do
             printf '{"%s": %s}\n' "$m" "$(_refactor_metric "$wt" "$feature" "$m")"
           done | jq -s -c 'add // {}')"
  cur="$(git -C "$ORCH_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$(git -C "$ORCH_REPO" rev-parse HEAD)" = "$pre" ]; then
    git -C "$ORCH_REPO" merge -q --ff-only "$post" >/dev/null 2>&1 \
      || die "refactor finish: could not fast-forward $cur to $post — the branch moved during the pass"
  else
    die "refactor finish: the feature branch moved during the pass (HEAD is not $pre); nothing was kept"
  fi
  git -C "$ORCH_REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$ORCH_REPO" branch -D "$br" >/dev/null 2>&1 || true
  ORCH_LEDGER_FEATURE="$feature" ledger_append refactor.kept \
    pre_sha "$pre" post_sha "$post" pre_diff_lines:raw "$pre_lines" post_diff_lines:raw "$post_lines" \
    metrics_before:raw "$metrics" metrics_after:raw "${after:-{\}}"
  printf 'refactor pass for %s KEPT: %s -> %s (%s lines changed)\n' \
    "$feature" "$(printf '%s' "$pre" | cut -c1-12)" "$(printf '%s' "$post" | cut -c1-12)" "$post_lines"
}
