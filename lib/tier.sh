#!/bin/bash
# tier.sh - what the developer asked for, as opposed to what the evidence forces.
#
# Two things size a feature's crew, and conflating them was the mistake this
# file exists to undo:
#
#   tier        chosen up front by a human, from the shape of the work
#   escalation  forced later by mechanical signals, from how the work is going
#
# They are the same ladder. A tier IS a rung — quick=0, standard=1, strict=2 —
# so choosing `strict` and being escalated to rung 2 land in exactly the same
# place, and `orch report` cannot tell them apart afterwards except by the
# reason recorded with the event. That is deliberate: the ablation asks whether
# a configuration paid off, not whose idea it was.
#
# Above strict the ladder continues into configurations no developer should
# have to request — best-of-N, diagnosis, and finally a human — because those
# are responses to a run going wrong, not to a job being big.
#
#     quick ──▶ standard ──▶ strict ──▶ best-of-N ──▶ diagnose ──▶ human
#     └──── the developer picks ────┘   └──── signals force ────┘
#
# The crew is sized by rung and nothing else. director and auditor are not in
# it: they live for the whole run, not for one feature.

[ -n "${ORCH_TIER_SOURCED:-}" ] && return 0
ORCH_TIER_SOURCED=1

# shellcheck source=escalate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/escalate.sh"

ORCH_TIERS="quick standard strict"

# The review ensemble. The union result behind it [P8] holds only while the
# lenses are independent, and a different model is the cheapest independence
# available: the ensemble is meant to be (model × lens) diverse, and until now
# every lens ran the same model. One lens runs opus; the rest run the role's
# frontmatter model. Empty ORCH_OPUS_LENS puts every lens on the same model,
# and `orch findings yield` is how you find out whether the opus lens earns its
# price — a lens with ~0% unique finds over ten features is deleted, whatever
# it runs on.
: "${ORCH_REVIEW_LENSES:=correctness failure-modes reproduction}"
# Unset means the default; empty means "no opus lens". `:=` cannot tell those
# apart, so the default is applied only when the variable does not exist.
[ -n "${ORCH_OPUS_LENS+x}" ] || ORCH_OPUS_LENS=correctness

tier_lenses() { printf '%s' "$ORCH_REVIEW_LENSES"; }

# tier_lens_model <lens> -> the model override for that lens, or empty for the
# role's own.
tier_lens_model() {
  [ -n "$ORCH_OPUS_LENS" ] && [ "$1" = "$ORCH_OPUS_LENS" ] && printf 'opus'
  return 0
}

# tier_rung <name> -> the rung a tier corresponds to, or empty if not a tier.
tier_rung() {
  case "$1" in
    quick)    printf '0' ;;
    standard) printf '1' ;;
    strict)   printf '2' ;;
    *)        printf '' ;;
  esac
}

tier_valid() { [ -n "$(tier_rung "$1")" ]; }

# The crew a rung spawns, in spawn order. Empty at rung 5: handing the feature
# to a human means stopping, not adding another agent to the pile.
tier_crew() {  # tier_crew <rung>
  case "$1" in
    0) printf 'tech-lead developer' ;;
    1) printf 'tech-lead developer code-reviewer' ;;
    2|3|4) printf 'tech-lead test-engineer developer code-reviewer' ;;
    5) printf '' ;;
    *) printf 'tech-lead developer' ;;
  esac
}

# The reasoning effort a rung's crew runs at. Empty means the role's own
# default — each agents/<role>.md declares `effort:` in its frontmatter next to
# `model:`, so the two are read together, and `test/agent-lint.sh` requires it.
# What this function returns is the tier's OVERRIDE, passed as --effort, and it
# only ever lowers.
#
# Only quick is lowered. The v1 session spent 2.45M tokens having an opus
# prover write tests, and the post-mortem's conclusion was not "think less
# everywhere" — it was that trivial work bought the same machinery as hard
# work. A quick-tier feature is by definition one the developer judged
# mechanical, so it gets low effort; everything above runs at whatever the
# role's model defaults to.
tier_effort() {  # tier_effort <rung>
  case "$1" in
    0) printf 'low' ;;
    *) printf '' ;;
  esac
}

# Why each rung adds what it adds. Printed when a tier is confirmed, so the
# developer sees the cost of the choice at the moment of making it.
tier_rationale() {  # tier_rationale <rung>
  case "$1" in
    0) printf 'the developer writes its own tests, if any. No independent review.' ;;
    1) printf 'a code-reviewer sees the diff with fresh context and no access to the developer trace.' ;;
    2) printf 'a test-engineer writes the tests from requirements alone, before any implementation exists.' ;;
    3) printf 'N developers work the same requirements in isolated worktrees; selection is mechanical.' ;;
    4) printf 'K read-only agents each hold a different hypothesis; execution picks between them.' ;;
    5) printf 'no falsifiable experiment remains. This one is yours.' ;;
    *) printf '' ;;
  esac
}

