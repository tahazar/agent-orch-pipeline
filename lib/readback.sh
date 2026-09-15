#!/bin/bash
# readback.sh - the read-back: what the tests literally assert, written blind.
#
# Prove2Me attaches a read-back to every statement before it is published: "a
# natural-language rendering of what a Lean 4 declaration *literally
# asserts*", written by an agent that "receives only the Lean code ... never
# the informal statement, mission pitch, or author's intent", because "an
# auditor who knows what the code is 'supposed to say' will read that meaning
# into it" [P37]. The human then compares the read-back to the source.
# "Omitting a hypothesis is the worst failure mode."
#
# Here the statement is the oracle. A code-reviewer session with the
# `readback` lens is given the oracle files and nothing else — not
# requirements.md, not request.md, not contract.md; hooks/artifact-scope.sh
# denies them to that lens — and records, per test, what would have to be
# true for it to pass, including what would satisfy it vacuously. It is a
# translation, not a judgement: the comparison to the requirements is the
# human's, in the approval packet, where the read-back sits beside them.
#
# The read-back is bound to the oracle sha it describes. A read-back of an
# older oracle is shown as stale, never as current.

[ -n "${ORCH_READBACK_SOURCED:-}" ] && return 0
ORCH_READBACK_SOURCED=1

# shellcheck source=statement.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statement.sh"

readback_path() { printf '%s/readback.md' "$(orch_feature_dir "$1")"; }

# The oracle files the read-back may read, one path per line, at the frozen
# sha (or HEAD when nothing is frozen yet).
readback_files() {  # readback_files <feature>
  local sha
  sha="$(oracle_frozen "$1" | jq -r '.sha // ""' 2>/dev/null)"
  oracle_listing "${sha:-$(orch_head_sha)}" | cut -d' ' -f2-
}

# readback_record <feature> <file|-> — the text, as written; bound to the sha.
readback_record() {
  local feature="$1" src="${2:--}" sha body
  orch_valid_feature "$feature" || die "readback record: invalid feature '$feature'"
  if [ "$src" = "-" ]; then body="$(cat)"; else body="$(cat "$src")" || die "readback record: cannot read $src"; fi
  [ -n "$body" ] || die "readback record: nothing to record"
  sha="$(oracle_frozen "$feature" | jq -r '.sha // ""' 2>/dev/null)"
  [ -n "$sha" ] || sha="$(orch_head_sha)"
  {
    printf '# Read-back — %s\n\nOracle at %s. What each test literally asserts, written without sight of the requirements.\n\n' \
      "$feature" "$(printf '%s' "$sha" | cut -c1-12)"
    printf '%s\n' "$body"
  } | orch_atomic_write "$(readback_path "$feature")"
  ORCH_LEDGER_FEATURE="$feature" ledger_append readback.recorded oracle_sha "$sha" \
    words:raw "$(printf '%s' "$body" | wc -w | tr -d ' ')" by "$(orch_actor)"
  printf 'read-back recorded for %s against oracle %s\n' "$feature" "$(printf '%s' "$sha" | cut -c1-12)"
}

# readback_status <feature> -> current | stale | none
readback_status() {
  local feature="$1" rec cur
  rec="$(ledger_read "$feature" | jq -r -s '[.[] | select(type=="object" and .event=="readback.recorded")] | if length==0 then "" else .[-1].oracle_sha end' 2>/dev/null)"
  [ -n "$rec" ] && [ -r "$(readback_path "$feature")" ] || { printf 'none'; return 0; }
  cur="$(oracle_frozen "$feature" | jq -r '.sha // ""' 2>/dev/null)"
  [ -n "$cur" ] || cur="$(orch_head_sha)"
  if [ "$(oracle_hash "$rec")" = "$(oracle_hash "$cur")" ]; then printf 'current'; else printf 'stale'; fi
}
