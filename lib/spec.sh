#!/bin/bash
# spec.sh - requirement-to-test coverage.
#
# On Prove2Me, "linking is attestation": a captain attaching a theorem to a
# milestone declares it faithful to the source, and faithfulness is "the
# single most important thing" [P37]. Here a requirement carries an id (`R1`,
# `R2`, ...) and an oracle test cites it in its name or a comment. A
# requirement no oracle test cites is a blocking finding against the
# test-engineer at the red phase — disputed by naming the ambiguity, which is
# what the role definition already tells it to do.
#
# Citation is weaker than fidelity. This checks that every requirement has a
# test pointing at it, not that the test means what the requirement says;
# that is the read-back's job (docs/AGENT-TDD.md, phase 7). Only the oracle
# counts — a developer's own test cannot be the reason a requirement is
# considered met.

[ -n "${ORCH_SPEC_SOURCED:-}" ] && return 0
ORCH_SPEC_SOURCED=1

# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"
# shellcheck source=statement.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statement.sh"

# "<line> <id>" for every requirement id defined in requirements.md. An id is
# defined where a line starts with it, after any list marker or emphasis.
spec_ids() {  # spec_ids <feature>
  local p; p="$(orch_feature_dir "$1")/requirements.md"
  [ -r "$p" ] || return 0
  grep -nE '^[[:space:]]*([-*+]|[0-9]+[.)]|#+)?[[:space:]]*[*_`]*R[0-9]+[*_`]*\b' "$p" 2>/dev/null \
    | sed -E 's/^([0-9]+):[[:space:]]*([-*+]|[0-9]+[.)]|#+)?[[:space:]]*[*_`]*(R[0-9]+).*/\1 \3/'
}

# spec_coverage <feature> [sha] -> JSON [{id, line, tests: [path...]}]
spec_coverage() {
  local feature="$1" sha="${2:-$(orch_head_sha)}" repo line id paths tests
  repo="${ORCH_REPO:-$(orch_repo_root)}"
  paths="$(oracle_listing "$sha" | cut -d' ' -f2-)"
  spec_ids "$feature" | while read -r line id; do
    [ -n "$id" ] || continue
    if [ -n "$paths" ]; then
      # shellcheck disable=SC2086 — one pathspec per oracle file
      tests="$(git -C "$repo" grep -l -w -E "$id" "$sha" -- $paths 2>/dev/null | sed "s/^[^:]*://" | jq -R . | jq -s -c '.')"
    else
      tests='[]'
    fi
    orch_json id "$id" line:raw "$line" tests:raw "${tests:-[]}"; printf '\n'
  done | jq -s '.' 2>/dev/null || printf '[]'
}

# spec_raise <feature> [sha]
#
# A blocking finding per uncovered requirement, once. Prints the count of
# uncovered ids; prints "unchecked" and records it when requirements.md
# defines no ids at all — what is not numbered cannot be cited.
spec_raise() {
  local feature="$1" sha="${2:-$(orch_head_sha)}" cov n id line claim
  cov="$(spec_coverage "$feature" "$sha")"
  n="$(printf '%s' "$cov" | jq 'length')"
  if [ "${n:-0}" = "0" ]; then
    ORCH_LEDGER_FEATURE="$feature" ledger_append spec.unchecked reason "no requirement ids in requirements.md"
    printf 'unchecked\n'; return 0
  fi
  printf '%s' "$cov" | jq -c '.[] | select(.tests | length == 0)' | while IFS= read -r row; do
    id="$(printf '%s' "$row" | jq -r .id)"; line="$(printf '%s' "$row" | jq -r .line)"
    claim="requirement $id is cited by no oracle test"
    findings_current "$feature" \
      | jq -e --arg c "$claim" 'select(.raised_by=="coverage" and .claim==$c and .status!="addressed")' >/dev/null 2>&1 \
      && continue
    findings_add "$feature" coverage blocking "docs/features/$feature/requirements.md" "$line" "$claim" \
      "nothing will fail if $id is not met; it is a requirement in name only" >/dev/null
  done
  printf '%s' "$cov" | jq '[.[] | select(.tests | length == 0)] | length'
}
