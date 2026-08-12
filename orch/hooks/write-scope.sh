#!/bin/bash
# write-scope.sh - PreToolUse on Edit/Write/NotebookEdit. Confines each role.
#
# Why a hook and not a permission rule: in Claude Code deny takes precedence
# over allow, so the natural expression of "may write only under docs/features"
# — deny everything, allow that one prefix — does not work; the broad deny wins
# and the role can write nothing. A denylist of everything else is the usual
# workaround and it is fragile in exactly the wrong direction, because the file
# you forgot to list is the one that gets written.
#
# A hook states the rule positively, and the gate-strength ranking puts it above
# a permission rule anyway [P1][P5]. Invariant 2 says capability is enforced by
# a mechanism and never by prompt; this is the mechanism for paths.
#
# Roles that need no path confinement (builder in a worktree) get it from
# `isolation: worktree` instead, which the platform enforces harder than any
# settings glob: it blocks Edit/Write into the main checkout, Bash with a cwd
# there, and `git -C` / GIT_DIR / GIT_WORK_TREE redirects out of the worktree.

set -u
ORCH_PROG=write-scope
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/ledger.sh" 2>/dev/null || exit 0

role="${ORCH_ROLE:-}"
[ -n "$role" ] || exit 0   # unroled session: nothing to confine

payload="$(cat 2>/dev/null)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)"
[ -n "$path" ] || exit 0

repo="$(orch_repo_root)"
rel="$path"
case "$path" in
  "$repo"/*) rel="${path#"$repo"/}" ;;
  /*) rel="$path" ;;
esac

# ALLOW and DENY are space-separated shell globs, evaluated against the
# repo-relative path. DENY is checked first so a role can be given a broad
# allowance minus a carve-out — which is what separates the builder (source,
# not tests) from everyone else.
case "$role" in
  conductor|planner|arbiter|reviewer)
    ALLOW='docs/features/*' ; DENY='' ;;
  prover)
    ALLOW="${ORCH_TEST_GLOB:-test/* tests/* spec/* *_test.* *.test.* *_spec.*} docs/features/*" ; DENY='' ;;
  builder)
    ALLOW='*' ; DENY="${ORCH_TEST_GLOB:-test/* tests/* spec/* *_test.* *.test.* *_spec.*}" ;;
  *)
    exit 0 ;;
esac

matches() {  # matches <path> <globs...>
  local p="$1"; shift
  local g
  for g in $@; do
    # shellcheck disable=SC2254 — $g is a glob on purpose
    case "$p" in $g) return 0 ;; esac
    case "$p" in ${g%/\*}/*) return 0 ;; esac
  done
  return 1
}

block() {
  ORCH_LEDGER_FEATURE="$(orch_current_feature)" \
    ledger_append gate.blocked gate write-scope role "$role" path "$rel" reason "$1"
  printf 'BLOCKED: %s may not write %s (%s).\n\n%s\n' "$role" "$rel" "$1" "$2" >&2
  exit 2
}

if [ -n "$DENY" ] && matches "$rel" $DENY; then
  block "it is a test path" \
"The builder does not author the tests it must satisfy. Separating test
authorship from implementation is the point of rung 2 — a builder that can edit
the oracle can always make it green.

If the test itself is wrong, say so and let the arbiter settle it by experiment:
  orch findings dispute <feature> <id> --reason \"<why the test is wrong>\""
fi

if ! matches "$rel" $ALLOW; then
  block "it is outside this role's write scope" \
"$role writes only: $ALLOW

Extra agents contribute information, never actions (invariant 2). If this
change needs making, hand it to the role that owns it rather than making it
here."
fi

exit 0
