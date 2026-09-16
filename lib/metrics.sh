#!/bin/bash
# metrics.sh - the metrics loop: a story's hypothesis, measured.
#
# A story says what it expects to move (`metric: exports_per_user up`). Once
# its feature is kept, the loop has one job: say whether it did. Readings
# are aggregates a repository's own script prints — never raw logs, which
# would walk personal data into a context window — attested through
# `orch run --feature _orch --label metrics`. Nothing here calls a model.
#
# The Goodhart discipline [P47] is in the definitions, not the readings:
#
#   docs/product/metrics.md, frozen with the personas and stories
#     - exports_per_user: up — exports per weekly active user
#     - error_rate: down guardrail — 5xx per 1k requests
#     - p95_ms: down guardrail holdout — dashboard p95
#
#   direction   which way is good; a hypothesis that moved the other way is
#               refuted, not "noisy"
#   guardrail   must not move the wrong way by more than ORCH_T_GUARDRAIL
#               percent while features land; a breach is a blocking finding
#               on the run, named after the feature that landed before it
#   holdout     never shown to a crew: not in a request, not in the
#               checklist, denied to the walkthrough. The human's number.
#
# What the loop produces is evidence, and evidence flows upward: a persona
# whose stories' hypotheses were confirmed by measurement is proposed for
# `evidence: measured`. Proposed — the file is the human's.

[ -n "${ORCH_METRICS_SOURCED:-}" ] && return 0
ORCH_METRICS_SOURCED=1

# shellcheck source=walkthrough.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/walkthrough.sh"
# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"

: "${ORCH_T_GUARDRAIL:=5}"    # percent the wrong way that breaches a guardrail
: "${ORCH_T_EFFECT:=2}"       # percent in the right direction that confirms a hypothesis

metrics_path() { printf '%s/metrics.md' "$(product_dir)"; }

# "name direction guardrail holdout description" per defined metric.
metrics_defs() {
  [ -r "$(metrics_path)" ] || return 0
  local line name rest dir g h desc
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#[-*] }"
    case "$line" in [A-Za-z_]*:*) ;; *) continue ;; esac
    name="${line%%:*}"; name="${name%"${name##*[![:space:]]}"}"
    case "$name" in *[!A-Za-z0-9_]*) continue ;; esac
    rest="${line#*:}"
    # shellcheck disable=SC2086
    set -- $rest
    dir="${1:-}"; case "$dir" in up|down) ;; *) continue ;; esac; shift
    g=false; h=false
    while [ "$#" -gt 0 ]; do case "$1" in guardrail) g=true ;; holdout) h=true ;; *) break ;; esac; shift; done
    desc="$*"; desc="${desc#— }"; desc="${desc#- }"
    printf '%s %s %s %s %s\n' "$name" "$dir" "$g" "$h" "$desc"
  done < "$(metrics_path)"
}
metrics_def() { metrics_defs | awk -v n="$1" '$1 == n'; }
metrics_holdout_names() { metrics_defs | awk '$4 == "true" {print $1}'; }

# Every attested reading, oldest first: "ts name value" lines, from the
# stdout of exit-0 `metrics` runs on the run ledger.
metrics_readings() {
  local f; f="$(orch_feature_dir _orch)/evidence.jsonl"
  [ -r "$f" ] || return 0
  jq -r 'select(type=="object" and .label=="metrics" and .exit_code==0) | .ts as $t | (.stdout_tail // "") | split("\n")[] | select(length>0) | $t + " " + .' "$f" 2>/dev/null \
  | awk '$2 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && $3 ~ /^-?[0-9]+(\.[0-9]+)?$/ {print $1, $2, $3}'
}
metrics_latest() { metrics_readings | awk -v n="$1" '$2 == n {v = $3; t = $1} END { if (t != "") print t, v }'; }
metrics_before() { metrics_readings | awk -v n="$1" -v ts="$2" '$2 == n && $1 < ts {v = $3; t = $1} END { if (t != "") print t, v }'; }

_metrics_pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (a == 0) { print (b == 0 ? 0 : 100); exit } printf "%.1f", (b - a) / a * 100 }'; }

# A story's hypothesis: "name direction" when its metric: line names a
# defined metric, else the free text with direction "?" (recorded, not
# measured). A holdout metric may not be a story's target.
metrics_hypothesis() {  # metrics_hypothesis <S001> -> "name dir" or "? text"
  local sf m name dir
  sf="$(product_story_file "$1")"; [ -r "$sf" ] || return 0
  m="$(product_field "$sf" metric)"; [ -n "$m" ] || return 0
  name="$(printf '%s' "$m" | awk '{print $1}')"
  if [ -n "$(metrics_def "$name")" ]; then
    dir="$(printf '%s' "$m" | awk '{print $2}')"; [ -n "$dir" ] || dir="$(metrics_def "$name" | awk '{print $2}')"
    printf '%s %s' "$name" "$dir"
  else printf '? %s' "$m"; fi
}

