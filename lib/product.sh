#!/bin/bash
# product.sh - the product layer: personas, stories, the chain from a persona
# to a landed feature, the night, and the morning.
#
# The persona chain is the verification chain one level up: a small frozen
# statement at the top, everything below measured against it. Two risks
# decide the design, and both are the FLT lesson again [P36].
#
#   Fiction at the top. A model writes plausible personas in seconds, and
#   every artifact below then optimises for people who may not exist. So a
#   persona carries an evidence status — hypothesized, observed, measured —
#   the way PROVENANCE.md marks research claims [P46][P47]; a feature built
#   for a hypothesized persona is exploratory, the morning says so, and
#   `keep` refuses it without the flag. Real behaviour is the persona's
#   oracle; logs and metrics are not a separate loop.
#
#   Drift. Personas and stories are frozen by hash like the statement. They
#   evolve, but through a re-freeze with a reason, so the ledger says why a
#   persona changed. The morning's discards are the input: what the human
#   rejects is written down against the persona, and the human folds it in.
#   Anthropic's Dreaming does the same for memory — proposals, reviewed,
#   never silent edits [P49].
#
# The chain: persona -> story -> feature -> requirement -> test. `orch spec
# coverage` holds the bottom link; this file holds the rest. Orphan work — a
# feature no story asked for — is what "linking is attestation" refuses
# [P37]; `orch product trace` names it.
#
#   docs/product/personas/<slug>.md         # Maya, the weekly exporter
#                                           evidence: observed
#                                           sources: support tickets 2026-Q2
#   docs/product/stories/S001-<slug>.md     # S001 Export the week as CSV
#                                           persona: maya
#                                           tier: standard      (optional)
#                                           after: S000         (optional)
#                                           metric: ...         (a hypothesis)
#
#   orch product freeze|check|trace|personas
#   orch product plan [--story S]           one feature per story, requests from the story
#   orch product night [--budget N]         plan, then crew every ready feature
#   orch product morning                    each feature, the walkthrough first
#   orch product keep|iterate|discard <F>   the three morning verbs
#
# Nothing here calls a model except the walkthrough (lib/walkthrough.sh) and
# the crews `night` starts, which are the ordinary crews with their gates.

[ -n "${ORCH_PRODUCT_SOURCED:-}" ] && return 0
ORCH_PRODUCT_SOURCED=1

# shellcheck source=walkthrough.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/walkthrough.sh"
# shellcheck source=metrics.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/metrics.sh"
# shellcheck source=waves.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/waves.sh"
# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"
# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"

: "${ORCH_PRODUCT_TIER:=standard}"
: "${ORCH_PRODUCT_BUDGET:=4}"

# Exit code:  9  PRODUCT_MOVED  a frozen persona or story changed

product_personas() { ls "$(product_dir)/personas" 2>/dev/null | grep '\.md$' | sed 's/\.md$//'; }
product_stories()  { ls "$(product_dir)/stories" 2>/dev/null | grep -E '^S[0-9]{3}.*\.md$' | sed 's/\.md$//' | sort; }
product_files() {  # every persona and story, and the metric definitions, relative to docs/product
  local x
  for x in $(product_personas); do printf 'personas/%s.md\n' "$x"; done
  for x in $(product_stories); do printf 'stories/%s.md\n' "$x"; done
  [ ! -r "$(product_dir)/metrics.md" ] || printf 'metrics.md\n'
}
_product_hash() { orch_sha256 < "$(product_dir)/$1"; }

# ---------------------------------------------------------------------------
# Frozen
# ---------------------------------------------------------------------------

product_freeze() {  # product_freeze [why]
  local why="${1:-}" f n=0 hashes='{}'
  for f in $(product_files); do
    hashes="$(printf '%s' "$hashes" | jq -c --arg f "$f" --arg h "$(_product_hash "$f")" '.[$f]=$h')"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || die "product freeze: nothing under $(product_dir) — write a persona and a story first"
  ORCH_LEDGER_FEATURE=_orch ledger_append product.frozen files:raw "$hashes" why "$why"
  printf 'product frozen: %s persona/story file(s)\n' "$n"
}

