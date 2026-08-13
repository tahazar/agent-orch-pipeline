#!/bin/bash
# report.sh - what actually happened, and the ablation.
#
# This is the contribution. No controlled ablation of orchestrated versus solo
# agents on a coding task at matched budget has been published [P20] - every
# matched-budget study is reasoning or math, and cross-scaffold SWE-bench
# comparison is unsound by the maintainers' own admission. `orch baseline` runs
# the solo attempt on every feature regardless of rung, which is what makes
# escalation_precision computable at all.
#
# Publish the table whether or not it flatters the design. "Rung 4 never once
# produced a distinguishing experiment" is a result, and it tells you to delete
# rung 4.

[ -n "${ORCH_REPORT_SOURCED:-}" ] && return 0
ORCH_REPORT_SOURCED=1

# shellcheck source=escalate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/escalate.sh"
# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"

report_features() {
  local root; root="$(orch_repo_root)/docs/features"
  [ -d "$root" ] || return 0
  ls "$root" 2>/dev/null | while IFS= read -r d; do
    [ -d "$root/$d" ] || continue
    [ "$d" = "_orch" ] && continue
    orch_valid_feature "$d" && printf '%s\n' "$d"
  done
}

baseline_path() { printf '%s/baseline.json' "$(orch_feature_dir "$1")"; }

# --------------------------------------------------------------------------
# Per-feature facts
# --------------------------------------------------------------------------

report_feature_json() {  # report_feature_json <feature>
  local feature="$1" led usage uptake yield base rung wall gates
  led="$(ledger_read "$feature")"
  rung="$(escalate_rung "$feature")"
  usage="$(ledger_feature_usage "$feature")"
  uptake="$(findings_uptake "$feature")"
  yield="$(findings_reviewer_yield "$feature")"
  base="$(cat "$(baseline_path "$feature")" 2>/dev/null)"
  [ -n "$base" ] || base='null'

  wall="$(printf '%s' "$led" | jq -s -r '
    [.[] | select(type=="object") | .ts] | if length < 2 then 0 else
      ((.[-1] | sub("Z$";"Z") | fromdateiso8601) - (.[0] | fromdateiso8601)) end' 2>/dev/null)"
  [ -n "$wall" ] || wall=0

  # Gate yield: of the gate checks that ran, how many actually blocked
  # something. A gate that has never blocked anything across many features is
  # not protecting you; it is ceremony.
  gates="$(printf '%s' "$led" | jq -s -c '
    [.[] | select(type=="object" and (.event=="gate.checked" or .event=="gate.blocked"))] as $g
    | ($g | map(select(.event=="gate.checked")) | length) as $checked
    | ($g | map(select(.event=="gate.blocked")) | length) as $blocked
    | {checked: $checked, blocked: $blocked,
       yield_pct: (if $checked==0 then null else ($blocked * 100 / $checked | floor) end),
       by_gate: ($g | group_by(.gate) | map({gate: .[0].gate,
                                             checked: (map(select(.event=="gate.checked"))|length),
                                             blocked: (map(select(.event=="gate.blocked"))|length)}))}' 2>/dev/null)"

  # -c matters: report_render reads these back one JSON document per line.
  jq -n -c \
    --arg feature "$feature" \
    --argjson rung "${rung:-0}" \
    --arg rung_name "$(escalate_rung_name "${rung:-0}")" \
    --argjson wall_clock_s "${wall:-0}" \
    --argjson usage "$usage" \
    --argjson uptake "${uptake:-{\}}" \
    --argjson reviewers "${yield:-[]}" \
    --argjson gates "${gates:-null}" \
    --argjson baseline "$base" \
    --argjson escalations "$(printf '%s' "$led" | jq -s -c '[.[] | select(type=="object" and .event=="escalation") | {rung, reason, ts}]' 2>/dev/null || printf '[]')" \
    --argjson bestofn "$(printf '%s' "$led" | jq -s -c '[.[] | select(type=="object" and .event=="bestofn.selected") | {winner, reason, eligible, archived, ranking}]' 2>/dev/null || printf '[]')" \
    --argjson diagnose "$(printf '%s' "$led" | jq -s -c '[.[] | select(type=="object" and (.event=="diagnose.resolved" or .event=="diagnose.inconclusive")) | {event, hypothesis, reason}]' 2>/dev/null || printf '[]')" \
    --argjson messages "$(printf '%s' "$led" | jq -s -c '
        [.[] | select(type=="object" and (.event|startswith("message.")))] as $m
        | {posted: ($m|map(select(.event=="message.posted"))|length),
           delivered: ($m|map(select(.outcome=="delivered"))|length),
           held: ($m|map(select(.outcome=="held"))|length),
           expired: ($m|map(select(.outcome=="expired"))|length),
           refused: ($m|map(select(.outcome=="refused"))|length)}' 2>/dev/null || printf '{}')" \
    '$ARGS.named' 2>/dev/null
}

# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

_pct() { [ "$1" = "null" ] && printf '  —' || printf '%3s%%' "$1"; }

report_render() {  # report_render <feature|--all>
  local target="$1" f rows='' j

  if [ "$target" = "--all" ]; then
    for f in $(report_features); do
      j="$(report_feature_json "$f")"
      rows="${rows}${j}
"
    done
  else
    rows="$(report_feature_json "$target")
"
  fi
  [ -n "$(printf '%s' "$rows" | grep -v '^$' || true)" ] || { printf 'No features found under docs/features/.\n'; return 0; }

  printf 'orch report\n\n'
  printf '%-22s %-12s %8s %9s %8s %7s\n' feature rung 'out tok' 'uptake' 'wall' 'gates'
  printf '%-22s %-12s %8s %9s %8s %7s\n' '----------------------' '------------' '--------' '---------' '--------' '-------'
  printf '%s' "$rows" | grep -v '^$' | while IFS= read -r j; do
    printf '%-22s %-12s %8s %8s%% %7ss %6s%%\n' \
      "$(printf '%s' "$j" | jq -r '.feature')" \
      "$(printf '%s' "$j" | jq -r '"\(.rung)·\(.rung_name)"')" \
      "$(printf '%s' "$j" | jq -r '.usage.output')" \
      "$(printf '%s' "$j" | jq -r '.uptake.critique_uptake_rate // "—"')" \
      "$(printf '%s' "$j" | jq -r '.wall_clock_s')" \
      "$(printf '%s' "$j" | jq -r '.gates.yield_pct // "—"')"
  done

  printf '\ncritique uptake — baseline to beat is 33.6%% [P11]\n'
  printf '%s' "$rows" | grep -v '^$' | jq -s -r '
    [.[] | select(.uptake.resolved > 0)] as $f
    | if ($f|length)==0 then "  no findings have reached a terminal state yet"
      else "  " + (([$f[].uptake.engaged]|add) * 100 / ([$f[].uptake.resolved]|add) | floor | tostring)
           + "% across " + (([$f[].uptake.resolved]|add)|tostring) + " resolved findings"
      end'

  printf '\nper-reviewer unique-find rate — a lens at ~0%% over 10+ features is a deletion candidate\n'
  findings_reviewer_yield --all | jq -r '
    if length==0 then "  no findings recorded yet"
    else .[] | "  \(.reviewer): \(.unique_surviving)/\(.raised) unique surviving (\(.unique_find_rate // "—")%)"
    end'

  printf '\nbest-of-N selection margins\n'
  printf '%s' "$rows" | grep -v '^$' | jq -s -r '
    [.[] | select(.bestofn | length > 0) | {feature, sel: .bestofn[-1]}]
    | if length==0 then "  never ran"
      else .[] | "  \(.feature): \(.sel.winner) of \(.sel.archived) — \(.sel.reason)"
      end'

  printf '\ndiagnostic stage\n'
  printf '%s' "$rows" | grep -v '^$' | jq -s -r '
    [.[] | .diagnose[]] as $d
    | if ($d|length)==0 then "  never ran — if it stays that way after 20 features, delete rung 4 and say so in the README"
      else "  resolved: \([$d[]|select(.event=="diagnose.resolved")]|length), inconclusive: \([$d[]|select(.event=="diagnose.inconclusive")]|length)"
      end'

  printf '\ncoordination transport — how much depended on the ephemeral path\n'
  printf '%s' "$rows" | grep -v '^$' | jq -s -r '
    [.[].messages] | {posted:(map(.posted//0)|add), delivered:(map(.delivered//0)|add),
                      held:(map(.held//0)|add), expired:(map(.expired//0)|add),
                      refused:(map(.refused//0)|add)}
    | "  posted \(.posted), delivered \(.delivered), held \(.held), expired \(.expired), refused \(.refused)"'

  report_ablation_render "$rows"
}

# --------------------------------------------------------------------------
# Ablation
# --------------------------------------------------------------------------

report_ablation_render() {  # report_ablation_render <rows>
  local rows="$1"
  printf '\nablation — orchestrated vs solo at the same requirements\n'
  printf '%s' "$rows" | grep -v '^$' | jq -s -r '
    [.[] | select(.baseline != null)] as $b
    | if ($b|length)==0 then
        "  no baselines recorded. Run `orch baseline <feature>` — without it neither the\n  cost multiplier nor escalation_precision can be computed, and both are the point."
      else
        ($b | group_by(.rung) | map({
            rung: .[0].rung,
            name: .[0].rung_name,
            n: length,
            solo_failed: ([.[] | select(.baseline.solo_passed == false)] | length),
            orch_out: ([.[].usage.output] | add),
            solo_out: ([.[].baseline.output_tokens // 0] | add),
            solo_usd: ([.[].baseline.total_cost_usd // 0] | add)
          })
          | map(. + {multiplier: (if .solo_out == 0 then null else (.orch_out * 100 / .solo_out | floor) / 100 end)})
          | (["  rung  n   solo-failed  orch-out  solo-out  x"] +
             (.[] | ["  \(.rung)·\(.name)  \(.n)   \(.solo_failed)   \(.orch_out)  \(.solo_out)  \(.multiplier // "—")"]))
          | .[]),
        "",
        ("  escalation_precision: " +
          (([$b[] | select(.rung > 0)]) as $esc
           | if ($esc|length)==0 then "no feature escalated past rung 0 yet"
             else "\((([$esc[] | select(.baseline.solo_passed == false)] | length) * 100 / ($esc|length)) | floor)% — of \($esc|length) escalated features, \([$esc[] | select(.baseline.solo_passed == false)] | length) would have been wrong solo"
             end)),
        "  Low precision means the detector is trigger-happy and the §4.1 thresholds need raising.",
        "  Published multipliers to compare against: 3–10x [P4], revised down from 15x [P3]."
      end'
}

# --------------------------------------------------------------------------
# Baseline
# --------------------------------------------------------------------------

# report_baseline <feature> [-- gate-cmd...]
#
# A single-agent attempt at the same requirements.md, in a throwaway worktree,
# merging nothing. Cost comes straight from the result envelope's
# total_cost_usd - the one number in this whole system that we do not have to
# derive, and the reason `claude -p --output-format json` is the right tool
# here rather than another orchestrated run.
report_baseline() {
  local feature="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local req wt br out rc gate_rc passed
  orch_valid_feature "$feature" || die "baseline: invalid feature '$feature'"
  req="$(orch_feature_dir "$feature")/requirements.md"
  [ -r "$req" ] || die "baseline: no requirements.md for $feature — there is nothing to give the solo agent"
  have claude || die "baseline: the claude CLI is not on PATH"

  wt="${ORCH_REPO}/.orch/baseline/$feature"
  br="orch/baseline/$feature"
  rm -rf "$wt"
  git -C "$ORCH_REPO" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$ORCH_REPO" branch -D "$br" 2>/dev/null || true
  git -C "$ORCH_REPO" worktree add -q -b "$br" "$wt" "$(escalate_base_branch)" \
    || die "baseline: could not create the throwaway worktree"

  printf 'running the solo baseline for %s in %s\n' "$feature" "$wt" >&2
  out="$(cd "$wt" && claude -p --output-format json \
    "Implement the requirements in $req. Work only in $wt. Do not ask questions; make the best call and note your assumptions in the commit message." \
    2>/dev/null)"
  rc=$?

  gate_rc=1
  if [ "$#" -gt 0 ]; then
    ( cd "$wt" && "$@" ) >/dev/null 2>&1
    gate_rc=$?
  else
    warn "baseline: no gate command given, so solo_passed is recorded as unknown"
    gate_rc=''
  fi
  case "$gate_rc" in '') passed=null ;; 0) passed=true ;; *) passed=false ;; esac

  jq -n \
    --arg feature "$feature" --arg ran_at "$(now_iso)" \
    --argjson exit_code "$rc" --argjson solo_passed "$passed" \
    --argjson envelope "$(printf '%s' "$out" | jq -c '.' 2>/dev/null || printf 'null')" \
    --argjson total_cost_usd "$(printf '%s' "$out" | jq -r '.total_cost_usd // 0' 2>/dev/null || printf 0)" \
    --argjson output_tokens "$(printf '%s' "$out" | jq -r '(.usage.output_tokens // 0)' 2>/dev/null || printf 0)" \
    --argjson duration_ms "$(printf '%s' "$out" | jq -r '.duration_ms // 0' 2>/dev/null || printf 0)" \
    '$ARGS.named' > "$(baseline_path "$feature")"

  ORCH_LEDGER_FEATURE="$feature" ledger_append baseline.ran \
    solo_passed "$passed" cost_usd "$(jq -r '.total_cost_usd' "$(baseline_path "$feature")")"

  git -C "$ORCH_REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  printf 'baseline recorded: %s\n' "$(baseline_path "$feature")"
  cat "$(baseline_path "$feature")"
}
