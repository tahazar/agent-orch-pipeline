#!/bin/bash
# findings.sh - review findings and critique uptake.
#
# Reviewer quality and critique uptake are separable, and uptake is the half
# that gets ignored. In [P11] the protocol whose reviewer had strictly better
# precision (0.861 vs 0.644) still produced worse outcomes, because its solver
# acted on verified-useful critique only 33.6% of the time against the other's
# 93.5%. Finding the defect and getting it fixed are different problems.
#
# Two things that paper is careful about, and so is this file:
#   - embedding the guidance in the solver's working context improves
#     follow-through PARTIALLY. It does not close the gap. Inline delivery is
#     the best lever available here, not a solved problem.
#   - forcing the solver to explicitly acknowledge critique LOWERED accuracy,
#     which is why nothing here makes an agent restate a finding back.
#
# Two consequences run through this file:
#   1. delivery inlines the finding text verbatim into the developer's next turn.
#      Relaying a filename through three hops is not delivery.
#   2. uptake is measured. Deliberately crudely - it measures engagement, not
#      correctness. Correctness is the re-review's job. Engagement is the thing
#      that was 33.6% and invisible.
#
# findings.jsonl is append-only. Status changes are new rows; the last row for
# an id wins. That keeps the audit trail intact instead of overwriting the
# record of what a reviewer originally said.

[ -n "${ORCH_FINDINGS_SOURCED:-}" ] && return 0
ORCH_FINDINGS_SOURCED=1

# shellcheck source=ledger.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ledger.sh"

findings_path() { printf '%s/findings.jsonl' "$(orch_feature_dir "$1")"; }

# Current state of every finding: last row per id.
findings_current() {  # findings_current <feature>
  local f; f="$(findings_path "$1")"
  [ -r "$f" ] || return 0
  jq -s -c '[.[] | select(type=="object")]
            | group_by(.id) | map(reduce .[] as $r ({}; . * $r)) | .[]' "$f" 2>/dev/null
}

findings_add() {  # findings_add <feature> <raised_by> <severity> <file> <line> <claim> <consequence>
  local feature="$1" by="$2" sev="$3" file="$4" line="$5" claim="$6" cons="$7"
  case "$sev" in blocking|major|minor|nit) ;; *) die "findings add: severity must be blocking|major|minor|nit" ;; esac
  local n id row
  n="$(findings_current "$feature" | jq -s 'length' 2>/dev/null || printf 0)"
  id="$(printf 'f%03d' $(( ${n:-0} + 1 )))"
  row="$(orch_json id "$id" raised_by "$by" raised_at "$(now_iso)" raised_at_sha "$(orch_head_sha)" \
    severity "$sev" file "$file" line "$line" claim "$claim" consequence "$cons" status open)"
  orch_append_jsonl "$(findings_path "$feature")" "$row"
  ORCH_LEDGER_FEATURE="$feature" ledger_append finding.raised id "$id" raised_by "$by" severity "$sev"
  [ "$sev" = "blocking" ] && ORCH_LEDGER_FEATURE="$feature" ledger_append review.blocking id "$id" raised_by "$by"
  printf '%s\n' "$id"
}

findings_set_status() {  # findings_set_status <feature> <id> <status> [reason]
  local feature="$1" id="$2" status="$3" reason="${4:-}"
  case "$status" in open|addressed|disputed|ignored) ;; *) die "findings: unknown status '$status'" ;; esac
  findings_current "$feature" | jq -e --arg i "$id" 'select(.id==$i)' >/dev/null 2>&1 \
    || die "findings: no such finding '$id' in $feature"
  orch_append_jsonl "$(findings_path "$feature")" \
    "$(orch_json id "$id" status "$status" status_at "$(now_iso)" status_sha "$(orch_head_sha)" \
       status_by "$(orch_actor)" status_reason "$reason")"
  ORCH_LEDGER_FEATURE="$feature" ledger_append finding.status id "$id" status "$status" reason "$reason"
}

# ---------------------------------------------------------------------------
# Delivery
# ---------------------------------------------------------------------------

