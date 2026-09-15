#!/bin/bash
# waves.sh - the feature dependency graph.
#
# Prove2Me coordinated thousands of agents on one proof with a directed
# acyclic graph of statements: take an open node, prove it, publish; a parent
# resolves when its children have [P37]. The same shape one level up: a
# feature declares what it depends on, a wave is every feature whose
# dependencies have landed, and the director starts a wave's crews together.
# Independence is declared, not inferred — the director says what depends on
# what, and the graph holds it to that.
#
#   orch feature start F --after A,B     declares the edges
#   orch waves                           the graph, with each feature's state
#   orch waves next [--start]            ready features: refresh from base; spawn
#
# A dependent feature branches from the base at start, before its
# dependencies land. When they do, `waves next` merges the base into its
# branch, so its crew begins on the code it depends on.

[ -n "${ORCH_WAVES_SOURCED:-}" ] && return 0
ORCH_WAVES_SOURCED=1

# shellcheck source=merge.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge.sh"
# shellcheck source=tier.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tier.sh"

waves_after() {  # waves_after <feature> -> its declared dependencies, space-separated
  ledger_read "$1" | jq -r -s '[.[] | select(type=="object" and .event=="feature.started")] | last | .after // "" ' 2>/dev/null | tr ',' ' '
}

waves_crewed() {  # a crew has been spawned for it
  ledger_read "$1" | jq -e -s 'any(.[]; type=="object" and (.event=="agent.spawned" or .event=="agent.printed") and .role!="director")' >/dev/null 2>&1
}

# waves_blockers <feature> -> the dependencies not yet landed
waves_blockers() {
  local d out=''
  for d in $(waves_after "$1"); do merge_landed "$d" || out="$out $d"; done
  printf '%s' "${out# }"
}

waves_state() {  # waves_state <feature> -> landed | blocked | ready | running
  if merge_landed "$1"; then printf landed
  elif [ -n "$(waves_blockers "$1")" ]; then printf blocked
  elif waves_crewed "$1"; then printf running
  else printf ready; fi
}

waves_render() {
  local f st b
  printf '%-24s %-9s %s\n' feature state after
  for f in $(orch_features_list); do
    st="$(waves_state "$f")"; b="$(waves_blockers "$f")"
    printf '%-24s %-9s %s%s\n' "$f" "$st" "$(waves_after "$f" | tr ' ' ',')" "${b:+   (waiting for ${b// /, })}"
  done
}

# waves_next [--start] — every ready feature: merge the base into its branch
# so it carries what landed, then print the command that starts its crew, or
# run it with --start.
waves_next() {
  local start=0 f base repo n=0
  [ "${1:-}" = "--start" ] && start=1
  base="$(escalate_base_branch)"
  for f in $(orch_features_list); do
    [ "$(waves_state "$f")" = ready ] || continue
    repo="$(orch_feature_repo "$f")"
    if [ -n "$(waves_after "$f")" ]; then
      git -C "$repo" merge -q --no-edit "$base" >/dev/null 2>&1 \
        || { warn "waves: $f could not merge $base cleanly — resolve in $repo"; continue; }
      ORCH_LEDGER_FEATURE="$f" ledger_append wave.refreshed base "$base" base_sha "$(git -C "$repo" rev-parse "$base")"
    fi
    n=$((n + 1))
    if [ "$start" = "1" ] && tier_is_confirmed "$f"; then
      ORCH_FEATURE="$f" "$ORCH_ROOT_BIN" team start --feature "$f" 2>&1 | sed 's/^/  /'
    else
      printf 'ready: %s%s\n' "$f" "$(tier_is_confirmed "$f" && printf '   orch team start --feature %s' "$f" || printf '   (no tier confirmed yet: orch spawn tech-lead --feature %s)' "$f")"
    fi
  done
  [ "$n" -gt 0 ] || printf 'nothing is ready: every unlanded feature is running or waiting.\n'
}
