#!/bin/bash
# statement.sh - the frozen statement, and the frozen oracle.
#
# The Fermat's Last Theorem formalization trusted thirteen million unread lines
# because trust lived in three small things it could check mechanically: the
# statement was frozen and the prover could not touch it; the proof was
# checked against that exact statement, not a paraphrase; and the tests that
# passed were, provably, the tests that had failed [P36][P37]. This file is
# those two identities for a software feature.
#
#   the statement   request.md, requirements.md, contract.md — what was asked.
#                   Frozen by hash at feature start and at tier confirm. Every
#                   gate recomputes the hashes and refuses STATEMENT_MOVED if
#                   they differ. A tech-lead that must amend it re-freezes with
#                   a reason, which is a ledger event, not a silent edit.
#
#   the oracle      the test files as they were when the red phase was
#                   attested — a hash over `git ls-tree` restricted to the
#                   test paths, minus the developer's own test path. The
#                   tests-pass gate recomputes it at HEAD and refuses
#                   ORACLE_MOVED on any difference, however the edit was made:
#                   Edit, Bash, `orch run -- sed`, or another worktree. The
#                   write guard sees only the Edit tool; this sees the tree.
#
# Neither costs a model call. Both are `sha256` and `git ls-tree`.

[ -n "${ORCH_STATEMENT_SOURCED:-}" ] && return 0
ORCH_STATEMENT_SOURCED=1

# shellcheck source=ledger.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ledger.sh"

: "${ORCH_STATEMENT_FILES:=request.md requirements.md contract.md}"
# The oracle's paths, and the carve-out for the developer's own tests. The
# developer may ADD tests under the dev glob (test-first reasoning made
# executable); it may not touch the oracle. The same globs drive
# hooks/write-scope.sh, so the two agree by construction.
: "${ORCH_TEST_GLOB:=test/* tests/* spec/* *_test.* *.test.* *_spec.*}"
: "${ORCH_DEV_TEST_GLOB:=test/dev/* tests/dev/* spec/dev/*}"

# Exit codes, so hooks can branch without parsing prose:
#   6  STATEMENT_MOVED  a frozen statement file changed
#   7  ORACLE_MOVED     the oracle tree at HEAD differs from the red-phase tree

# ---------------------------------------------------------------------------
# The statement
# ---------------------------------------------------------------------------

_statement_file_hash() {  # _statement_file_hash <feature> <file> -> sha, or ''
  local p; p="$(orch_feature_dir "$1")/$2"
  [ -r "$p" ] && orch_sha256 < "$p"
  return 0
}

# statement_freeze <feature> [why]
#
# Freezes every statement file that exists now. A file absent at this freeze
# (requirements.md at feature start, before the tech-lead has written it) is
# simply not frozen yet; the next freeze picks it up. Freezes accumulate; the
# last one is the one gates hold the feature to.
statement_freeze() {
  local feature="$1" why="${2:-}" f h files='' hashes='{}'
  orch_valid_feature "$feature" || die "statement freeze: invalid feature '$feature'"
  for f in $ORCH_STATEMENT_FILES; do
    h="$(_statement_file_hash "$feature" "$f")"
    [ -n "$h" ] || continue
    hashes="$(printf '%s' "$hashes" | jq -c --arg f "$f" --arg h "$h" '.[$f]=$h')"
    files="$files $f"
  done
  [ -n "$files" ] || { warn "statement freeze: no statement file exists for $feature yet"; return 1; }
  ORCH_LEDGER_FEATURE="$feature" ledger_append statement.frozen files:raw "$hashes" why "$why"
  printf 'statement frozen for %s:%s\n' "$feature" "$files"
}

# The last freeze: {ts, files:{name: sha}}, or nothing.
statement_frozen() {  # statement_frozen <feature>
  ledger_read "$1" | jq -c -s '
    [.[] | select(type=="object" and .event=="statement.frozen")]
    | if length==0 then empty else .[-1] | {ts, files} end' 2>/dev/null
}

statement_frozen_at() { statement_frozen "$1" | jq -r '.ts // ""' 2>/dev/null; }

# statement_check <feature> -> 0, or 6 with the moved files on stderr.
#
# A feature that was never frozen has nothing to be held to and passes; that
# is a gap the report should count, not a reason to block a feature that
# predates this file.
statement_check() {
  local feature="$1" frozen f fh h moved=''
  frozen="$(statement_frozen "$feature")"
  [ -n "$frozen" ] || return 0
  for f in $(printf '%s' "$frozen" | jq -r '.files | keys[]'); do
    fh="$(printf '%s' "$frozen" | jq -r --arg f "$f" '.files[$f]')"
    h="$(_statement_file_hash "$feature" "$f")"
    [ "$h" = "$fh" ] || moved="$moved $f"
  done
  [ -n "$moved" ] || return 0
  ORCH_LEDGER_FEATURE="$feature" ledger_append statement.moved files "${moved# }"
  cat >&2 <<EOM
STATEMENT_MOVED:${moved} changed since the statement was frozen at $(printf '%s' "$frozen" | jq -r .ts).

The statement is what every test, review and approval is measured against.
Editing it after the freeze silently changes what "done" means. If the change
is right, say so and re-freeze — that voids the red phase, because tests written
against the old statement no longer describe the new one:

  orch statement freeze $feature --why "<what changed and why>"
EOM
  return 6
}

