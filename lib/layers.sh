#!/bin/bash
# layers.sh - which parts of orch a repository has switched on.
#
# A library wants the verification floor and a crew. A service wants those
# and overnight upkeep. A product wants personas on top. Each layer depends
# only on the one below, and a repo names the ones it uses in
# .claude/orch.json:
#
#   { "layers": ["floor", "crew", "upkeep"] }
#
#   floor    attested evidence, frozen statement and oracle, axioms, sensors,
#            the packet. git, jq and a test command; no crew, no personas.
#   crew     tiers, blind roles, reviewers, auditor, refactor pass, read-back,
#            holdout. Needs the Claude Code launcher and substrate.
#   upkeep   repo-wide census, overnight refactor passes, morning selection.
#   product  personas, stories, the walkthrough, the night. Not built yet.
#
# Absent file: floor and crew, which is what orch did before layers existed.
# A command from a layer that is off refuses with one line saying so — the
# alternative, a command that half-works because its prerequisites are
# missing, is how a pipeline acquires mysteries.

[ -n "${ORCH_LAYERS_SOURCED:-}" ] && return 0
ORCH_LAYERS_SOURCED=1

# shellcheck source=common.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ORCH_LAYERS_ALL="floor crew upkeep product"
ORCH_LAYERS_DEFAULT="floor crew"

layers_path() { printf '%s/.claude/orch.json' "$(orch_main_repo)"; }

# The enabled layers, space-separated, in canonical order. floor is always on.
layers_enabled() {
  local f on l out=''
  f="$(layers_path)"
  if [ -r "$f" ]; then
    on="$(jq -r '.layers // [] | join(" ")' "$f" 2>/dev/null)"
  else
    on="$ORCH_LAYERS_DEFAULT"
  fi
  for l in $ORCH_LAYERS_ALL; do
    case " floor $on " in *" $l "*) out="$out $l" ;; esac
  done
  printf '%s' "${out# }"
}

layer_enabled() { case " $(layers_enabled) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# layer_require <layer> — die with the one line, unless on.
layer_require() {
  layer_enabled "$1" && return 0
  die "the \`$1\` layer is off for this repository. Enable it in $(layers_path):
  orch init --profile $(case "$1" in upkeep) printf service ;; product) printf product ;; *) printf library ;; esac)
or add \"$1\" to \"layers\" by hand. Layers on now: $(layers_enabled)"
}

# layers_profile <library|service|product> -> the layer list it means.
layers_profile() {
  case "$1" in
    library) printf 'floor crew' ;;
    service) printf 'floor crew upkeep' ;;
    product) printf 'floor crew upkeep product' ;;
    *) return 1 ;;
  esac
}

# layers_write <layer...> — write .claude/orch.json, keeping other keys.
layers_write() {
  local f cur
  f="$(layers_path)"
  mkdir -p "$(dirname "$f")"
  cur="$(cat "$f" 2>/dev/null)"; [ -n "$cur" ] || cur='{}'
  printf '%s' "$cur" | jq --arg l "$*" '.layers = ($l | split(" "))' | orch_atomic_write "$f"
}

# What each layer needs, for doctor: "ok" or the missing thing.
layers_prereq() {  # layers_prereq <layer> -> '' if satisfied, else the gap
  case "$1" in
    floor)   have git && have jq || printf 'git and jq' ;;
    crew)    have claude || printf 'the claude CLI on PATH' ;;
    upkeep)  have claude || printf 'the claude CLI on PATH' ;;
    product) printf 'not built yet' ;;
  esac
  return 0
}
