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
# Roles that need no path confinement (developer in a worktree) get it from
# `isolation: worktree` instead, which the platform enforces harder than any
# settings glob: it blocks Edit/Write into the main checkout, Bash with a cwd
# there, and `git -C` / GIT_DIR / GIT_WORK_TREE redirects out of the worktree.

set -u
# No pathname expansion, ever. ALLOW and DENY are word-split on purpose so a
# list of globs can live in one variable — but unquoted expansion ALSO
# pathname-expands each glob against this process's cwd, which made the write
# boundary depend on where the hook happened to run: the same file drew
# different rejection messages from different directories, one of them the
# self-refuting "developer writes only: *". Both paths blocked, so nothing
# leaked — but a rule that varies by cwd is not a rule. Found live, in the
# first standard-tier feature. `case` patterns never pathname-expand, so
# matching is unaffected.
set -f
ORCH_PROG=write-scope
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/ledger.sh" 2>/dev/null || exit 0

role="${ORCH_ROLE:-}"
[ -n "$role" ] || exit 0   # unroled session: nothing to confine

payload="$(cat 2>/dev/null)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)"
[ -n "$path" ] || exit 0

# Both sides are resolved before the prefix strip. git reports the repo with
# symlinks resolved; the tool input carries whatever path the agent typed. On
# macOS those differ for anything under /tmp or $TMPDIR (/var -> /private/var),
# and an unresolved comparison would leave `rel` absolute, match no ALLOW glob,
# and block a legitimate write on one platform only.
repo="$(orch_realpath "$(orch_repo_root)")"
abs="$(orch_realpath "$path")"
rel="$abs"
case "$abs" in
  "$repo"/*) rel="${abs#"$repo"/}" ;;
esac

# A path inside a candidate worktree is judged by its worktree-relative form.
# The globs describe the shape of ONE source tree, and every candidate carries
# a whole one — seen from the main checkout its tests live at
# .orch/worktrees/<F>/<cN>/test/..., which `test/*` must still catch. A
# candidate's own session resolves its worktree as the repo root and never
# hits this; it exists for every other vantage point, including the fixture's.
case "$rel" in
  .orch/worktrees/*/*/*) rel="${rel#.orch/worktrees/*/*/}" ;;
esac

# ALLOW and DENY are space-separated shell globs, evaluated against the
# repo-relative path. DENY is checked first so a role can be given a broad
# allowance minus a carve-out — which is what separates the developer (source,
# not tests) from everyone else.
case "$role" in
  director|tech-lead|auditor|code-reviewer)
    ALLOW='docs/features/*' ; DENY='' ;;
  test-engineer)
    ALLOW="${ORCH_TEST_GLOB:-test/* tests/* spec/* *_test.* *.test.* *_spec.*} docs/features/*" ; DENY='' ;;
  developer)
    # The deny encodes the blind oracle: the developer must not edit tests
    # SOMEONE ELSE wrote as its acceptance criteria. That someone exists only
    # at strict and above — at quick and standard the tier table names the
    # developer as the test author, and denying it test paths unconditionally
    # made test-writing tasks unassignable to any role in a standard crew.
    # Found live, by a developer that refused to route around the guard and
    # asked instead, which is exactly what the guard is for.
    . "$ORCH_HOME/lib/escalate.sh" 2>/dev/null || true
    rung="$(escalate_rung "$(orch_current_feature)" 2>/dev/null)" || rung=0
    if [ "${rung:-0}" -ge 2 ]; then
      ALLOW='*' ; DENY="${ORCH_TEST_GLOB:-test/* tests/* spec/* *_test.* *.test.* *_spec.*}"
    else
      ALLOW='*' ; DENY=''
    fi ;;
  *)
    exit 0 ;;
esac

matches() {  # matches <path> <globs...>
  local p="$1"; shift
  local g
  for g in "$@"; do
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
"The developer does not author the tests it must satisfy. Separating test
authorship from implementation is the point of rung 2 — a developer that can edit
the oracle can always make it green.

If the test itself is wrong, say so and let the auditor settle it by experiment:
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
