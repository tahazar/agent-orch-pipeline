#!/bin/bash
# walkthrough.sh - the persona walkthrough: the read-back at product level.
#
# The read-back (lib/readback.sh) has a blind session say what the tests
# literally assert, so the human can compare that to the requirements. The
# walkthrough does the same one level up: a fresh session is given one
# persona and one story, a running product, and nothing else — no source, no
# tests, no requirements, no developer trace — and it tries to reach the
# story's goal as that person would. What it finds it files in that person's
# voice ("as Maya I could not find export; it took nine steps"), and the
# mechanical part — done or blocked, steps, minutes — is a ledger row bound
# to the sha it was tried at. UXAgent [P45] is the published version of this
# idea; the fidelity literature [P46] is why it complements the human's
# morning rather than replacing it.
#
# No seventh role: a `code-reviewer` with the `walkthrough` lens. The lens
# is denied source, tests and every feature artifact by hooks/artifact-scope.sh,
# emits findings only, and records through `orch walkthrough record`. While
# the product layer is on, a story-backed feature cannot land without a
# walkthrough that finished at its HEAD — the merge checks the gate, not the
# prose.
#
#   orch walkthrough start <F>          spawn it (needs the product running: ORCH_PRODUCT_CMD)
#   orch walkthrough record <F> --outcome done|blocked --steps N [--minutes M] [--note T]
#   orch walkthrough status <F>         the latest record and whether it is at HEAD

[ -n "${ORCH_WALKTHROUGH_SOURCED:-}" ] && return 0
ORCH_WALKTHROUGH_SOURCED=1

# shellcheck source=layers.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layers.sh"
# shellcheck source=ledger.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ledger.sh"
# shellcheck source=substrate/base.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/substrate/base.sh"

ORCH_EVIDENCE_LEVELS="hypothesized observed measured"

product_dir() { printf '%s/docs/product' "$(orch_main_repo)"; }

# A story file by id (S001) or by name (S001-slug); empty when none.
product_story_file() {  # product_story_file <S001[-slug]>
  local id="${1%%-*}" s
  s="$(ls "$(product_dir)/stories" 2>/dev/null | grep -E "^${id}(-.*)?\.md$" | head -1)"
  [ -n "$s" ] && printf '%s/stories/%s' "$(product_dir)" "$s"
  return 0
}
product_persona_file() { printf '%s/personas/%s.md' "$(product_dir)" "$1"; }

# One header field of a persona or story: the first line "key: value".
product_field() {  # product_field <file> <key>
  grep -m1 -iE "^${2}:[[:space:]]*" "$1" 2>/dev/null | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}
product_title() { grep -m1 '^# ' "$1" 2>/dev/null | sed 's/^# *//'; }

# The persona's evidence status, or "none". A persona nobody has observed is
# a hypothesis, and everything built for it is exploratory.
product_persona_evidence() {  # product_persona_evidence <slug>
  local e; e="$(product_field "$(product_persona_file "$1")" evidence | tr 'A-Z' 'a-z' | awk '{print $1}')"
  case " $ORCH_EVIDENCE_LEVELS " in *" $e "*) printf '%s' "$e" ;; *) printf 'none' ;; esac
}

# The story a feature was built for: the product.planned row, or a
# "Story: S001" line in request.md for a feature a human started by hand.
product_feature_story() {  # product_feature_story <feature> -> S001 or ''
  local s
  s="$(ledger_read "$1" | jq -r -s '[.[] | select(type=="object" and .event=="product.planned")] | if length==0 then "" else last.story end' 2>/dev/null)"
  [ -n "$s" ] || s="$(grep -m1 -oE '^Story:[[:space:]]*S[0-9]{3}' "$(orch_feature_dir "$1")/request.md" 2>/dev/null | grep -oE 'S[0-9]{3}')"
  printf '%s' "$s"
}
product_feature_persona() {  # product_feature_persona <feature> -> slug or ''
  local s f; s="$(product_feature_story "$1")"; [ -n "$s" ] || return 0
  f="$(product_story_file "$s")"; [ -n "$f" ] && product_field "$f" persona
  return 0
}

# Does landing this feature need a walkthrough? Only while the layer is on,
# and only for a feature a story asked for; upkeep and hand-started work
# without a story are not the persona's business.
walkthrough_required() {  # walkthrough_required <feature>
  layer_enabled product && [ -n "$(product_feature_story "$1")" ]
}

walkthrough_latest() {  # walkthrough_latest <feature> -> the last record row, or nothing
  ledger_read "$1" | jq -c -s '[.[] | select(type=="object" and .event=="walkthrough.recorded")] | if length==0 then empty else .[-1] end' 2>/dev/null
}

# walkthrough_status <feature> -> "none" | "stale" | "done N" | "blocked N"
walkthrough_status() {
  local row head
  row="$(walkthrough_latest "$1")"; [ -n "$row" ] || { printf 'none'; return 0; }
  head="$(git -C "$(orch_feature_repo "$1")" rev-parse HEAD 2>/dev/null)"
  [ "$(printf '%s' "$row" | jq -r .at_sha)" = "$head" ] || { printf 'stale'; return 0; }
  printf '%s %s' "$(printf '%s' "$row" | jq -r .outcome)" "$(printf '%s' "$row" | jq -r .steps)"
}

