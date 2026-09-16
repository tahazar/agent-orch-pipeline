#!/bin/bash
# axioms.sh - the enumerated escape hatches.
#
# The FLT build fails unless the theorem "depends on axioms: [propext,
# Classical.choice, Quot.sound]" — exactly Lean's three — and no module may
# contain `sorry`, `axiom`, `native_decide`, `unsafe`, `extern`,
# `implemented_by` or `partial def` [P36]. The list is short, mechanical, and
# checked by the build rather than by a reviewer. Buzzard's audit of the result
# was the same check by hand: flag every line that is not a definition or a
# proof; about a hundred came back out of thirteen million [P41].
#
# A test suite has its own `sorry`s, each with a different spelling: `.skip`,
# `.only`, `xfail`, `# type: ignore`, `eslint-disable`, an `except: pass`
# around the assertion, a regenerated snapshot, one edit to the test command.
# A scanner has the same: `# nosec`, `# nosemgrep`, `checkov:skip`,
# `trivy:ignore` — a finding silenced at the line is a finding nobody sees.
# This file enumerates them and counts them in the diff. Any INCREASE against
# the base branch is a blocking finding raised by `axioms`, which the developer
# fixes or disputes like any other. Trusted configuration — the files that
# decide what "the tests pass" means — is an axiom wholesale: a change to any
# of them is a finding too.
#
# The list is a guess with a mechanism attached. `orch findings yield` shows
# whether `axioms` blocks anything; a lens that never fires is deleted.

[ -n "${ORCH_AXIOMS_SOURCED:-}" ] && return 0
ORCH_AXIOMS_SOURCED=1

# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"

: "${ORCH_AXIOM_PATHS:=.github/* .gitlab-ci.yml Jenkinsfile jest.config.* vitest.config.* pytest.ini tox.ini setup.cfg .eslintrc* eslint.config.* .mocharc* __snapshots__/* *.snap}"

# One extended regex per line. A repo overrides the whole list with
# .claude/orch-axioms.txt (or ORCH_AXIOMS_FILE); comments and blanks ignored.
axioms_patterns() {
  local f="${ORCH_AXIOMS_FILE:-$(orch_main_repo)/.claude/orch-axioms.txt}"
  if [ -r "$f" ]; then grep -v '^[[:space:]]*#' "$f" | grep .; return 0; fi
  cat <<'PATTERNS'
\.(only|skip)\(
\b(xit|xdescribe|xtest|fit|fdescribe)\(
\.(todo|failing)\(
@ts-(ignore|expect-error)
eslint-disable
istanbul ignore
c8 ignore
pytest\.mark\.(skip|xfail)
unittest\.skip
# *type: *ignore
# *noqa
pragma: no cover
except( +[A-Za-z_.]+)?: *(pass|\.\.\.) *$
\bt\.Skipf?\(
//nolint
#\[ignore\]
#\[allow\(
rubocop:disable
expect\(true\)\.toBe\(true\)
assert True *$
nosec
nosemgrep
(checkov|bridgecrew):skip
(trivy|tfsec|terrascan):ignore
NOSONAR
(lgtm|codeql) *\[
PATTERNS
}

_axioms_is_config() {  # _axioms_is_config <path>
  local p="$1" g
  set -f
  for g in $ORCH_AXIOM_PATHS; do
    case "$p" in $g|"${g%/\*}"/*) set +f; return 0 ;; esac
    case "$(basename "$p")" in $g) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# axioms_scan <base> <head>
#
# JSON array of increases: {kind: pattern|config, file, line, pattern, base, head}.
# Deleted files cannot add an escape hatch; renamed files are judged as their
# new name against the old content.
axioms_scan() {
  local base="$1" head="$2" repo status old file bf hf pat bc hc line
  repo="${ORCH_REPO:-$(orch_repo_root)}"
  bf="$(mktemp "${TMPDIR:-/tmp}/orch-ax.XXXXXX")"; hf="$(mktemp "${TMPDIR:-/tmp}/orch-ax.XXXXXX")"
  git -C "$repo" diff --name-status "$base" "$head" -- . ':(exclude)docs/features' 2>/dev/null \
  | while IFS="$(printf '\t')" read -r status old file; do
      case "$status" in
        D*) continue ;;
        R*|C*) ;;                       # old<TAB>new
        *) file="$old" ;;
      esac
      [ -n "$file" ] || continue
      if _axioms_is_config "$file"; then
        orch_json kind config file "$file" line 0 pattern "" base:raw 0 head:raw 1; printf '\n'
      fi
      git -C "$repo" show "$base:$old" > "$bf" 2>/dev/null || : > "$bf"
      git -C "$repo" show "$head:$file" > "$hf" 2>/dev/null || : > "$hf"
      axioms_patterns | while IFS= read -r pat; do
        bc="$(grep -cE -- "$pat" "$bf" 2>/dev/null)"; hc="$(grep -cE -- "$pat" "$hf" 2>/dev/null)"
        [ "${hc:-0}" -gt "${bc:-0}" ] || continue
        line="$(grep -nE -- "$pat" "$hf" | tail -1 | cut -d: -f1)"
        orch_json kind pattern file "$file" line "${line:-0}" pattern "$pat" base:raw "${bc:-0}" head:raw "${hc:-0}"; printf '\n'
      done
    done | jq -s '.' 2>/dev/null || printf '[]'
  rm -f "$bf" "$hf"
}

# axioms_raise <feature> <base> <head>
#
# Turns each increase into a blocking finding raised by `axioms`, once: a
# finding already on record for the same file and claim is not raised again,
# so a guard that runs on every task completion does not pile up duplicates.
# Prints the number of open axioms findings afterwards.
axioms_raise() {
  local feature="$1" base="$2" head="$3" row claim file line cons
  axioms_scan "$base" "$head" | jq -c '.[]' | while IFS= read -r row; do
    [ -n "$row" ] || continue
    file="$(printf '%s' "$row" | jq -r .file)"; line="$(printf '%s' "$row" | jq -r .line)"
    if [ "$(printf '%s' "$row" | jq -r .kind)" = config ]; then
      claim="trusted configuration changed: $file"
      cons="what 'the tests pass' means changed with the diff; the gate cannot tell a fix from a loosened check"
    else
      claim="new escape hatch: $(printf '%s' "$row" | jq -r .pattern) ($(printf '%s' "$row" | jq -r .base) -> $(printf '%s' "$row" | jq -r .head))"
      cons="a test or check can now pass without proving the requirement, and nothing downstream can tell"
    fi
    findings_current "$feature" \
      | jq -e --arg f "$file" --arg c "$claim" 'select(.raised_by=="axioms" and .file==$f and .claim==$c)' >/dev/null 2>&1 \
      && continue
    findings_add "$feature" axioms blocking "$file" "$line" "$claim" "$cons" >/dev/null
  done
  findings_current "$feature" | jq -s '[.[] | select(.raised_by=="axioms" and .status=="open")] | length' 2>/dev/null || printf 0
}

axioms_open() {  # axioms_open <feature> -> the open axioms findings, one per line
  findings_current "$1" | jq -r 'select(.raised_by=="axioms" and .status=="open") | "  \(.id)  \(.file):\(.line)  \(.claim)"' 2>/dev/null
}