product_frozen() {
  ledger_read _orch | jq -c -s '[.[] | select(type=="object" and .event=="product.frozen")] | if length==0 then empty else .[-1] | {ts, files} end' 2>/dev/null
}

# Files that exist now and were not in the last freeze.
_product_unfrozen() {
  local frozen f
  frozen="$(product_frozen)"
  for f in $(product_files); do
    [ -n "$frozen" ] && printf '%s' "$frozen" | jq -e --arg f "$f" '.files[$f] != null' >/dev/null 2>&1 || printf '%s\n' "$f"
  done
}

# product_check -> 0, or 9 with the moved files. Never frozen passes.
product_check() {
  local frozen f moved=''
  frozen="$(product_frozen)"; [ -n "$frozen" ] || return 0
  for f in $(printf '%s' "$frozen" | jq -r '.files | keys[]'); do
    [ -r "$(product_dir)/$f" ] || { moved="$moved $f(removed)"; continue; }
    [ "$(_product_hash "$f")" = "$(printf '%s' "$frozen" | jq -r --arg f "$f" '.files[$f]')" ] || moved="$moved $f"
  done
  [ -n "$moved" ] || return 0
  ORCH_LEDGER_FEATURE=_orch ledger_append product.moved files "${moved# }"
  cat >&2 <<EOM
PRODUCT_MOVED:${moved} changed since the personas and stories were frozen at $(printf '%s' "$frozen" | jq -r .ts).

A persona or story is what every feature below it was asked for. If the change
is right — a persona observed, a story sharpened by a discard — say so:

  orch product freeze --why "<what changed and why>"
EOM
  return 9
}

# ---------------------------------------------------------------------------
# The chain
# ---------------------------------------------------------------------------

_product_features() {  # features with a story: planned by product, or citing one by hand
  local f
  for f in $(orch_features_list); do
    case "$f" in *-upkeep-*) continue ;; esac
    [ -n "$(product_feature_story "$f")" ] && printf '%s\n' "$f"
  done
}
_product_orphans() {  # features that no story asked for
  local f
  for f in $(orch_features_list); do
    case "$f" in *-upkeep-*) continue ;; esac
    [ -z "$(product_feature_story "$f")" ] && printf '%s\n' "$f"
  done
}
_product_last() {  # _product_last <feature> <event> -> row or ''
  ledger_read "$1" | jq -c -s --arg e "$2" '[.[] | select(type=="object" and .event==$e)] | if length==0 then empty else .[-1] end' 2>/dev/null
}
product_feature_closed() {  # kept or discarded in a morning
  [ -n "$(_product_last "$1" product.kept)" ] || [ -n "$(_product_last "$1" product.discarded)" ]
}

# The open feature for a story: built for it and not discarded. Landed
# counts — the story is built.
product_feature_for() {  # product_feature_for <S001> -> feature or ''
  local f
  for f in $(_product_features); do
    [ "$(product_feature_story "$f")" = "${1%%-*}" ] || continue
    [ -n "$(_product_last "$f" product.discarded)" ] && continue
    printf '%s' "$f"; return 0
  done
  return 1
}

# A feature's state, for the morning: kept, discarded, landed, parked (rung 5),
# or the wave state (blocked, ready, running).
product_feature_state() {  # product_feature_state <feature>
  if [ -n "$(_product_last "$1" product.discarded)" ]; then printf 'discarded'
  elif [ -n "$(_product_last "$1" product.kept)" ] || merge_landed "$1"; then printf 'landed'
  elif [ "$(escalate_rung "$1")" -ge 5 ]; then printf 'parked'
  else waves_state "$1"; fi
}

