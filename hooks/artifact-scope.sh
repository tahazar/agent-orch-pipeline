#!/bin/bash
# artifact-scope.sh - PreToolUse on Read/Grep. Need-to-know for artifacts.
#
# hooks/task-scope.sh scopes what a role may learn from the task list. This is
# the same principle for docs/features/**, and the measured reason it exists:
# the v1 session produced 301k words of coordination artifacts for 8.4k lines
# of code, and every agent re-read the tree every turn. Most of that re-reading
# was not just waste but harm — the two roles whose value depends on NOT
# knowing things had access to everything.
#
#   director, auditor,
#   tech-lead           every artifact — they coordinate, plan, adjudicate
#   developer           its own feature's directory, nothing cross-feature
#   test-engineer       requirements.md and request.md ONLY. The blind oracle
#                       is the entire point of the strict tier: a test author
#                       that can read the plan or the status file writes tests
#                       shaped by the implementation's intentions. If a ruling
#                       changes what the tests must assert, it belongs in
#                       requirements.md, not in a side channel.
#   code-reviewer       requirements.md and request.md ONLY — the criteria.
#                       The diff comes from git, and the developer's trace is
#                       exactly what fresh context means not having.
#
# Scope, honestly stated: this intercepts the Read and Grep tools. It does not
# intercept `Bash(cat ...)` — but the crew's Bash allowlist does not include
# cat, so that path is permission-gated rather than unguarded. The rule is
# stated positively here for the same reason write-scope.sh states its rule
# positively: the path you forgot to deny is the one that gets read.

set -u
ORCH_PROG=artifact-scope
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/ledger.sh" 2>/dev/null || {
  printf 'orch artifact-scope could not load its libraries; NOT blocking. Fix orch before relying on scoping.\n' >&2
  exit 0
}

role="${ORCH_ROLE:-}"
[ -n "$role" ] || exit 0
case "$role" in director|auditor|tech-lead) exit 0 ;; esac
case "$role" in developer|test-engineer|code-reviewer) ;; *) exit 0 ;; esac

payload="$(cat 2>/dev/null)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"
case "$tool" in Read|Grep) ;; *) exit 0 ;; esac

path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null)"
[ -n "$path" ] || exit 0

# Resolved first, raw second: a path whose parent does not exist yet cannot be
# resolved, and on macOS the resolved repo root (/private/var/...) will not
# prefix-match it. A read of a nonexistent cross-feature path still names the
# feature it was aimed at, and the scope decision is about the aim.
repo_raw="$(orch_repo_root)"
repo="$(orch_realpath "$repo_raw")"
abs="$(orch_realpath "$path")"
rel="$abs"
case "$abs" in
  "$repo"/*)     rel="${abs#"$repo"/}" ;;
  "$repo_raw"/*) rel="${abs#"$repo_raw"/}" ;;
esac

# Only docs/features/** is scoped; source visibility is write-scope's and the
# worktree's problem, and a repo's own README is nobody's secret.
case "$rel" in docs/features/*) ;; *) exit 0 ;; esac

my_feature="${ORCH_FEATURE:-$(orch_current_feature)}"
target="${rel#docs/features/}"
target_feature="${target%%/*}"
target_file="${target#*/}"
# A path that IS the feature directory has no file component. For the scoped
# roles that means a sweep of the whole trace, which is the thing the allowlist
# exists to prevent — so it falls through to the per-role case as a non-allowed
# "file" rather than being special-cased into an exemption.
[ "$target_file" = "$target" ] && target_file='.'

block() {  # block <reason> <guidance>
  ORCH_LEDGER_FEATURE="$my_feature" \
    ledger_append gate.blocked gate artifact-scope role "$role" path "$rel" reason "$1"
  printf 'BLOCKED: %s may not read %s (%s).\n\n%s\n' "$role" "$rel" "$1" "$2" >&2
  exit 2
}

if [ "$target_feature" != "$my_feature" ]; then
  block "it belongs to $target_feature, and you are on $my_feature" \
"Features are separate contexts on purpose. If something from $target_feature
genuinely bears on your work, say so in a finding and let the tech-lead carry
it into your feature's requirements."
fi

case "$role" in
  test-engineer|code-reviewer)
    case "$target_file" in
      requirements.md|request.md) ;;
      *)
        if [ "$role" = "test-engineer" ]; then
          block "the oracle is written blind" \
"Tests come from requirements.md and nothing else. Reading the plan, the
status, or the developer's artifacts shapes the tests around what is being
built instead of what was asked for — which is a test that passes by
construction and checks nothing.

If requirements.md is ambiguous, raise it rather than resolving it from a
side channel:
  orch findings add $my_feature --raised-by test-engineer --severity major \\
    --file docs/features/$my_feature/requirements.md --line 0 \\
    --claim \"...\" --consequence \"...\""
        else
          block "a code-reviewer gets the diff and the criteria, nothing else" \
"Your independence is the only reason you are worth running. requirements.md
and request.md are your criteria; the diff comes from git. The rest of this
directory is the crew's trace, and a reviewer that has read the author's
reasoning has stopped being a second opinion."
        fi
        ;;
    esac
    ;;
esac

exit 0
