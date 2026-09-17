#!/bin/bash
# perf.sh - the performance sensor: the diff's benchmarks against the base's,
# measured in the same session, on the same machine, interleaved.
#
# A benchmark number on its own is a claim about a machine. A number against
# the base, with both measured now and alternated so a noisy neighbour hits
# both, is a claim about the diff — which is the only claim the gate is
# about. So the sensor checks the base out into a clean worktree, runs the
# same command there and here N times turn about, takes the median of each
# side, and records the ratio with the base's own spread beside it. A
# regression smaller than the spread is reported and not held against the
# diff: a gate that fires on noise is a gate the crew learns to re-run.
#
#   orch sensor perf F [--runs N] -- <command that prints benchmark results>
#
# The command's output, in any of: lines of `name value [unit]`; Go's
# `BenchmarkX-8  N  123 ns/op`; hyperfine's JSON; pytest-benchmark's JSON.
# Lower is better unless the name says otherwise (ORCH_PERF_HIGHER_RE). A
# budget file (.claude/orch-perf.json: {"budgets": {"name": max}}) makes an
# absolute ceiling per benchmark as well.
#
# Report line by default; a gate when ORCH_T_PERF (max regression percent)
# is set. Each regression over the threshold is a finding raised by `perf`.
# What this trusts: the command is the repository's. orch attests that it
# ran on both trees and reads what it printed.

[ -n "${ORCH_PERF_SOURCED:-}" ] && return 0
ORCH_PERF_SOURCED=1

# shellcheck source=sensors.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sensors.sh"
# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"

: "${ORCH_PERF_RUNS:=3}"
: "${ORCH_T_PERF:=}"                                   # percent; empty = report only
: "${ORCH_PERF_HIGHER_RE:=(ops|/s|per_s|throughput|qps|rps|iops|score)$}"
: "${ORCH_PERF_BUDGET_FILE:=}"