# metrics_verdict <feature> -> "confirmed|refuted|unchanged|unmeasured|none <detail>"
metrics_verdict() {
  local f="$1" s h name dir kept before after pct
  s="$(product_feature_story "$f")"; [ -n "$s" ] || { printf 'none'; return 0; }
  h="$(metrics_hypothesis "$s")"; [ -n "$h" ] || { printf 'none'; return 0; }
  name="${h%% *}"; dir="${h#* }"
  [ "$name" != '?' ] || { printf 'unmeasured %s is not a defined metric (docs/product/metrics.md)' "$dir"; return 0; }
  kept="$(_product_last "$f" product.kept | jq -r '.ts // ""')"
  [ -n "$kept" ] || { printf 'unmeasured not kept yet (%s %s)' "$name" "$dir"; return 0; }
  before="$(metrics_before "$name" "$kept")"; after="$(metrics_latest "$name")"
  [ -n "$before" ] && [ -n "$after" ] && [ "${after%% *}" \> "$kept" ] \
    || { printf 'unmeasured no reading on both sides of the landing (%s %s)' "$name" "$dir"; return 0; }
  pct="$(_metrics_pct "${before#* }" "${after#* }")"
  awk -v p="$pct" -v d="$dir" -v e="$ORCH_T_EFFECT" -v n="$name" -v b="${before#* }" -v a="${after#* }" 'BEGIN {
    good = (d == "up") ? p : -p
    v = (good >= e) ? "confirmed" : (good <= -e) ? "refuted" : "unchanged"
    printf "%s %s %s: %s -> %s (%s%s%%)", v, n, d, b, a, (p > 0 ? "+" : ""), p }'
}

# metrics_guardrails — each guardrail, its last two readings, breach or not.
# A breach is a blocking finding on the run, named after the feature kept
# most recently before the reading, once per reading.
metrics_guardrails() {
  local name dir g h desc prev last pct bad cause claim rc=0
  metrics_defs | while read -r name dir g h desc; do
    [ "$g" = true ] || continue
    last="$(metrics_latest "$name")"
    prev="$(metrics_readings | awk -v n="$name" '$2 == n {print $1, $3}' | tail -2 | head -1)"
    if [ -z "$last" ] || [ -z "$prev" ] || [ "$prev" = "$last" ]; then printf '  %-20s guardrail (%s)  %s\n' "$name" "$dir" "${last:+${last#* } — one reading, nothing to compare}${last:-no reading}"; continue; fi
    pct="$(_metrics_pct "${prev#* }" "${last#* }")"
    bad="$(awk -v p="$pct" -v d="$dir" -v t="$ORCH_T_GUARDRAIL" 'BEGIN { print ((d == "up" && -p > t) || (d == "down" && p > t)) ? "true" : "false" }')"
    printf '  %-20s guardrail (%s)  %s -> %s  %s%s%%%s\n' "$name" "$dir" "${prev#* }" "${last#* }" "$([ "${pct#-}" = "$pct" ] && printf '+')" "$pct" "$([ "$bad" = true ] && printf '  BREACH')"
    [ "$bad" = true ] || continue
    cause="$(ledger_read --all | jq -r -s --arg t "${last%% *}" '[.[] | select(type=="object" and .event=="product.kept" and .ts < $t)] | sort_by(.ts) | last | .feature // ""' 2>/dev/null)"
    claim="guardrail $name moved the wrong way: ${prev#* } -> ${last#* } ($([ "${pct#-}" = "$pct" ] && printf '+')$pct%) at ${last%% *}; last landing before it: ${cause:-none}"
    findings_current _orch | jq -e --arg c "$claim" 'select(.raised_by=="metrics" and .claim==$c)' >/dev/null 2>&1 \
      || findings_add _orch metrics blocking "docs/product/metrics.md" 0 "$claim" "a number the product was designed to protect is regressing while features land; the morning keeps nothing until it is explained" >/dev/null
  done
}

# metrics_render — the whole loop, for the human.
metrics_render() {
  local name dir g h desc last f v p s per confirmed refuted
  [ -n "$(metrics_defs)" ] || { printf 'no metrics defined. Layout, in docs/product/metrics.md:\n  - exports_per_user: up — exports per weekly active user\n  - error_rate: down guardrail — 5xx per 1k requests\n  - p95_ms: down guardrail holdout — never shown to a crew\nReadings:  orch run --feature _orch --label metrics -- <script printing "name value" lines>\n'; return 0; }
  printf 'metrics (readings: %s attested)\n' "$(metrics_readings | awk '{print $1}' | sort -u | grep -c .)"
  metrics_defs | while read -r name dir g h desc; do
    last="$(metrics_latest "$name")"
    printf '  %-20s %-4s %s%s%s  — %s\n' "$name" "$dir" "$([ "$g" = true ] && printf 'guardrail ')" "$([ "$h" = true ] && printf 'HOLDOUT ')" "${last:+${last#* } at ${last%% *}}${last:-no reading}" "$desc"
  done
  printf '\nguardrails:\n'; metrics_guardrails
  printf '\nhypotheses, per kept feature:\n'
  for f in $(_product_features); do
    [ -n "$(_product_last "$f" product.kept)" ] || continue
    v="$(metrics_verdict "$f")"
    printf '  %-26s %s  %s\n' "$f" "$(product_feature_story "$f")" "$v"
  done | grep . || printf '  none kept yet\n'
  printf '\nproposals (the files are yours; nothing here edits them):\n'
  for per in $(product_personas); do
    confirmed=0; refuted=0
    for f in $(_product_features); do
      [ "$(product_feature_persona "$f")" = "$per" ] || continue
      case "$(metrics_verdict "$f")" in confirmed*) confirmed=$((confirmed + 1)) ;; refuted*) refuted=$((refuted + 1)) ;; esac
    done
    if [ "$confirmed" -gt 0 ] && [ "$refuted" = 0 ] && [ "$(product_persona_evidence "$per")" != measured ]; then
      printf '  %s: %s confirmed hypothesis(es), none refuted — propose  evidence: measured  in %s, then  orch product freeze --why "..."\n' "$per" "$confirmed" "$(product_persona_file "$per")"
    elif [ "$refuted" -gt 0 ]; then
      printf '  %s: %s refuted hypothesis(es) — the persona predicted a move that did not come; amend the persona or the story\n' "$per" "$refuted"
    fi
  done | grep . || printf '  none yet\n'
}