# product_trace — the whole chain, and exit 1 on a broken link.
product_trace() {
  local rc=0 p s f ev sf st per stories msg
  [ -n "$(product_files)" ] || die "product trace: nothing under $(product_dir). Layout:
  docs/product/personas/<slug>.md   (# Name; evidence: hypothesized|observed|measured)
  docs/product/stories/S001-<slug>.md   (# S001 Title; persona: <slug>)"
  if msg="$(product_check 2>&1)"; then
    [ -n "$(product_frozen)" ] && printf 'frozen: as of %s\n' "$(product_frozen | jq -r .ts)" || printf 'frozen: never (orch product freeze)\n'
  else printf '%s\n' "$msg" | head -1; rc=1; fi
  [ -z "$(_product_unfrozen)" ] || printf 'not yet frozen: %s\n' "$(_product_unfrozen | tr '\n' ' ')"

  printf '\n%-22s %-13s %s\n' persona evidence stories
  for p in $(product_personas); do
    ev="$(product_persona_evidence "$p")"
    stories=''
    for s in $(product_stories); do [ "$(product_field "$(product_dir)/stories/$s.md" persona)" = "$p" ] && stories="$stories ${s%%-*}"; done
    printf '%-22s %-13s %s%s\n' "$p" "$ev" "${stories# }" "$([ "$ev" = none ] && printf '   NO EVIDENCE LINE — everything built for it is exploratory')"
  done

  printf '\n%-8s %-14s %-26s %s\n' story persona feature state
  for s in $(product_stories); do
    sf="$(product_dir)/stories/$s.md"; per="$(product_field "$sf" persona)"
    if [ -z "$per" ]; then printf '%-8s %-14s BROKEN — names no persona\n' "${s%%-*}" '-'; rc=1; continue; fi
    if [ ! -r "$(product_persona_file "$per")" ]; then printf '%-8s %-14s BROKEN — no such persona\n' "${s%%-*}" "$per"; rc=1; continue; fi
    if f="$(product_feature_for "$s")"; then st="$(product_feature_state "$f")"; else f='-'; st='unplanned'; fi
    printf '%-8s %-14s %-26s %s\n' "${s%%-*}" "$per" "$f" "$st"
  done

  if [ -n "$(_product_orphans)" ]; then
    printf '\nfeatures no story asked for:\n'
    for f in $(_product_orphans); do printf '  %s   (add "Story: S00N" to its request.md, or write the story)\n' "$f"; done
    rc=1
  fi
  return "$rc"
}

# product_personas_render — each persona, its stories, and what the mornings
# have said about it. The learned lines are proposals: the file is the
# human's, and nothing here edits it.
product_personas_render() {
  local p s learned
  for p in $(product_personas); do
    printf '%s — %s   [%s]\n' "$p" "$(product_title "$(product_persona_file "$p")")" "$(product_persona_evidence "$p")"
    for s in $(product_stories); do
      [ "$(product_field "$(product_dir)/stories/$s.md" persona)" = "$p" ] || continue
      printf '  %s  %s\n' "${s%%-*}" "$(product_title "$(product_dir)/stories/$s.md")"
    done
    learned="$(ledger_read _orch | jq -r -s --arg p "$p" '.[] | select(type=="object" and .event=="product.learned" and .persona==$p) | "  learned (\(.ts[0:10]), \(.story) discarded): \(.why)"' 2>/dev/null)"
    [ -z "$learned" ] || printf '%s\n' "$learned"
    printf '\n'
  done
}

# ---------------------------------------------------------------------------
# Plan, night
# ---------------------------------------------------------------------------

_product_next_id() {  # the lowest free F0NN..F8NN; upkeep owns F9NN
  local n=1 id
  while :; do
    id="$(printf 'F%03d' "$n")"
    orch_features_list | grep -q "^$id-" || break
    n=$((n + 1)); [ "$n" -lt 900 ] || die "product plan: no free feature id below F900"
  done
  printf '%s' "$id"
}

# product_plan [--story S] — one feature per story without one. The request
# is the story itself plus the citation line, frozen like any request; the
# tier is the story's or the default; `after:` becomes --after on the
# features the stories it names already have.
product_plan() {
  local only='' s sid sf per ev expl tier after dep a slug id req msg hyp
  while [ "$#" -gt 0 ]; do case "$1" in --story) only="${2%%-*}"; shift 2 ;; *) shift ;; esac; done
  [ -n "$(product_stories)" ] || die "product plan: no stories under $(product_dir)/stories"
  msg="$(product_check 2>&1)" || die "product plan: $msg"
  [ -z "$(_product_unfrozen)" ] || product_freeze "plan" >/dev/null
  for s in $(product_stories); do
    sid="${s%%-*}"
    [ -z "$only" ] || [ "$only" = "$sid" ] || continue
    if id="$(product_feature_for "$sid")"; then printf '%s  %s  (exists)\n' "$id" "$sid"; continue; fi
    sf="$(product_dir)/stories/$s.md"
    per="$(product_field "$sf" persona)"
    [ -n "$per" ] && [ -r "$(product_persona_file "$per")" ] || { warn "product plan: $sid names no persona that exists; skipped"; continue; }
    ev="$(product_persona_evidence "$per")"
    expl=false; case "$ev" in hypothesized|none) expl=true ;; esac
    # A holdout metric is the human's number; a story that targets it would
    # hand the crew the one thing the holdout exists to keep from them.
    hyp="$(metrics_hypothesis "$sid")"
    if [ -n "$hyp" ] && metrics_holdout_names | grep -qx "${hyp%% *}"; then
      warn "product plan: $sid targets ${hyp%% *}, a holdout metric; skipped — pick a metric the crew may see"; continue
    fi
    tier="$(product_field "$sf" tier)"; tier="${tier:-$ORCH_PRODUCT_TIER}"
    after=''
    for a in $(product_field "$sf" after | tr ',' ' '); do
      if dep="$(product_feature_for "$a")"; then after="$after,$dep"
      else warn "product plan: $sid is after $a, which has no feature yet; planned without that edge"; fi
    done
    slug="${s#S[0-9][0-9][0-9]-}"; [ "$slug" != "$s" ] || slug="$(product_title "$sf" | sed -E 's/^S[0-9]+ *//')"
    slug="$(printf '%s' "$slug" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)"
    id="$(_product_next_id)-${slug:-story}"
    req="$(cat "$sf")