# perf_parse: benchmark output on stdin -> "name value" lines.
perf_parse() {
  local txt; txt="$(cat)"
  if printf '%s' "$txt" | jq -e 'type=="object" and (.results != null or .benchmarks != null)' >/dev/null 2>&1; then
    printf '%s' "$txt" | jq -r '
      (.results // [] | .[] | "\(.command // .name) \(.mean)"),
      (.benchmarks // [] | .[] | "\(.name) \(.stats.mean)")' 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g'
    return 0
  fi
  printf '%s\n' "$txt" | awk '
    /^Benchmark[A-Za-z0-9_\/.-]+(-[0-9]+)?[ \t]+[0-9]+[ \t]+[0-9.]+ ns\/op/ { n = $1; sub(/-[0-9]+$/, "", n); print n, $3; next }
    /^[A-Za-z_][A-Za-z0-9_.\/:-]*[ \t:=]+[0-9]+(\.[0-9]+)?([ \t]|$)/ {
      n = $1; sub(/[:=]$/, "", n); v = $2; sub(/^[:=]+/, "", v)
      if (v == "") v = $3
      if (v ~ /^[0-9]+(\.[0-9]+)?$/) print n, v }'
}

# perf_median: "name value" lines on stdin, many runs -> "name median min max" per name
perf_median() {
  sort -k1,1 -k2,2n | awk '
    { v[$1, ++c[$1]] = $2 }
    END { for (n in c) { k = c[n]; m = (k % 2) ? v[n, (k + 1) / 2] : (v[n, k / 2] + v[n, k / 2 + 1]) / 2
                         printf "%s %s %s %s\n", n, m, v[n, 1], v[n, k] } }' | sort
}

perf_budget() {  # perf_budget <name> -> the absolute ceiling for it, or ''
  local f="${ORCH_PERF_BUDGET_FILE:-$(orch_main_repo)/.claude/orch-perf.json}"
  [ -r "$f" ] && jq -r --arg n "$1" '.budgets[$n] // empty' "$f" 2>/dev/null
  return 0
}

# sensor_perf <feature> [--runs N] [--sha S] [--base B] -- <cmd...>
sensor_perf() {
  local feature="$1"; shift
  local runs="$ORCH_PERF_RUNS" sha='' base='' repo wt msg i txt bout hout rows new worst worst_name row name b h pct noise better budget over sev claim cons
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runs) runs="$2"; shift 2 ;;
      --sha)  sha="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "sensor perf: unexpected argument '$1' (the command goes after --)" ;;
    esac
  done
  [ "$#" -gt 0 ] || die "sensor perf: no command given.  orch sensor perf $feature -- <benchmark command>"
  repo="$(_sensor_repo)"
  [ -n "$sha" ] || sha="$(orch_head_sha)"
  [ -n "$base" ] || base="$(_sensor_base "$sha")"
  [ "$(git -C "$repo" status --porcelain -- . ':(exclude)docs/features' ':(exclude).orch' | grep -c .)" = "0" ] \
    || die "sensor perf: the tree is dirty — a number for a tree nobody can check out is not a reading"

  # The base, clean, beside the feature's tree. Built the same way when a
  # build command exists, so the comparison is between two built trees.
  wt="$(orch_state_dir)/worktrees/$feature/perf-base"
  [ ! -e "$wt" ] || git -C "$repo" worktree remove --force --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$repo" worktree prune >/dev/null 2>&1
  msg="$(git -C "$repo" worktree add -f -q --detach "$wt" "$base" 2>&1)" || die "sensor perf: could not check out the base: $msg"
  if [ -n "${ORCH_BUILD_CMD:-}" ]; then
    ( cd "$wt" && ORCH_REPO="$repo" evidence_run "$feature" perf-base-build -- sh -c "$ORCH_BUILD_CMD" ) >/dev/null 2>&1 \
      || { git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; die "sensor perf: the base does not build (ORCH_BUILD_CMD) — nothing to compare against"; }
  fi
  bout="$(mktemp "${TMPDIR:-/tmp}/orch-perf.XXXXXX")"; hout="$(mktemp "${TMPDIR:-/tmp}/orch-perf.XXXXXX")"
  # Interleaved: base, head, base, head. A noisy neighbour hits both sides.
  i=0
  while [ "$i" -lt "$runs" ]; do
    # Captured, not piped: the run's exit status is the one that matters,
    # and a pipeline would report the parser's instead.
    txt="$(cd "$wt" && ORCH_REPO="$repo" evidence_run "$feature" perf-base -- "$@" 2>/dev/null)" \
      || { rm -f "$bout" "$hout"; git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; die "sensor perf: the benchmark failed on the base"; }
    printf '%s\n' "$txt" | perf_parse >> "$bout"
    txt="$(cd "$repo" && evidence_run "$feature" perf -- "$@" 2>/dev/null)" \
      || { rm -f "$bout" "$hout"; git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; die "sensor perf: the benchmark failed at HEAD"; }
    printf '%s\n' "$txt" | perf_parse >> "$hout"
    i=$((i + 1))
  done
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  [ -s "$hout" ] || { rm -f "$bout" "$hout"; die "sensor perf: the command printed nothing this file can read (name value lines, Go benchmarks, hyperfine or pytest-benchmark JSON)"; }

  rows="$(perf_median < "$bout" | while read -r name b bmin bmax; do
      h="$(perf_median < "$hout" | awk -v n="$name" '$1 == n {print $2}')"
      [ -n "$h" ] || continue
      if printf '%s' "$name" | grep -qE "$ORCH_PERF_HIGHER_RE"; then better=higher; else better=lower; fi
      pct="$(awk -v b="$b" -v h="$h" -v dir="$better" 'BEGIN { if (b == 0) { print 0; exit } r = (h - b) / b * 100; if (dir == "higher") r = -r; printf "%.1f", r }')"
      noise="$(awk -v b="$b" -v lo="$bmin" -v hi="$bmax" 'BEGIN { if (b == 0) { print 0; exit } printf "%.1f", (hi - lo) / b * 100 }')"
      budget="$(perf_budget "$name")"
      over=false; [ -n "$budget" ] && over="$(awk -v h="$h" -v m="$budget" -v dir="$better" 'BEGIN { print ((dir == "lower" && h > m) || (dir == "higher" && h < m)) ? "true" : "false" }')"
      orch_json name "$name" base:raw "$b" head:raw "$h" pct:raw "$pct" noise_pct:raw "$noise" better "$better" budget:raw "${budget:-null}" over_budget:raw "$over"; printf '\n'
    done | jq -s -c '.')"
  # New benchmarks (at HEAD only) are reported, not compared.
  new="$(perf_median < "$hout" | awk '{print $1}' | while read -r name; do grep -q "^$name " "$bout" || printf '%s\n' "$name"; done | jq -R . | jq -s -c '.')"
  rm -f "$bout" "$hout"
  worst="$(printf '%s' "$rows" | jq -r 'map(.pct) | max // 0')"
  worst_name="$(printf '%s' "$rows" | jq -r --argjson w "$worst" '[.[] | select(.pct == $w)] | first | .name // ""')"

  # Findings: over the threshold and outside the base's own spread, or over
  # a budget. Once each.
  printf '%s' "$rows" | jq -c '.[]' | while IFS= read -r row; do
    name="$(printf '%s' "$row" | jq -r .name)"; pct="$(printf '%s' "$row" | jq -r .pct)"; noise="$(printf '%s' "$row" | jq -r .noise_pct)"
    if [ "$(printf '%s' "$row" | jq -r .over_budget)" = true ]; then
      sev=blocking
      claim="$name: $(printf '%s' "$row" | jq -r .head) is over its budget of $(printf '%s' "$row" | jq -r .budget) (base $(printf '%s' "$row" | jq -r .base))"
      cons="the budget in .claude/orch-perf.json is an absolute ceiling the product was designed to; the diff crosses it"
    elif [ -n "$ORCH_T_PERF" ] && awk -v p="$pct" -v t="$ORCH_T_PERF" -v n="$noise" 'BEGIN { exit !(p > t && p > n) }'; then
      if awk -v p="$pct" -v t="$ORCH_T_PERF" 'BEGIN { exit !(p > 2 * t) }'; then sev=blocking; else sev=major; fi
      claim="$name: $(printf '%s' "$row" | jq -r .pct)% worse than the base ($(printf '%s' "$row" | jq -r .base) -> $(printf '%s' "$row" | jq -r .head); the base's own spread was $noise%)"
      cons="a regression over ORCH_T_PERF=$ORCH_T_PERF% measured A/B in the same session; every user of this path pays it"
    else continue; fi
    findings_current "$feature" | jq -e --arg c "$claim" 'select(.raised_by=="perf" and .claim==$c)' >/dev/null 2>&1 && continue
    findings_add "$feature" perf "$sev" "bench:$name" 0 "$claim" "$cons" >/dev/null
  done

  ORCH_LEDGER_FEATURE="$feature" ledger_append sensor.perf \
    at_sha "$sha" base_sha "$(git -C "$repo" rev-parse "$base" 2>/dev/null)" runs:raw "$runs" cmd "$*" \
    worst_pct:raw "$worst" worst "$worst_name" rows:raw "$rows" new:raw "$new"
  jq -n -c --arg sha "$sha" --argjson runs "$runs" --argjson worst_pct "$worst" --arg worst "$worst_name" --argjson rows "$rows" --argjson new "$new" '$ARGS.named'
}