_tier_last() {  # _tier_last <feature> <event> <field>
  ledger_read "$1" | jq -s -r --arg e "$2" --arg f "$3" \
    '[.[] | select(type=="object" and .event==$e)] | if length==0 then "" else (.[-1][$f] // "") end' \
    2>/dev/null
}

# The tier a feature is actually running at. Derived from the rung, so an
# escalation past strict reports the rung name rather than pretending the
# developer's choice still describes the run.
tier_current() {  # tier_current <feature>
  escalate_rung_name "$(escalate_rung "$1")"
}

tier_recommended()     { _tier_last "$1" tier.recommended tier; }
tier_recommended_why() { _tier_last "$1" tier.recommended why; }
tier_confirmed()       { _tier_last "$1" tier.confirmed tier; }

# tier_recommend <feature> <tier> <why>
#
# The tech-lead's proposal. It is not a decision: nothing about the crew changes
# until a human confirms. Requiring the justification in the same call is the
# point — a tier proposed without a stated reason is a guess with a flag on it.
tier_recommend() {
  local feature="$1" tier="$2" why="$3"
  orch_valid_feature "$feature" || die "tier recommend: invalid feature '$feature'"
  tier_valid "$tier" || die "tier recommend: '$tier' is not a tier (expected: $ORCH_TIERS)"
  [ -n "$why" ] || die "tier recommend: --why is required — a tier with no stated reason is a guess"
  ORCH_LEDGER_FEATURE="$feature" ledger_append tier.recommended \
    tier "$tier" rung:raw "$(tier_rung "$tier")" why "$why"
  printf '%s recommends tier `%s` for %s: %s\n' "$(orch_actor)" "$tier" "$feature" "$why"
  printf '\nNothing is spawned until a human confirms:\n  orch tier confirm %s\n' "$feature"
}

# tier_confirm <feature> [tier]
#
# The human's decision, and the only thing that sizes a crew. With no tier
# given it takes the recommendation; refusing to guess when there is neither is
# deliberate, because silently defaulting is how every feature ends up at
# whichever tier the author of this file happened to prefer.
tier_confirm() {
  local feature="$1" tier="${2:-}" rec rung cur
  orch_valid_feature "$feature" || die "tier confirm: invalid feature '$feature'"
  rec="$(tier_recommended "$feature")"

  if [ -z "$tier" ]; then
    tier="$rec"
    [ -n "$tier" ] || die "tier confirm: no recommendation on record for $feature, so there is nothing to confirm.
Pass one explicitly:  orch tier confirm $feature --tier <$(printf '%s' "$ORCH_TIERS" | tr ' ' '|')>"
  fi
  tier_valid "$tier" || die "tier confirm: '$tier' is not a tier (expected: $ORCH_TIERS)"

  rung="$(tier_rung "$tier")"
  cur="$(escalate_rung "$feature")"

  # A tier is a floor, never a ceiling. Escalation is one-way by design, so
  # confirming `quick` on a feature the signals already pushed to strict does
  # not walk it back down — it records the choice and leaves the rung alone.
  if [ "$rung" -lt "$cur" ]; then
    warn "$feature is already at rung $cur ($(escalate_rung_name "$cur")); tier $tier does not lower it"
  fi

  ORCH_LEDGER_FEATURE="$feature" ledger_append tier.confirmed \
    tier "$tier" rung:raw "$rung" recommended "$rec" by "$(orch_actor)"

  # The crew is sized here, so this is the last moment the statement can
  # change without anyone having built against it. Freeze whatever exists —
  # requirements.md and contract.md if the tech-lead has written them,
  # request.md regardless.
  . "$ORCH_HOME/lib/statement.sh"
  statement_freeze "$feature" "tier confirmed" >/dev/null 2>&1 || true

  if [ "$rung" -gt "$cur" ]; then
    escalate_to "$feature" "$rung" "tier=$tier confirmed by a human"
  fi

  rung="$(escalate_rung "$feature")"
  printf '%s runs at tier `%s` (rung %s).\n' "$feature" "$(escalate_rung_name "$rung")" "$rung"
  printf '  %s\n' "$(tier_rationale "$rung")"
  printf '\ncrew: %s\n' "$(tier_crew "$rung" | sed 's/ /, /g')"
  printf 'director and auditor are not in it — they live for the whole run.\n'
}

# Whether a crew may be spawned yet. The gate the spawner checks.
tier_is_confirmed() {  # tier_is_confirmed <feature>
  [ -n "$(tier_confirmed "$1")" ]
}

tier_show() {  # tier_show <feature>
  local feature="$1" rung rec why conf
  rung="$(escalate_rung "$feature")"
  rec="$(tier_recommended "$feature")"
  why="$(tier_recommended_why "$feature")"
  conf="$(tier_confirmed "$feature")"
  jq -n -c \
    --arg feature "$feature" \
    --argjson rung "${rung:-0}" \
    --arg running "$(escalate_rung_name "$rung")" \
    --arg recommended "$rec" \
    --arg why "$why" \
    --arg confirmed "$conf" \
    --argjson is_confirmed "$([ -n "$conf" ] && printf true || printf false)" \
    --arg crew "$(tier_crew "$rung")" \
    '$ARGS.named'
}