Story: $sid (persona: $per, evidence: $ev)"
    # shellcheck disable=SC2086
    "$ORCH_ROOT_BIN" feature start "$id" --request "$req" --tier "$tier" ${after:+--after "${after#,}"} >/dev/null 2>&1 \
      || { warn "product plan: could not start $id for $sid"; continue; }
    ORCH_LEDGER_FEATURE="$id" ledger_append product.planned story "$sid" persona "$per" evidence "$ev" \
      exploratory:raw "$expl" tier "$tier" story_sha "$(_product_hash "stories/$s.md")"
    printf '%s  %s  as %s (%s)%s\n' "$id" "$sid" "$per" "$ev" "$($expl && printf '  EXPLORATORY')"
  done
}

# product_night [--budget N] [--story S] — plan, then crew every ready
# feature up to the budget. A parked feature (rung 5) waits for the morning
# rather than blocking the night; a blocked one waits for its wave.
product_night() {
  local budget="$ORCH_PRODUCT_BUDGET" f n=0 st args=''
  while [ "$#" -gt 0 ]; do case "$1" in --budget) budget="$2"; shift 2 ;; --story) args="--story $2"; shift 2 ;; *) shift ;; esac; done
  # shellcheck disable=SC2086
  product_plan $args | sed 's/^/  /'
  for f in $(_product_features); do
    product_feature_closed "$f" && continue
    [ "$n" -lt "$budget" ] || { printf '  budget of %s reached; the rest wait for the next night\n' "$budget"; break; }
    st="$(product_feature_state "$f")"
    case "$st" in
      ready) ;;
      parked) printf '  %s is parked at rung 5 — it is yours in the morning\n' "$f"; continue ;;
      *) continue ;;
    esac
    ORCH_FEATURE="$f" "$ORCH_ROOT_BIN" team start --feature "$f" 2>&1 | sed 's/^/  /'
    ORCH_LEDGER_FEATURE="$f" ledger_append product.night budget:raw "$budget"
    n=$((n + 1))
  done
  printf '\nproduct night: %s crew(s) started. In the morning:  orch product morning\n' "$n"
}