# The text that goes into the developer's next turn, verbatim. Not a path to a
# file, not a summary, not "see findings.jsonl" - the whole point of [P11] is
# that the critique has to be in the working context to be acted on.
findings_render_open() {  # findings_render_open <feature>
  local feature="$1" body
  body="$(findings_current "$feature" | jq -s -r '
    [.[] | select(.status=="open")] | sort_by(.severity)
    | if length==0 then "" else
      (.[] | "── \(.id)  [\(.severity)]  \(.file):\(.line)   raised by \(.raised_by)\n" +
             "   claim:       \(.claim)\n" +
             "   consequence: \(.consequence)\n") end' 2>/dev/null)"
  [ -n "$body" ] || return 1
  cat <<EOF
OPEN REVIEW FINDINGS for $feature — address or dispute each one.

$body
For each: fix it, or run \`orch findings dispute <id> --reason "<why it is wrong>"\`.
Silence counts as ignored, and ignored findings are what \`orch report\` measures.
EOF
}

# ---------------------------------------------------------------------------
# Uptake
# ---------------------------------------------------------------------------

# Did the diff since raised_at_sha touch the region the finding points at?
#
# -U0 so a hunk header describes only the lines that actually changed; a
# generous context window would let an edit three functions away count as
# engagement, which would inflate exactly the number this exists to measure.
_finding_region_touched() {  # _finding_region_touched <sha> <file> <line>
  local sha="$1" file="$2" line="$3"
  case "$line" in ''|*[!0-9]*) line=0 ;; esac
  [ -n "$file" ] || return 1
  git -C "${ORCH_REPO:-.}" diff -U0 "$sha..HEAD" -- "$file" 2>/dev/null \
    | awk -v L="$line" '
        /^@@ / {
          # @@ -a,b +c,d @@   ; d defaults to 1 when absent
          split($3, p, ",")
          start = p[1]; sub(/^\+/, "", start)
          len = (p[2] == "" ? 1 : p[2])
          if (len == 0) { lo = start; hi = start } else { lo = start; hi = start + len - 1 }
          if (L == 0 || (L >= lo && L <= hi)) { found = 1 }
        }
        END { exit(found ? 0 : 1) }'
}

# findings_verify <feature> - classify every open finding as addressed or
# ignored. Explicitly disputed findings are left alone; disputing is a claim a
# human or the auditor can check, and silently reclassifying it would destroy
# the distinction that makes the metric meaningful.
findings_verify() {
  local feature="$1" row id sha file line status
  findings_current "$feature" | while IFS= read -r row; do
    [ -n "$row" ] || continue
    status="$(printf '%s' "$row" | jq -r '.status // "open"')"
    [ "$status" = "open" ] || continue
    id="$(printf '%s' "$row"   | jq -r '.id')"
    sha="$(printf '%s' "$row"  | jq -r '.raised_at_sha // ""')"
    file="$(printf '%s' "$row" | jq -r '.file // ""')"
    line="$(printf '%s' "$row" | jq -r '.line // "0"')"
    if [ -z "$sha" ] || [ "$sha" = "unknown" ]; then
      printf '  %s  skipped (no sha recorded)\n' "$id"
      continue
    fi
    if _finding_region_touched "$sha" "$file" "$line"; then
      findings_set_status "$feature" "$id" addressed "$file:$line changed since ${sha%"${sha#????????????}"}"
      printf '  %s  addressed\n' "$id"
    else
      findings_set_status "$feature" "$id" ignored "no change to $file:$line since the finding was raised"
      printf '  %s  ignored\n' "$id"
    fi
  done
  findings_uptake "$feature"
}

# critique_uptake_rate: of findings that reached a terminal state, the fraction
# the developer engaged with - addressed or explicitly disputed. Compare against
# the 33.6% baseline in [P11].
findings_uptake() {  # findings_uptake <feature>
  findings_current "$1" | jq -s -c '
    [.[] | select(.status != "open")] as $closed
    | ($closed | length) as $n
    | {feature_findings: length,
       resolved: $n,
       engaged: ([$closed[] | select(.status=="addressed" or .status=="disputed")] | length),
       ignored: ([$closed[] | select(.status=="ignored")] | length),
       critique_uptake_rate: (if $n == 0 then null
         else (([$closed[] | select(.status=="addressed" or .status=="disputed")] | length) * 100 / $n | floor) end),
       baseline_pct: 33.6}' 2>/dev/null || printf '{}'
}

# Per-reviewer unique-find rate: findings only that reviewer raised, that
# survived to addressed or disputed. A lens with near-zero unique yield over
# 10+ features is a deletion candidate, and saying so in the report is the
# discipline that is easy to skip - without it every added role is a permanent
# cost with an
# unmeasured benefit.
findings_reviewer_yield() {  # findings_reviewer_yield <feature|--all>
  local feature="$1" root
  root="$(orch_repo_root)/docs/features"
  { if [ "$feature" = "--all" ]; then
      find "$root" -name findings.jsonl -type f 2>/dev/null | sort | while IFS= read -r p; do cat "$p"; done
    else
      cat "$root/$feature/findings.jsonl" 2>/dev/null
    fi
  } | jq -s -c '
    [.[] | select(type=="object")] | group_by(.id) | map(reduce .[] as $r ({}; . * $r)) as $f
    | ($f | group_by(.claim + "|" + (.file // "")) ) as $byclaim
    | [ $byclaim[] | select(length==1) | .[0] ] as $unique
    | [ $f[] | .raised_by ] | unique
    | map(. as $r
        | {reviewer: $r,
           raised: ([$f[] | select(.raised_by==$r)] | length),
           unique: ([$unique[] | select(.raised_by==$r)] | length),
           unique_surviving: ([$unique[] | select(.raised_by==$r and (.status=="addressed" or .status=="disputed"))] | length)})
    | map(. + {unique_find_rate: (if .raised==0 then null else (.unique_surviving * 100 / .raised | floor) end)})' \
    2>/dev/null || printf '[]'
}