perf_latest() { sensor_latest "$1" perf; }

# perf_gate <feature> <sha> -> 0, or 8 with the reason on stderr.
perf_gate() {
  local feature="$1" sha="$2" r bad
  r="$(perf_latest "$feature")"
  if [ -n "$r" ] && [ "$(printf '%s' "$r" | jq -r '.at_sha // ""')" = "$sha" ] \
     && [ "$(printf '%s' "$r" | jq '[.rows[] | select(.over_budget)] | length')" -gt 0 ]; then
    printf 'PERF_BUDGET: over budget at %s:\n%s\n' "$(printf '%s' "$sha" | cut -c1-12)" \
      "$(printf '%s' "$r" | jq -r '.rows[] | select(.over_budget) | "  \(.name)  \(.head) > budget \(.budget)  (base \(.base))"')" >&2
    return 8
  fi
  [ -n "$ORCH_T_PERF" ] || return 0
  if [ -z "$r" ] || [ "$(printf '%s' "$r" | jq -r '.at_sha // ""')" != "$sha" ]; then
    printf 'SENSOR_MISSING: no perf reading at %s (ORCH_T_PERF=%s is set).\n  orch sensor perf %s -- <benchmark command>\n' \
      "$(printf '%s' "$sha" | cut -c1-12)" "$ORCH_T_PERF" "$feature" >&2
    return 8
  fi
  bad="$(printf '%s' "$r" | jq -r --argjson t "$ORCH_T_PERF" '.rows[] | select(.pct > $t and .pct > .noise_pct) | "  \(.name)  +\(.pct)%  (\(.base) -> \(.head), base spread \(.noise_pct)%)"')"
  [ -z "$bad" ] || { printf 'PERF_REGRESSION: over ORCH_T_PERF=%s%% at %s, outside the base'"'"'s own spread:\n%s\n' "$ORCH_T_PERF" "$(printf '%s' "$sha" | cut -c1-12)" "$bad" >&2; return 8; }
  return 0
}

perf_render() {  # perf_render <feature> <head> — the lines for the packet
  local feature="$1" head="$2" r
  r="$(perf_latest "$feature")"
  if [ -z "$r" ]; then
    [ -z "$ORCH_T_PERF" ] || printf '  perf: NO READING (ORCH_T_PERF=%s is set)\n' "$ORCH_T_PERF"
    return 0
  fi
  printf '  perf: worst %s%% (%s) over %s interleaved runs against the base, at %s%s\n' \
    "$(printf '%s' "$r" | jq -r .worst_pct)" "$(printf '%s' "$r" | jq -r '.worst // "-"')" "$(printf '%s' "$r" | jq -r .runs)" \
    "$(printf '%s' "$r" | jq -r '.at_sha[0:12]')" "$([ "$(printf '%s' "$r" | jq -r .at_sha)" = "$head" ] || printf '  (NOT at HEAD)')"
  printf '%s' "$r" | jq -r '.rows[] | "      \(.name)  \(.base) -> \(.head)  \(if .pct > 0 then "+" else "" end)\(.pct)%  spread \(.noise_pct)%\(if .over_budget then "  OVER BUDGET \(.budget)" elif .budget != null then "  budget \(.budget)" else "" end)"'
  [ "$(printf '%s' "$r" | jq '.new | length')" = 0 ] || printf '      new at HEAD (no base to compare): %s\n' "$(printf '%s' "$r" | jq -r '.new | join(", ")')"
}