# ---------------------------------------------------------------------------
# The morning
# ---------------------------------------------------------------------------

# Each feature in two minutes: what the persona could do, the numbers, the
# cost, the verbs. Never the diff — that is what the packet is for, and the
# morning is selection, not review.
product_morning() {
  local f row st head base ev tests nf diff usage v
  printf 'product morning\n\n'
  [ -n "$(_product_features)" ] || { printf '  no story-backed features. Write stories, then:  orch product night\n'; return 0; }
  for f in $(_product_features); do
    row="$(_product_last "$f" product.planned)"
    st="$(product_feature_state "$f")"
    printf '%s  %s  as %s (%s)   %s%s\n' "$f" "$(product_feature_story "$f")" \
      "$(printf '%s' "$row" | jq -r '.persona // "-"')" "$(printf '%s' "$row" | jq -r '.evidence // "?"')" "$st" \
      "$(printf '%s' "$row" | jq -r 'if .exploratory then "   EXPLORATORY" else "" end')"
    case "$st" in
      landed) v="$(metrics_verdict "$f")"; [ "$v" = none ] || printf '  metric: %s\n' "$v"; printf '\n'; continue ;;
      discarded) printf '\n'; continue ;;
    esac
    printf '  walkthrough: %s\n' "$(walkthrough_render "$f")"
    head="$(git -C "$(orch_feature_repo "$f")" rev-parse HEAD 2>/dev/null)"
    base="$(git -C "$(orch_feature_repo "$f")" merge-base "$(escalate_base_branch)" "$head" 2>/dev/null)"
    tests="$(ORCH_REPO="$(orch_feature_repo "$f")" evidence_latest "$f" tests 2>/dev/null)"
    if [ -n "$tests" ]; then
      ev="exit $(printf '%s' "$tests" | jq -r .exit_code)$([ "$(printf '%s' "$tests" | jq -r .git_sha)" = "$head" ] || printf ' (not at HEAD)')"
    else ev='none'; fi
    nf="$(findings_current "$f" 2>/dev/null | jq -s '[.[] | select(.status=="open")] | length')"
    diff="$(git -C "$(orch_feature_repo "$f")" diff --shortstat "${base:-$head}" "$head" -- . ':(exclude)docs/features' 2>/dev/null | sed 's/^ *//')"
    usage="$(ledger_feature_usage "$f" | jq -r 'if .found > 0 then "\((.input + .output) / 1000 | floor)k tokens" else "cost unknown (no transcript)" end')"
    printf '  tests: %s   open findings: %s   diff: %s   %s\n' "$ev" "${nf:-0}" "${diff:-none}" "$usage"
    case "$st" in
      parked)  printf '  parked at rung 5: read docs/features/%s/ledger.jsonl — no experiment is left to run\n' "$f" ;;
      blocked) printf '  waiting for %s\n' "$(waves_blockers "$f" | tr ' ' ',')" ;;
    esac
    printf '  orch product keep %s   |   orch product iterate %s --note "..."   |   orch product discard %s --why "..."\n\n' "$f" "$f" "$f"
  done
}

