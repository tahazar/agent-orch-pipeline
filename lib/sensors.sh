#!/bin/bash
# sensors.sh - diff coverage and mutation score, as attested numbers.
#
# Line coverage says a line ran; mutation score says a test would notice if
# the line were wrong. A suite with full coverage and a low mutation score
# exercises the code and asserts nothing about it — which is precisely the
# suite an agent writes once it has seen the implementation. Böckeler's
# recommendation for agent-written tests was mutation testing as the sensor
# [P42]; this is that, plus the mechanical form of "nothing is written that a
# test did not demand": coverage of the lines the diff added or changed.
#
# Both are report lines first. Each becomes a gate only when its threshold is
# set (ORCH_T_DIFF_COV, ORCH_T_MUTATION), because a threshold nobody has
# measured against is a guess with a mechanism attached, and `orch report` is
# how the guess gets replaced.
#
# What this trusts, stated plainly: the lcov file and the mutation report are
# produced by tools the developer runs. This file requires an attested run at
# the same sha so that at least a command happened, and it counts only the
# lines the diff touched. It does not prove the report was not hand-written.
# The clean-worktree replay at the gate (docs/AGENT-TDD.md, phase 4) is where
# that would be proved; until then a forged report is an escape hatch the
# axiom scan does not see.
#
# Formats: lcov (`SF:` / `DA:line,count`), which coverage.py (`coverage lcov`),
# istanbul/jest, cargo-llvm-cov and gcov2lcov all write; Stryker's
# mutation.json; cargo-mutants' outcomes.json; or a score printed as the last
# line of an attested `mutation` run for anything else.

[ -n "${ORCH_SENSORS_SOURCED:-}" ] && return 0
ORCH_SENSORS_SOURCED=1

# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"
# shellcheck source=statement.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statement.sh"
# shellcheck source=escalate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/escalate.sh"

: "${ORCH_LCOV:=coverage/lcov.info}"
: "${ORCH_STRYKER:=reports/mutation/mutation.json}"
: "${ORCH_CARGO_MUTANTS:=mutants.out/outcomes.json}"
# What counts as source. Coverage of a README or a lockfile is not a number,
# and a changed dotfile is not an unmeasured module.
: "${ORCH_SOURCE_EXT:=py js jsx ts tsx mjs cjs go rs rb java kt kts cs php swift c cc cpp cxx h hpp m mm scala ex exs}"
: "${ORCH_T_DIFF_COV:=}"     # percent; empty = report only
: "${ORCH_T_MUTATION:=}"     # percent; empty = report only

_sensor_repo() { printf '%s' "${ORCH_REPO:-$(orch_repo_root)}"; }
_sensor_base() { git -C "$(_sensor_repo)" merge-base "$(escalate_base_branch)" "${1:-HEAD}" 2>/dev/null || escalate_base_branch; }

_sensor_is_source() {  # _sensor_is_source <path>
  local p="$1" e
  case "$p" in .*|*/.*) return 1 ;; esac
  case "$p" in *.*) ;; *) return 1 ;; esac
  for e in $ORCH_SOURCE_EXT; do [ "${p##*.}" = "$e" ] && return 0; done
  return 1
}

