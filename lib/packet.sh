#!/bin/bash
# packet.sh - the approval packet (docs/AGENT-TDD.md, phase 7).
#
# The FLT reviewer reads the one-line statement, the proof route, the axiom
# list and the comparator verdict; nobody reads the proof [P36]. The human
# gate here should be the same shape: the statement first, then everything
# that was checked by something that cannot be persuaded, and the diff last.
# The goal is a human who approves most features without opening the diff —
# not because they stopped reading, but because everything the diff could
# tell them has already been checked.
#
# Nothing here is written by a model except the read-back — a blind,
# natural-language rendering of what the tests literally assert — and that
# is bound to the oracle sha it describes and shown as stale otherwise.

[ -n "${ORCH_PACKET_SOURCED:-}" ] && return 0
ORCH_PACKET_SOURCED=1

# shellcheck source=spec.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec.sh"
# shellcheck source=axioms.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/axioms.sh"
# shellcheck source=sensors.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sensors.sh"
# shellcheck source=readback.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/readback.sh"
# shellcheck source=holdout.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/holdout.sh"

_packet_h() { printf '\n== %s ==\n\n' "$1"; }

packet_render() {  # packet_render <feature>
  local feature="$1" dir base head cov row st n m
  orch_valid_feature "$feature" || die "packet: invalid feature '$feature'"
  dir="$(orch_feature_dir "$feature")"
  head="$(orch_head_sha)"
  base="$(git -C "$ORCH_REPO" merge-base "$(escalate_base_branch)" "$head" 2>/dev/null || escalate_base_branch)"

  printf 'APPROVAL PACKET — %s at %s\n' "$feature" "$(printf '%s' "$head" | cut -c1-12)"
  printf 'Read in order. The diff is last because everything above it was checked by hash or by a command.\n'

  _packet_h "1. what was asked (request.md, frozen at feature start)"
  cat "$dir/request.md" 2>/dev/null || printf '(no request.md)\n'

  _packet_h "2. the statement, and whether it held"
  if st="$(statement_check "$feature" 2>&1)"; then
    printf 'statement: as frozen (%s)\n' "$(statement_frozen "$feature" | jq -r '.files | keys | join(", ")')"
  else
    printf '%s\n' "$st" | head -1
  fi
  if row="$(oracle_frozen "$feature")" && [ -n "$row" ]; then
    if oracle_check "$feature" "$head" >/dev/null 2>&1; then
      printf 'oracle:    as frozen at the red phase (%s test files, %s)\n' \
        "$(printf '%s' "$row" | jq -r .files)" "$(printf '%s' "$row" | jq -r '.sha[0:12]')"
    else
      printf 'oracle:    ORACLE_MOVED — the tests at HEAD are not the tests that failed\n'
    fi
  else
    printf 'oracle:    not frozen (no attested red phase on record)\n'
  fi
  printf '\nread-back — what the tests literally assert, written without sight of the requirements:\n'
  case "$(readback_status "$feature")" in
    current) sed '1,3d' "$(readback_path "$feature")" | sed 's/^/  /' ;;
    stale)   printf '  STALE — written against an older oracle. Re-run:  orch readback start %s\n' "$feature" ;;
    *)       printf '  none recorded. Compare the tests to the requirements yourself, or:  orch readback start %s\n' "$feature" ;;
  esac

  _packet_h "3. requirements, and the oracle tests that cite each"
  cov="$(spec_coverage "$feature" "$head")"
  if [ "$(printf '%s' "$cov" | jq 'length')" = "0" ]; then
    printf 'requirements.md defines no ids (R1, R2, ...); coverage was not checked.\n\n'
    cat "$dir/requirements.md" 2>/dev/null || printf '(no requirements.md)\n'
  else
    printf '%s' "$cov" | jq -r '.[] | "  \(.id)  " + (if (.tests|length)==0 then "UNCOVERED" else (.tests|join(", ")) end)'
    printf '\n'
    grep -nE '^[[:space:]]*([-*+]|[0-9]+[.)]|#+)?[[:space:]]*[*_`]*R[0-9]+' "$dir/requirements.md" 2>/dev/null | sed 's/^[0-9]*:/  /'
  fi

  _packet_h "4. escape hatches and trusted configuration in the diff"
  n="$(axioms_scan "$base" "$head")"
  if [ "$(printf '%s' "$n" | jq 'length')" = "0" ]; then
    printf 'none new against %s\n' "$(printf '%s' "$base" | cut -c1-12)"
  else
    printf '%s' "$n" | jq -r '.[] | if .kind=="config" then "  CONFIG   \(.file)" else "  \(.file):\(.line)  \(.pattern)  (\(.base) -> \(.head))" end'
    printf '\n  each is a finding; open ones held the gate, disputed ones are below\n'
  fi
  printf '\nchanged outside source and test paths:\n'
  git -C "$ORCH_REPO" diff --name-only "$base" "$head" -- . ':(exclude)docs/features' 2>/dev/null \
    | while IFS= read -r f; do
        _sensor_is_source "$f" && continue
        printf '  %s\n' "$f"
      done | grep . || printf '  none\n'

  _packet_h "5. findings still open or disputed"
  findings_current "$feature" | jq -r 'select(.status=="open" or .status=="disputed")
    | "  \(.id)  [\(.severity)] \(.status)  \(.file):\(.line)  \(.claim)" + (if .status=="disputed" then "\n         dispute: \(.status_reason)" else "" end)' \
    | grep . || printf '  none\n'

  _packet_h "6. sensors"
  for m in diff_coverage mutation; do
    row="$(sensor_latest "$feature" "$m")"
    if [ -z "$row" ]; then printf '  %s: no reading\n' "$m"; continue; fi
    printf '  %s: %s%% at %s%s\n' "$m" "$(printf '%s' "$row" | jq -r '.pct // "—"')" \
      "$(printf '%s' "$row" | jq -r '.at_sha[0:12]')" \
      "$([ "$(printf '%s' "$row" | jq -r .at_sha)" = "$head" ] || printf '  (NOT at HEAD)')"
  done
  row="$(ledger_read "$feature" | jq -c -s '[.[] | select(type=="object" and (.event=="refactor.kept" or .event=="refactor.discarded" or .event=="refactor.skipped"))] | if length==0 then empty else .[-1] end' 2>/dev/null)"
  if [ -n "$row" ]; then
    printf '  refactor: %s%s\n' "$(printf '%s' "$row" | jq -r '.event | ltrimstr("refactor.")')" \
      "$(printf '%s' "$row" | jq -r 'if .reason then " — " + .reason elif .post_diff_lines then " — \(.post_diff_lines) lines" else "" end')"
  else
    printf '  refactor: not run\n'
  fi

  if holdout_has "$feature"; then
    row="$(substrate_read_gate "$feature" holdout 2>/dev/null)"
    if [ "$(printf '%s' "$row" | jq -r '.state // "absent"')" = met ] && [ "$(printf '%s' "$row" | jq -r '.sha // ""')" = "$head" ]; then
      printf '  holdout: PASSED at HEAD (%s held-out test file(s) the developer never saw)\n' "$(holdout_list "$feature" | grep -c .)"
    else
      printf '  holdout: NOT passed at HEAD — the merge is blocked until it is:  orch holdout run %s -- <cmd>\n' "$feature"
    fi
  fi

  _packet_h "7. evidence at HEAD"
  for m in build tests coverage; do
    row="$(evidence_latest "$feature" "$m")"
    if [ -z "$row" ]; then printf '  %-9s none\n' "$m"; continue; fi
    printf '  %-9s exit %s  %s  %s%s\n' "$m" "$(printf '%s' "$row" | jq -r .exit_code)" \
      "$(printf '%s' "$row" | jq -r '.git_sha[0:12]')" \
      "$([ "$(printf '%s' "$row" | jq -r '.dirty // false')" = "true" ] && printf 'DIRTY' || printf 'clean')" \
      "$([ "$(printf '%s' "$row" | jq -r .git_sha)" = "$head" ] || printf '  (NOT at HEAD)')"
  done

  _packet_h "8. the diff, last"
  git -C "$ORCH_REPO" diff --stat "$base" "$head" -- . ':(exclude)docs/features' 2>/dev/null | sed 's/^/  /'
  printf '\n  git diff %s..%s\n\nApprove:  orch approve %s --gate human\n' \
    "$(printf '%s' "$base" | cut -c1-12)" "$(printf '%s' "$head" | cut -c1-12)" "$feature"
}
