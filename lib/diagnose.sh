#!/bin/bash
# diagnose.sh - the anti-anchoring diagnostic stage (rung 4).
#
# Sequential investigation anchors: once one theory has been explored,
# everything after it is biased toward that theory. The documented remedy is
# parallel competing-hypothesis debugging [P1]. It is read-only, so it does not
# violate invariant 1, and it is the one place in a coding workflow where
# parallelism is genuinely well supported.
#
# The rule that makes this different from a brainstorm: each hypothesis must
# return a FALSIFIABLE PREDICTION and the exact command that tests it. Then
# `orch run` executes all K and the results select. The parallelism generates
# hypotheses; execution - never consensus - picks among them.
#
# 80+ agents once unanimously endorsed a padding oracle in OpenSSL that did not
# exist, and one empirical test killed it [P17]. That is the whole argument.

[ -n "${ORCH_DIAGNOSE_SOURCED:-}" ] && return 0
ORCH_DIAGNOSE_SOURCED=1

# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"

: "${ORCH_DIAGNOSE_K:=3}"

diagnose_path() { printf '%s/diagnosis.jsonl' "$(orch_feature_dir "$1")"; }

diagnose_seed() {  # diagnose_seed <index>
  case "$1" in
    1) printf 'the-fix-is-wrong|The implementation does not do what the requirement asks. Start from the assumption that the test is right and the code is wrong.' ;;
    2) printf 'the-test-is-wrong|The test does not test the requirement - wrong fixture, wrong assertion, or it would pass without the fix. Start from the assumption that the code is right.' ;;
    3) printf 'the-requirement-is-ambiguous|The requirement admits two readings and the developer and the code-reviewer picked different ones. Start from the assumption that both the code and the test are internally consistent.' ;;
    *) printf 'open-%s|Neither the fix, the test, nor the requirement is at fault. Look at the environment, the build, ordering, or state left behind by another test.' "$1" ;;
  esac
}

diagnose_current() {  # diagnose_current <feature>
  local f; f="$(diagnose_path "$1")"
  [ -r "$f" ] || return 0
  jq -s -c '[.[] | select(type=="object")] | group_by(.k)
            | map(reduce .[] as $r ({}; . * $r)) | .[]' "$f" 2>/dev/null
}

# diagnose_start <feature> <finding-id> [k]
diagnose_start() {
  local feature="$1" finding="$2" k="${3:-$ORCH_DIAGNOSE_K}" i seed name text
  orch_valid_feature "$feature" || die "diagnose: invalid feature '$feature'"
  [ -n "$finding" ] || die "diagnose start: needs a finding id"
  : > "$(diagnose_path "$feature")"
  i=1
  while [ "$i" -le "$k" ]; do
    seed="$(diagnose_seed "$i")"; name="${seed%%|*}"; text="${seed#*|}"
    orch_append_jsonl "$(diagnose_path "$feature")" \
      "$(orch_json k "$i" hypothesis "$name" seed "$text" finding "$finding" \
         status open started_at "$(now_iso)")"
    printf 'h%s  %-30s %s\n' "$i" "$name" "$text"
    i=$((i + 1))
  done
  ORCH_LEDGER_FEATURE="$feature" ledger_append diagnose.started finding "$finding" k:raw "$k"
  cat >&2 <<EOF

Each diagnostician gets the finding, the failing evidence, and the diff — and
nothing from the others. Each must return a prediction and the command that
falsifies it:

  orch diagnose predict $feature <k> --prediction "<what will happen>" --command "<cmd>"

State predictions so that the command exiting 0 confirms them. "It probably has
to do with caching" is not a prediction.
EOF
}

# diagnose_predict <feature> <k> <prediction> <command>
diagnose_predict() {
  local feature="$1" k="$2" pred="$3" cmd="$4"
  [ -n "$pred" ] || die "diagnose predict: --prediction is required"
  [ -n "$cmd" ]  || die "diagnose predict: --command is required"
  diagnose_current "$feature" | jq -e --arg k "$k" 'select(.k==$k)' >/dev/null 2>&1 \
    || die "diagnose predict: no hypothesis $k for $feature (run \`orch diagnose start\` first)"
  orch_append_jsonl "$(diagnose_path "$feature")" \
    "$(orch_json k "$k" prediction "$pred" command "$cmd" predicted_at "$(now_iso)" status predicted)"
  ORCH_LEDGER_FEATURE="$feature" ledger_append diagnose.predicted k "$k"
  printf 'h%s recorded.\n' "$k"
}

# diagnose_run <feature> - execute every prediction and let the results decide.
#
# Outcomes:
#   exactly one holds  -> that hypothesis directs the next repair
#   none holds         -> inconclusive, escalate to rung 5
#   two or more hold   -> contradictory, escalate to rung 5
#
# The last case matters. Two confirmed contradictory predictions mean the
# experiments were not actually distinguishing, and papering over that with a
# tiebreak is how a wrong theory gets a rubber stamp.
diagnose_run() {
  local feature="$1" row k cmd rc held=0 winner='' n=0
  diagnose_current "$feature" | while IFS= read -r row; do
    [ -n "$row" ] || continue
    k="$(printf '%s' "$row" | jq -r '.k')"
    cmd="$(printf '%s' "$row" | jq -r '.command // ""')"
    if [ -z "$cmd" ]; then
      printf 'h%s  SKIPPED — no falsifiable command was supplied\n' "$k" >&2
      continue
    fi
    printf '\n── h%s: %s\n' "$k" "$(printf '%s' "$row" | jq -r '.prediction')" >&2
    evidence_run "$feature" "diagnose-h$k" -- sh -c "$cmd"
    rc=$?
    orch_append_jsonl "$(diagnose_path "$feature")" \
      "$(orch_json k "$k" exit_code:raw "$rc" \
         outcome "$([ "$rc" = 0 ] && printf held || printf refuted)" \
         ran_at "$(now_iso)" status resolved)"
  done

  n="$(diagnose_current "$feature" | jq -s 'length' 2>/dev/null || printf 0)"
  held="$(diagnose_current "$feature" | jq -s '[.[] | select(.outcome=="held")] | length' 2>/dev/null || printf 0)"
  winner="$(diagnose_current "$feature" | jq -s -r '[.[] | select(.outcome=="held")] | if length==1 then .[0].hypothesis else "" end' 2>/dev/null)"

  printf '\n' >&2
  diagnose_current "$feature" | jq -s -r '.[] | "  h\(.k)  \(.hypothesis)  \(.outcome // "not run")"' >&2

  if [ "$held" = "1" ]; then
    ORCH_LEDGER_FEATURE="$feature" ledger_append diagnose.resolved hypothesis "$winner" k_total:raw "$n"
    printf '%s\n' "$winner"
    printf '\nOne prediction held: %s. That directs the next repair.\n' "$winner" >&2
    return 0
  fi

  if [ "$held" = "0" ]; then
    ORCH_LEDGER_FEATURE="$feature" ledger_append diagnose.inconclusive reason none_held k_total:raw "$n"
    printf '\nNo prediction held. No distinguishing experiment exists at this level —\nthat is the escalation to a human (rung 5), not a reason to try again.\n' >&2
  else
    ORCH_LEDGER_FEATURE="$feature" ledger_append diagnose.inconclusive reason contradictory held:raw "$held" k_total:raw "$n"
    printf '\n%s predictions held simultaneously. They were not distinguishing.\nEscalating to a human (rung 5) with all predictions and their attested results.\n' "$held" >&2
  fi
  return 1
}