_sensor_is_test() {  # any test path, oracle or dev — coverage is of production code
  local p="$1" g
  set -f
  for g in $ORCH_TEST_GLOB $ORCH_DEV_TEST_GLOB; do
    case "$p" in $g|"${g%/\*}"/*) set +f; return 0 ;; esac
  done
  set +f; return 1
}

# "<file> <line>" for every line the diff added or changed, production only.
sensor_diff_lines() {  # sensor_diff_lines <base> <head>
  local file
  git -C "$(_sensor_repo)" diff -U0 "$1" "$2" -- . ':(exclude)docs/features' 2>/dev/null \
  | awk '
      /^\+\+\+ / { f = $2; sub(/^b\//, "", f); next }
      /^@@ / { split($3, p, ","); s = p[1]; sub(/^\+/, "", s)
               n = (p[2] == "" ? 1 : p[2])
               for (i = 0; i < n; i++) print f, s + i }' \
  | while read -r file line; do
      _sensor_is_source "$file" || continue
      _sensor_is_test "$file" || printf '%s %s\n' "$file" "$line"
    done
}

# "<file> <line> <count>" from an lcov file, paths made repo-relative.
sensor_lcov_lines() {  # sensor_lcov_lines <lcov-file>
  local repo; repo="$(_sensor_repo)"
  awk -v repo="$repo/" '
    /^SF:/ { f = substr($0, 4); sub("^" repo, "", f); sub(/^\.\//, "", f); next }
    /^DA:/ { split(substr($0, 4), d, ","); print f, d[1], d[2] }' "$1" 2>/dev/null
}

# sensor_coverage <feature> [--lcov F] [--sha S] [--base B]
#
# Diff coverage: of the executable lines the diff touched, how many ran.
# A changed file that the report never saw is listed as unmeasured rather
# than folded into the percentage — a module no test imports is a different
# finding from a branch no test reaches, and it should not hide behind the
# non-executable lines it happens to contain.
sensor_coverage() {
  local feature="$1"; shift
  local lcov="$ORCH_LCOV" sha='' base='' d l repo n_lines covered uncovered unmeasured pct j
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lcov) lcov="$2"; shift 2 ;;
      --sha)  sha="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      *) die "sensor coverage: unexpected argument '$1'" ;;
    esac
  done
  repo="$(_sensor_repo)"
  [ -n "$sha" ] || sha="$(orch_head_sha)"
  [ -n "$base" ] || base="$(_sensor_base "$sha")"
  case "$lcov" in /*) ;; *) lcov="$repo/$lcov" ;; esac
  [ -r "$lcov" ] || die "sensor coverage: no lcov report at $lcov (ORCH_LCOV, or --lcov)"
  # At least a command produced it: an attested `coverage` run at this sha.
  evidence_verify "$feature" coverage --claim pass >/dev/null 2>&1 \
    || die "sensor coverage: no attested passing \`coverage\` run for $feature — run the tool through orch:
  orch run --feature $feature --label coverage -- <command that writes $lcov>"
  [ "$(evidence_latest "$feature" coverage | jq -r '.git_sha // ""')" = "$sha" ] \
    || die "sensor coverage: the attested coverage run is not at $sha — run it again"

  d="$(mktemp "${TMPDIR:-/tmp}/orch-cov.XXXXXX")"; l="$(mktemp "${TMPDIR:-/tmp}/orch-cov.XXXXXX")"
  sensor_diff_lines "$base" "$sha" | sort > "$d"
  sensor_lcov_lines "$lcov" | sort > "$l"
  j="$(awk '
    NR == FNR { seen[$1] = 1; cnt[$1 " " $2] = $3; next }
    { key = $1 " " $2
      if (!($1 in seen)) { um[$1] = 1; next }
      if (!(key in cnt)) next            # not executable per the report
      total++
      if (cnt[key] + 0 > 0) covered++
      else printf "%s:%s\n", $1, $2 > "/dev/stderr"
    }
    END { for (f in um) printf "UNMEASURED %s\n", f > "/dev/stderr"
          printf "%d %d\n", total + 0, covered + 0 }' "$l" "$d" 2>"$d.err")"
  n_lines="${j%% *}"; covered="${j##* }"
  uncovered="$(grep -v '^UNMEASURED ' "$d.err" | jq -R . | jq -s -c '.')"
  unmeasured="$(sed -n 's/^UNMEASURED //p' "$d.err" | sort | jq -R . | jq -s -c '.')"
  rm -f "$d" "$l" "$d.err"
  if [ "${n_lines:-0}" -gt 0 ]; then pct=$(( covered * 100 / n_lines )); else pct=null; fi

  ORCH_LEDGER_FEATURE="$feature" ledger_append sensor.diff_coverage \
    at_sha "$sha" base "$base" lines:raw "$n_lines" covered:raw "$covered" pct:raw "$pct" \
    uncovered:raw "$uncovered" unmeasured:raw "$unmeasured"
  jq -n -c --arg sha "$sha" --argjson lines "$n_lines" --argjson covered "$covered" --argjson pct "$pct" \
    --argjson uncovered "$uncovered" --argjson unmeasured "$unmeasured" '$ARGS.named'
}

# sensor_mutation <feature> [--from stryker|cargo-mutants|evidence] [--file F] [--sha S] [--base B]
#
# Restricted to the files the diff touched when the report is per-file
# (Stryker, cargo-mutants); the whole run otherwise. `evidence` reads the
# score from the last numeric line of an attested `mutation` run — the way a
# best-of-N metric is read — for tools whose report this file cannot parse.
sensor_mutation() {
  local feature="$1"; shift
  local from='' file='' sha='' base='' repo changed j score killed survived total scope
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --file) file="$2"; shift 2 ;;
      --sha)  sha="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      *) die "sensor mutation: unexpected argument '$1'" ;;
    esac
  done
  repo="$(_sensor_repo)"
  [ -n "$sha" ] || sha="$(orch_head_sha)"
  [ -n "$base" ] || base="$(_sensor_base "$sha")"
  if [ -z "$from" ]; then
    if   [ -r "$repo/${file:-$ORCH_STRYKER}" ] && [ -z "$file" ]; then from=stryker
    elif [ -r "$repo/$ORCH_CARGO_MUTANTS" ]; then from=cargo-mutants
    else from=evidence; fi
  fi
  changed="$(git -C "$repo" diff --name-only "$base" "$sha" -- . ':(exclude)docs/features' 2>/dev/null | jq -R . | jq -s -c '.')"

  case "$from" in
    stryker)
      file="${file:-$ORCH_STRYKER}"; case "$file" in /*) ;; *) file="$repo/$file" ;; esac
      [ -r "$file" ] || die "sensor mutation: no Stryker report at $file"
      j="$(jq -c --argjson ch "$changed" --arg repo "$repo/" '
        (.files | to_entries | map(.key |= (ltrimstr($repo) | ltrimstr("./")))) as $all
        | ([$all[] | select(.key as $k | $ch | index($k))]) as $mine
        | (if ($mine|length) > 0 then {rows: $mine, scope: "changed"} else {rows: $all, scope: "all"} end) as $s
        | [$s.rows[].value.mutants[]] as $m
        | {killed: ([$m[] | select(.status=="Killed" or .status=="Timeout")] | length),
           survived: ([$m[] | select(.status=="Survived" or .status=="NoCoverage")] | length),
           scope: $s.scope}' "$file" 2>/dev/null)" || die "sensor mutation: could not parse $file as a Stryker report"
      ;;
    cargo-mutants)
      file="${file:-$ORCH_CARGO_MUTANTS}"; case "$file" in /*) ;; *) file="$repo/$file" ;; esac
      [ -r "$file" ] || die "sensor mutation: no cargo-mutants report at $file"
      j="$(jq -c --argjson ch "$changed" '
        [.outcomes[] | select((.scenario|type)=="object" and .scenario.Mutant != null) | {file: .scenario.Mutant.file, s: .summary}] as $all
        | ([$all[] | select(.file as $k | $ch | index($k))]) as $mine
        | (if ($mine|length) > 0 then {rows: $mine, scope: "changed"} else {rows: $all, scope: "all"} end) as $s
        | {killed: ([$s.rows[] | select(.s=="CaughtMutant" or .s=="Timeout")] | length),
           survived: ([$s.rows[] | select(.s=="MissedMutant")] | length),
           scope: $s.scope}' "$file" 2>/dev/null)" || die "sensor mutation: could not parse $file as a cargo-mutants report"
      ;;
    evidence)
      score="$(evidence_latest "$feature" mutation | jq -r 'select(.exit_code==0) | .stdout_tail // ""' 2>/dev/null \
        | tr -d '\r' | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)"
      [ -n "$score" ] || die "sensor mutation: no attested \`mutation\` run printing a score for $feature:
  orch run --feature $feature --label mutation -- <command whose last line is the score>"
      # A fraction is a percentage that forgot to multiply.
      case "$score" in 0.*|1.0*|1) score="$(awk -v s="$score" 'BEGIN { printf "%d", s * 100 }')" ;; *) score="${score%%.*}" ;; esac
      j="$(jq -n -c --argjson s "$score" '{killed: null, survived: null, scope: "all", pct: $s}')"
      ;;
    *) die "sensor mutation: --from must be stryker, cargo-mutants, or evidence" ;;
  esac

  killed="$(printf '%s' "$j" | jq -r '.killed')"; survived="$(printf '%s' "$j" | jq -r '.survived')"
  scope="$(printf '%s' "$j" | jq -r '.scope')"
  if [ "$killed" != "null" ]; then
    total=$((killed + survived))
    if [ "$total" -gt 0 ]; then score=$(( killed * 100 / total )); else score=null; fi
  else
    total=null; score="$(printf '%s' "$j" | jq -r '.pct')"
  fi
  ORCH_LEDGER_FEATURE="$feature" ledger_append sensor.mutation \
    at_sha "$sha" from "$from" scope "$scope" killed:raw "$killed" survived:raw "$survived" total:raw "$total" pct:raw "$score"
  jq -n -c --arg sha "$sha" --arg from "$from" --arg scope "$scope" \
    --argjson killed "$killed" --argjson survived "$survived" --argjson total "$total" --argjson pct "$score" '$ARGS.named'
}

# The latest reading of each sensor, for the report and the gate.
sensor_latest() {  # sensor_latest <feature> <diff_coverage|mutation>
  ledger_read "$1" | jq -c -s --arg e "sensor.$2" '
    [.[] | select(type=="object" and .event==$e)] | if length==0 then empty else .[-1] end' 2>/dev/null
}

# sensor_gate <feature> <sha> -> 0, or 8 with the reason on stderr.
#
# Only the sensors with a threshold set are gates. A reading at another sha
# is no reading: the number has to describe the diff being approved.
sensor_gate() {
  local feature="$1" sha="$2" r pct at
  if [ -n "$ORCH_T_DIFF_COV" ]; then
    r="$(sensor_latest "$feature" diff_coverage)"
    at="$(printf '%s' "$r" | jq -r '.at_sha // ""' 2>/dev/null)"
    if [ -z "$r" ] || [ "$at" != "$sha" ]; then
      printf 'SENSOR_MISSING: no diff-coverage reading at %s (ORCH_T_DIFF_COV=%s is set).\n  orch run --feature %s --label coverage -- <cmd>; orch sensor coverage %s\n' \
        "$(printf '%s' "$sha" | cut -c1-12)" "$ORCH_T_DIFF_COV" "$feature" "$feature" >&2
      return 8
    fi
    pct="$(printf '%s' "$r" | jq -r '.pct // "null"')"
    if [ "$pct" = "null" ] || [ "$pct" -lt "$ORCH_T_DIFF_COV" ] || [ "$(printf '%s' "$r" | jq '.unmeasured | length')" -gt 0 ]; then
      printf 'SENSOR_BELOW: diff coverage is %s%% of %s changed executable lines (threshold %s%%); unmeasured files: %s\n  uncovered: %s\n' \
        "$pct" "$(printf '%s' "$r" | jq -r .lines)" "$ORCH_T_DIFF_COV" \
        "$(printf '%s' "$r" | jq -r '.unmeasured | join(", ") | if .=="" then "none" else . end')" \
        "$(printf '%s' "$r" | jq -r '.uncovered | join(", ") | if .=="" then "none" else . end')" >&2
      return 8
    fi
  fi
  if [ -n "$ORCH_T_MUTATION" ]; then
    r="$(sensor_latest "$feature" mutation)"
    at="$(printf '%s' "$r" | jq -r '.at_sha // ""' 2>/dev/null)"
    if [ -z "$r" ] || [ "$at" != "$sha" ]; then
      printf 'SENSOR_MISSING: no mutation reading at %s (ORCH_T_MUTATION=%s is set).\n  orch sensor mutation %s\n' \
        "$(printf '%s' "$sha" | cut -c1-12)" "$ORCH_T_MUTATION" "$feature" >&2
      return 8
    fi
    pct="$(printf '%s' "$r" | jq -r '.pct // "null"')"
    if [ "$pct" = "null" ] || [ "$pct" -lt "$ORCH_T_MUTATION" ]; then
      printf 'SENSOR_BELOW: mutation score is %s%% (threshold %s%%, scope %s): the suite runs the code and does not notice when it is wrong.\n' \
        "$pct" "$ORCH_T_MUTATION" "$(printf '%s' "$r" | jq -r .scope)" >&2
      return 8
    fi
  fi
  return 0
}