# product_keep <F> [--exploratory] — the human's approval and the landing
# in one verb. Exploratory work needs the flag: its persona was never
# observed, and keeping it is a bet the human should know they are making.
product_keep() {
  local f="$1" ok=0 row head; shift
  while [ "$#" -gt 0 ]; do case "$1" in --exploratory) ok=1 ;; esac; shift; done
  row="$(_product_last "$f" product.planned)"
  [ -n "$row" ] || [ -n "$(product_feature_story "$f")" ] || die "product keep: $f was not built for a story; land it with orch approve + orch merge"
  if [ "$(printf '%s' "$row" | jq -r '.exploratory // false')" = true ] && [ "$ok" != 1 ]; then
    die "product keep: $f is exploratory — its persona ($(printf '%s' "$row" | jq -r .persona)) is $(printf '%s' "$row" | jq -r .evidence), not observed.
Keep it anyway with --exploratory, or observe the persona first and re-freeze."
  fi
  head="$(git -C "$(orch_feature_repo "$f")" rev-parse HEAD 2>/dev/null)" || die "product keep: no tree for $f"
  # The approval is the human's verb; the landing is the queue's. kept is
  # recorded only once the queue accepted it — a refused merge is not a keep.
  substrate_set_gate "$f" human met "$head" >/dev/null
  ORCH_PACKET_SEEN=1 merge_land "$f" || return 1
  ORCH_LEDGER_FEATURE="$f" ledger_append product.kept exploratory:raw "$([ "$ok" = 1 ] && printf true || printf false)"
  merge_close "$f"
  printf 'kept %s\n' "$f"
}

# product_iterate <F> --note T — amend the request and re-freeze. The red
# phase is void by construction; the crew re-reads the request.
product_iterate() {
  local f="$1" note=''; shift
  # A plain scan, not `$(while ...)`: bash 3.2 does not see the function's
  # positional parameters inside a command substitution, and the note came
  # back empty-but-present on macOS.
  while [ "$#" -gt 0 ]; do case "$1" in --note) note="${2-}"; [ "$#" -gt 1 ] && shift ;; esac; shift; done
  [ -n "$note" ] || die "product iterate: --note is required — what should be different tomorrow?"
  [ -r "$(orch_feature_dir "$f")/request.md" ] || die "product iterate: $f has no request.md"
  printf '\n## Morning note (%s)\n\n%s\n' "$(now_iso | cut -c1-10)" "$note" >> "$(orch_feature_dir "$f")/request.md"
  . "$ORCH_HOME/lib/statement.sh"
  statement_freeze "$f" "morning iterate" >/dev/null
  ORCH_LEDGER_FEATURE="$f" ledger_append product.iterated note "$note"
  printf 'iterated %s: the note is in request.md and the statement is re-frozen. The red phase is void; the crew re-reads the request.\n  orch team recycle developer     (from %s)\n' "$f" "$(orch_feature_repo "$f")"
}

# product_discard <F> --why W — archive it, and write the reason against the
# persona. The reason is required because it is the only part of a discard
# with any information in it.
product_discard() {
  local f="$1" why='' row; shift
  while [ "$#" -gt 0 ]; do case "$1" in --why) why="${2-}"; [ "$#" -gt 1 ] && shift ;; esac; shift; done
  [ -n "$why" ] || die "product discard: --why is required — a discard with no reason teaches the persona nothing"
  row="$(_product_last "$f" product.planned)"
  ORCH_LEDGER_FEATURE="$f" ledger_append product.discarded why "$why"
  ORCH_LEDGER_FEATURE=_orch ledger_append product.learned persona "$(printf '%s' "$row" | jq -r '.persona // ""')" \
    story "$(product_feature_story "$f")" discarded "$f" why "$why"
  merge_close "$f" >/dev/null
  printf 'discarded %s — noted against persona %s. The persona file is yours to amend; then  orch product freeze --why "..."\n' \
    "$f" "$(printf '%s' "$row" | jq -r '.persona // "?"')"
}
