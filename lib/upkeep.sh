#!/bin/bash
# upkeep.sh - the upkeep layer: a repo-wide census, overnight refactor
# passes, and a morning to keep or discard them.
#
# Anthropic runs "automated Claude-driven routines that iteratively improve
# the codebase" on a schedule. This is that, on orch's terms: nothing is
# improved on a model's say-so, every pass is judged by the refactor exit
# (tests green, oracle unchanged, no new escape hatch, diff no larger, metrics
# no worse), and the human picks in the morning from passes that already
# hold, never from promises.
#
#   scan     a census of the repository, per file, from things git and grep
#            can count: size, churn, escape hatches (the whole-repo
#            `#print axioms`), TODOs, tests older than the source they test,
#            uncovered lines when an lcov report exists, and any attested
#            per-file metric a tool printed. Ranked; no model call.
#   plan     the top files become upkeep features with mechanical requests.
#   night    each feature gets a green attestation, an oracle freeze (the
#            existing suite IS the oracle), and a refactor pass in its own
#            worktree on a fresh developer, landing on a branch, not on HEAD —
#            N passes from one base cannot all fast-forward.
#   morning  what held, with the numbers; keep merges, discard archives.
#
# The log half — maintenance driven by production errors and latency — is
# not here yet. It needs telemetry this file cannot assume, and it must read
# attested aggregates, never raw logs.

[ -n "${ORCH_UPKEEP_SOURCED:-}" ] && return 0
ORCH_UPKEEP_SOURCED=1

# shellcheck source=refactor.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/refactor.sh"
# shellcheck source=sensors.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sensors.sh"

: "${ORCH_UPKEEP_TOP:=3}"
: "${ORCH_UPKEEP_CHURN_DAYS:=90}"
: "${ORCH_UPKEEP_TIER:=standard}"

upkeep_path() { printf '%s/census.jsonl' "$(orch_feature_dir _orch)"; }

# Does <path> look like the test for <source>? Name-based, best effort.
_upkeep_test_for() {  # _upkeep_test_for <source> -> newest matching test path or ''
  local base stem
  base="$(basename "$1")"; stem="${base%.*}"
  git -C "$ORCH_REPO" ls-files 2>/dev/null | while IFS= read -r p; do
    _sensor_is_test "$p" || continue
    case "$(basename "$p")" in
      "test_$stem".*|"$stem"_test.*|"$stem".test.*|"$stem"_spec.*|"$stem".spec.*|"${stem}Test".*) printf '%s\n' "$p" ;;
    esac
  done | head -1
}

# upkeep_scan [--top N] -> JSON array, ranked, and the census on disk.
upkeep_scan() {
  local top="$ORCH_UPKEEP_TOP" since lcov f lines churn hatches todos test_stale uncovered pat n metric rows='' j
  while [ "$#" -gt 0 ]; do case "$1" in --top) top="$2"; shift 2 ;; *) shift ;; esac; done
  since="$(date -u -d "-${ORCH_UPKEEP_CHURN_DAYS} days" +%Y-%m-%d 2>/dev/null || date -u -v-"${ORCH_UPKEEP_CHURN_DAYS}"d +%Y-%m-%d)"
  lcov="$ORCH_REPO/$ORCH_LCOV"
  for f in $(git -C "$ORCH_REPO" ls-files 2>/dev/null); do
    _sensor_is_source "$f" || continue
    _sensor_is_test "$f" && continue
    lines="$(wc -l < "$ORCH_REPO/$f" | tr -d ' ')"
    churn="$(git -C "$ORCH_REPO" log --since="$since" --format=%h -- "$f" 2>/dev/null | grep -c .)"
    hatches="$(axioms_patterns | while IFS= read -r pat; do grep -cE -- "$pat" "$ORCH_REPO/$f" 2>/dev/null || printf '0\n'; done \
      | awk '{s+=$1} END {print s+0}')"
    todos="$(grep -cE 'TODO|FIXME|XXX|HACK' "$ORCH_REPO/$f" 2>/dev/null)"
    test_stale=false
    t="$(_upkeep_test_for "$f")"
    if [ -n "$t" ]; then
      [ "$(git -C "$ORCH_REPO" log -1 --format=%ct -- "$f" 2>/dev/null)" -gt "$(git -C "$ORCH_REPO" log -1 --format=%ct -- "$t" 2>/dev/null || printf 0)" ] && test_stale=true
    else
      t=''
    fi
    uncovered=null
    if [ -r "$lcov" ]; then
      n="$(sensor_lcov_lines "$lcov" | awk -v f="$f" '$1==f && $3==0 {c++} END {print c+0}')"
      [ "$(sensor_lcov_lines "$lcov" | awk -v f="$f" '$1==f {c++} END {print c+0}')" -gt 0 ] && uncovered="$n"
    fi
    # An attested per-file metric, if a tool printed "<number> <path>" lines.
    metric="$(evidence_latest _orch upkeep-metrics 2>/dev/null | jq -r '.stdout_tail // ""' | awk -v f="$f" '$2==f {print $1}' | tail -1)"
    j="$(orch_json file "$f" lines:raw "$lines" churn:raw "${churn:-0}" hatches:raw "${hatches:-0}" todos:raw "${todos:-0}" \
          test "$t" test_stale:raw "$test_stale" uncovered:raw "$uncovered" metric:raw "${metric:-null}")"
    rows="${rows}${j}