walkthrough_gate_met() {  # at the feature's HEAD
  local g head
  head="$(git -C "$(orch_feature_repo "$1")" rev-parse HEAD 2>/dev/null)"
  g="$(substrate_read_gate "$1" walkthrough 2>/dev/null)"
  [ "$(printf '%s' "$g" | jq -r '.state // "absent"')" = met ] && [ "$(printf '%s' "$g" | jq -r '.sha // ""')" = "$head" ]
}

# The session's opening message: the persona, the story, how to start the
# product, how to record. The persona and story files are quoted whole — the
# session is denied everything else, so this is all it knows.
walkthrough_orders() {  # walkthrough_orders <feature>
  local f="$1" s p sf pf run
  s="$(product_feature_story "$f")"; [ -n "$s" ] || die "walkthrough: $f was not built for a story — nothing to walk through"
  sf="$(product_story_file "$s")"; [ -r "$sf" ] || die "walkthrough: story $s has no file under docs/product/stories"
  p="$(product_field "$sf" persona)"; pf="$(product_persona_file "$p")"
  [ -r "$pf" ] || die "walkthrough: story $s names persona '$p', which has no file under docs/product/personas"
  run="${ORCH_PRODUCT_CMD:-}"
  [ -n "$run" ] || run="(not configured: set ORCH_PRODUCT_CMD; until then, docs/product/README.md says how, or ask)"
  cat <<EOM
You are ${p} — this person, for the length of this session:

$(cat "$pf")

Today you are trying to do this, and nothing else:

$(cat "$sf")

You have never seen this product's code and you will not: source files, tests and the feature's artifacts are denied to you, and reading them would make you a reviewer instead of a user. The product is what you use. Start it with:

  $run

Use it the way ${p} would, with the tools ${p} would have (a browser via Playwright, or the command line). Count your steps — every click, command, or page. When you reach the goal, or give up, record it (this is the gate; it is not optional):

  orch walkthrough record $f --outcome done|blocked --steps <N> --minutes <M> --note "<one line, in your own words>"

Everything that stopped you, confused you, or cost you a step you did not expect is a finding, in your own voice, one per thing:

  orch findings add $f --raised-by walkthrough --severity blocking|major|minor --file <the screen, page or command where it happened> --line 0 --claim "as ${p}, ..." --consequence "<what it costs someone like you>"

You change nothing. You do not guess what the developers meant; you report what happened to you.
EOM
}

# walkthrough_record <feature> <outcome> <steps> [minutes] [note]
walkthrough_record() {
  local f="$1" outcome="$2" steps="$3" minutes="${4:-}" note="${5:-}" s p sha
  case "$outcome" in done|blocked) ;; *) die "walkthrough record: --outcome must be done or blocked" ;; esac
  case "$steps" in ''|*[!0-9]*) die "walkthrough record: --steps must be a number — the count is the point" ;; esac
  s="$(product_feature_story "$f")"; p="$(product_feature_persona "$f")"
  sha="$(git -C "$(orch_feature_repo "$f")" rev-parse HEAD 2>/dev/null)"
  ORCH_LEDGER_FEATURE="$f" ledger_append walkthrough.recorded story "$s" persona "$p" outcome "$outcome" \
    steps:raw "$steps" minutes:raw "${minutes:-null}" note "$note" at_sha "$sha" lens "${ORCH_LENS:-}"
  if [ "$outcome" = done ]; then
    substrate_set_gate "$f" walkthrough met "$sha" >/dev/null
    printf 'walkthrough for %s: %s reached the goal in %s step(s) at %s — gate `walkthrough` met.\n' "$f" "${p:-the persona}" "$steps" "$(printf '%s' "$sha" | cut -c1-12)"
  else
    substrate_set_gate "$f" walkthrough open "$sha" >/dev/null 2>&1 || true
    printf 'walkthrough for %s: %s was BLOCKED after %s step(s) at %s. The merge waits; the findings say where.\n' "$f" "${p:-the persona}" "$steps" "$(printf '%s' "$sha" | cut -c1-12)"
  fi
}

walkthrough_render() {  # walkthrough_render <feature> — one line for the packet and the morning
  local f="$1" row st p
  p="$(product_feature_persona "$f")"
  case "$(walkthrough_status "$f")" in
    none)  printf 'none — %s has not tried it:  orch walkthrough start %s\n' "${p:-the persona}" "$f" ;;
    stale) printf 'STALE — recorded at an older HEAD; re-run:  orch walkthrough start %s\n' "$f" ;;
    *)
      row="$(walkthrough_latest "$f")"
      printf '%s %s in %s step(s)%s at HEAD%s\n' "${p:-the persona}" \
        "$(printf '%s' "$row" | jq -r 'if .outcome=="done" then "reached the goal" else "was BLOCKED" end')" \
        "$(printf '%s' "$row" | jq -r .steps)" \
        "$(printf '%s' "$row" | jq -r 'if .minutes then ", \(.minutes) min" else "" end')" \
        "$(printf '%s' "$row" | jq -r 'if (.note // "") != "" then " — \"\(.note)\"" else "" end')" ;;
  esac
}