# ---------------------------------------------------------------------------
# The oracle
# ---------------------------------------------------------------------------

# Is <path> an oracle path: matches a test glob and not the developer's glob.
# `set -f` because the globs are word-split on purpose and must not
# pathname-expand against whatever the cwd happens to be — the same bug
# hooks/write-scope.sh once had.
_oracle_match() {  # _oracle_match <path>
  local p="$1" g
  set -f
  for g in $ORCH_DEV_TEST_GLOB; do
    case "$p" in $g|"${g%/\*}"/*) set +f; return 1 ;; esac
  done
  for g in $ORCH_TEST_GLOB; do
    case "$p" in $g|"${g%/\*}"/*) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# "<blob> <path>" for every oracle file in the tree at <sha>.
oracle_listing() {  # oracle_listing <sha>
  local meta path
  git -C "${ORCH_REPO:-$(orch_repo_root)}" ls-tree -r "$1" 2>/dev/null \
    | while IFS="$(printf '\t')" read -r meta path; do
        _oracle_match "$path" && printf '%s %s\n' "${meta##* }" "$path"
      done
}

oracle_hash() { oracle_listing "$1" | orch_sha256; }  # oracle_hash <sha>

# oracle_freeze <feature> <sha>
oracle_freeze() {
  local feature="$1" sha="$2" h n
  orch_valid_feature "$feature" || die "oracle freeze: invalid feature '$feature'"
  git -C "${ORCH_REPO:-$(orch_repo_root)}" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1 \
    || die "oracle freeze: '$sha' is not a commit in this repository"
  h="$(oracle_hash "$sha")"
  n="$(oracle_listing "$sha" | grep -c .)"
  ORCH_LEDGER_FEATURE="$feature" ledger_append oracle.frozen sha "$sha" hash "$h" files:raw "$n"
  printf 'oracle frozen for %s at %s: %s test file(s), %s\n' "$feature" "$(printf '%s' "$sha" | cut -c1-12)" "$n" "$(printf '%s' "$h" | cut -c1-12)"
}

oracle_frozen() {  # oracle_frozen <feature> -> {ts, sha, hash, files} or nothing
  ledger_read "$1" | jq -c -s '
    [.[] | select(type=="object" and .event=="oracle.frozen")]
    | if length==0 then empty else .[-1] | {ts, sha, hash, files} end' 2>/dev/null
}

# oracle_check <feature> [sha]
#
# 0 when the oracle at <sha> (default HEAD) is the oracle that was frozen, or
# when none was frozen; 7 with the changed files on stderr otherwise.
oracle_check() {
  local feature="$1" sha="${2:-$(orch_head_sha)}" frozen fsha fhash h a b delta
  frozen="$(oracle_frozen "$feature")"
  [ -n "$frozen" ] || return 0
  fsha="$(printf '%s' "$frozen" | jq -r .sha)"
  fhash="$(printf '%s' "$frozen" | jq -r .hash)"
  h="$(oracle_hash "$sha")"
  [ "$h" != "$fhash" ] || return 0
  a="$(mktemp "${TMPDIR:-/tmp}/orch-oracle.XXXXXX")"; b="$(mktemp "${TMPDIR:-/tmp}/orch-oracle.XXXXXX")"
  oracle_listing "$fsha" | sort -k2 > "$a"
  oracle_listing "$sha"  | sort -k2 > "$b"
  # A path whose blob changed appears on both sides; name each path once.
  delta="$(diff "$a" "$b" | sed -n 's/^[<>] [0-9a-f]* //p' | sort -u | sed 's/^/  /')"
  rm -f "$a" "$b"
  ORCH_LEDGER_FEATURE="$feature" ledger_append oracle.moved frozen_sha "$fsha" at_sha "$sha" \
    files "$(printf '%s' "$delta" | tr -s ' \n' ' ')"
  cat >&2 <<EOM
ORACLE_MOVED: the tests at $(printf '%s' "$sha" | cut -c1-12) are not the tests that failed at $(printf '%s' "$fsha" | cut -c1-12).

$delta

The tests that pass must be the tests that failed. The developer does not edit
the oracle, by any tool, in any worktree; the developer's own tests go under
${ORCH_DEV_TEST_GLOB%% *} and are welcome. If an oracle test is wrong, dispute it
and let the auditor settle it by experiment:

  orch findings dispute $feature <id> --reason "<why the test is wrong>"
EOM
  return 7
}