"
  done
  # The score is a guess with a mechanism attached: escape hatches and stale
  # tests weigh most, because they are the two the floor would have refused
  # in a new feature; then churn on size, then uncovered lines, then TODOs.
  printf '%s' "$rows" | grep -v '^$' | jq -s -c --argjson top "$top" '
    map(. + {score: ((.hatches * 20) + (if .test_stale then 15 else 0 end)
                     + ((.churn * .lines) / 200 | floor) + ((.uncovered // 0) / 4 | floor) + (.todos * 2)
                     + (if .metric != null then (.metric | floor) else 0 end))})
    | sort_by(-.score, .file) | .[:$top]' \
    | tee >(jq -c '.[]' > "$(upkeep_path)") 
  ORCH_LEDGER_FEATURE=_orch ledger_append upkeep.scanned top:raw "$top" since "$since"
}

upkeep_render() {  # upkeep_render <json>
  printf '%s' "$1" | jq -r '.[] | "  \(.score | tostring | .[0:5])  \(.file)  " + ([
      (if .hatches > 0 then "\(.hatches) hatch(es)" else empty end),
      (if .test_stale then "tests older than source" else empty end),
      (if .test == "" then "no test" else empty end),
      "\(.lines) lines, \(.churn) changes",
      (if .uncovered != null then "\(.uncovered) uncovered" else empty end),
      (if .todos > 0 then "\(.todos) TODO" else empty end),
      (if .metric != null then "metric \(.metric)" else empty end)
    ] | join(", "))'
}

_upkeep_next_id() {  # the next free F9NN id, so upkeep features sort after product ones
  local n=900
  while orch_features_list | grep -q "^F$n-"; do n=$((n + 1)); done
  printf 'F%s' "$n"
}
_upkeep_features() { orch_features_list | grep -- '-upkeep-'; }

# The open upkeep feature for a file, if one exists: planned or started, and
# neither kept nor discarded. A nightly re-run must not plan a file twice.
_upkeep_open_for() {  # _upkeep_open_for <file> -> feature id or ''
  local id
  for id in $(_upkeep_features); do
    ledger_read "$id" | jq -e -s --arg f "$1" '
      any(.[]; .event=="upkeep.planned" and .file==$f)
      and (any(.[]; .event=="upkeep.kept" or .event=="upkeep.discarded" or .event=="refactor.discarded") | not)' >/dev/null 2>&1 \
      && { printf '%s' "$id"; return 0; }
  done
  return 1
}

# upkeep_plan [--top N] — one upkeep feature per ranked file, requests
# written mechanically from the census. A file with an open upkeep feature
# is listed under that feature, not planned again.
upkeep_plan() {
  local census f slug id req row base
  census="$(upkeep_scan "$@")"
  base="$(escalate_base_branch)"
  printf '%s' "$census" | jq -c '.[]' | while IFS= read -r row; do
    f="$(printf '%s' "$row" | jq -r .file)"
    if id="$(_upkeep_open_for "$f")"; then printf '%s  %s\n' "$id" "$f"; continue; fi
    slug="upkeep-$(printf '%s' "$f" | tr '/.' '--' | tr -c 'A-Za-z0-9-\n' '-' | cut -c1-40)"
    id="$(_upkeep_next_id)-$slug"
    req="$(printf '%s' "$row" | jq -r '
      "Upkeep of \(.file). Behaviour must not change; the existing test suite is the oracle and is frozen.\n\nWhat the census found:\n"
      + (if .hatches > 0 then "- \(.hatches) escape hatch(es) (skip/ignore/disable) — remove them or make the code not need them\n" else "" end)
      + (if .test_stale then "- its test (\(.test)) is older than the source — the source changed without the test changing\n" else "" end)
      + (if .test == "" then "- no test named for it\n" else "" end)
      + "- \(.lines) lines, \(.churn) changes in the window\n"
      + (if .uncovered != null then "- \(.uncovered) uncovered lines in the last coverage report\n" else "" end)
      + (if .todos > 0 then "- \(.todos) TODO/FIXME\n" else "" end)
      + "\nR1 every existing test still passes\nR2 the file is smaller or simpler, with the numbers above not worse\nR3 no new skip, ignore, disabled lint, or changed test config\n"')"
    "$ORCH_ROOT_BIN" feature start "$id" --request "$req" --tier "$ORCH_UPKEEP_TIER" >/dev/null 2>&1 \
      || { warn "upkeep plan: could not start $id"; continue; }
    ORCH_LEDGER_FEATURE="$id" ledger_append upkeep.planned file "$f" score:raw "$(printf '%s' "$row" | jq -r .score)"
    printf '%s  %s\n' "$id" "$f"
  done
}

# upkeep_night [--top N] — plan, then for each feature: attest green on the
# base, freeze the oracle, start a refactor pass that lands on a branch.
upkeep_night() {
  local base line id f cur
  base="$(escalate_base_branch)"
  cur="$(git -C "$ORCH_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "${ORCH_TEST_CMD:-}" ] || die "upkeep night: ORCH_TEST_CMD is not set — the suite is the oracle, and orch has to run it"
  [ "$(git -C "$ORCH_REPO" status --porcelain -- . ':(exclude)docs/features' ':(exclude).orch' | grep -c .)" = "0" ] \
    || die "upkeep night: the tree is dirty — commit or stash first; every pass starts from a clean base"
  upkeep_plan "$@" | while IFS='  ' read -r id f; do
    [ -n "$id" ] || continue
    # feature start made a worktree for <id>; --feature resolves to it.
    "$ORCH_ROOT_BIN" run --feature "$id" --label build -- sh -c "${ORCH_BUILD_CMD:-true}" >/dev/null 2>&1 \
      || { ORCH_LEDGER_FEATURE="$id" ledger_append upkeep.skipped reason "build red on the base"; warn "upkeep: $id — build red on the base, skipped"; continue; }
    "$ORCH_ROOT_BIN" run --feature "$id" --label tests -- sh -c "$ORCH_TEST_CMD" >/dev/null 2>&1 \
      || { ORCH_LEDGER_FEATURE="$id" ledger_append upkeep.skipped reason "tests red on the base"; warn "upkeep: $id — tests red on the base, skipped"; continue; }
    "$ORCH_ROOT_BIN" oracle freeze "$id" >/dev/null 2>&1
    ORCH_REFACTOR_LAND=branch "$ORCH_ROOT_BIN" refactor start "$id" 2>&1 | sed 's/^/  /'
    ORCH_LEDGER_FEATURE="$id" ledger_append upkeep.started file "$f"
  done
  printf '\nupkeep night started. In the morning:  orch upkeep morning\n'
}

# upkeep_morning — every upkeep feature and where its pass stands.
upkeep_morning() {
  local id st row
  printf 'upkeep morning\n\n'
  for id in $(_upkeep_features); do
    row="$(ledger_read "$id" | jq -c -s '[.[] | select(type=="object" and (.event | startswith("refactor.") or startswith("upkeep.")))] | last // {}' 2>/dev/null)"
    st="$(printf '%s' "$row" | jq -r '.event // "none"')"
    case "$st" in
      refactor.kept)
        printf '  KEPT      %s  %s -> %s lines  branch %s\n    orch upkeep keep %s   |   orch upkeep discard %s\n' \
          "$id" "$(printf '%s' "$row" | jq -r .pre_diff_lines)" "$(printf '%s' "$row" | jq -r .post_diff_lines)" \
          "$(printf '%s' "$row" | jq -r '.landed // "-"')" "$id" "$id" ;;
      refactor.discarded)
        printf '  DISCARDED %s  %s\n' "$id" "$(printf '%s' "$row" | jq -r .reason)" ;;
      refactor.started|upkeep.started)
        printf '  OPEN      %s  pass still running or unfinished (orch refactor finish %s)\n' "$id" "$id" ;;
      upkeep.kept|upkeep.discarded)
        printf '  done      %s  %s\n' "$id" "${st#upkeep.}" ;;
      *) printf '  %-9s %s  %s\n' "${st#upkeep.}" "$id" "$(printf '%s' "$row" | jq -r '.reason // ""')" ;;
    esac
  done
}

# upkeep_keep <feature> — the human's verb: merge the kept branch into the base.
upkeep_keep() {
  local id="$1" br base
  br="$(ledger_read "$id" | jq -r -s '[.[] | select(type=="object" and .event=="refactor.kept")] | last | .landed // ""' 2>/dev/null)"
  [ -n "$br" ] || die "upkeep keep: $id has no kept pass on a branch"
  base="$(escalate_base_branch)"
  git -C "$(orch_main_repo)" checkout -q "$base" || die "upkeep keep: could not check out $base"
  git -C "$(orch_main_repo)" merge -q --no-ff -m "upkeep: $id" "$br" || die "upkeep keep: merge of $br into $base failed — resolve by hand"
  git -C "$ORCH_REPO" branch -D "$br" >/dev/null 2>&1 || true
  ORCH_LEDGER_FEATURE="$id" ledger_append upkeep.kept branch "$br" into "$base"
  printf 'kept %s into %s\n' "$id" "$base"
}

upkeep_discard() {
  local id="$1" br
  br="$(ledger_read "$id" | jq -r -s '[.[] | select(type=="object" and .event=="refactor.kept")] | last | .landed // ""' 2>/dev/null)"
  [ -n "$br" ] && git -C "$ORCH_REPO" branch -D "$br" >/dev/null 2>&1
  ORCH_LEDGER_FEATURE="$id" ledger_append upkeep.discarded branch "${br:-}" why "${2:-}"
  printf 'discarded %s%s\n' "$id" "${2:+ — $2}"
}
