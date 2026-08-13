#!/bin/bash
# task-scope.sh - PreToolUse on TaskGet/TaskList/TaskUpdate. Need-to-know.
#
# Every session in a team shares one task list, because that is what gives us
# first-party file locking and blocks/blockedBy auto-unblock. Sharing the list
# is not the same as reading all of it, and the difference is load-bearing.
#
# The reviewer is the case that matters. Its entire value is that it has not
# seen the developer's reasoning: fresh context, the diff, the criteria, and
# nothing else. A reviewer that can read the developer's task history is
# anchored to the developer's argument, and the union-of-lenses result that
# justifies running more than one of them only holds while they are
# independent. Correlated reviewers cost the same and find less.
#
# The test-engineer is the second case. If it can see the developer's tasks it
# writes tests that describe the implementation instead of the requirements,
# which inverts the one property strict tier exists to buy.
#
#   director, auditor   everything — they adjudicate and they own the run
#   tech-lead           its own feature
#   developer           its own feature
#   test-engineer       its own feature, minus the developer's tasks
#   code-reviewer       nothing (TaskList/TaskGet are denied outright in its
#                       role definition; this hook is the backstop for a
#                       hand-launched session that skipped them)
#
# Reads are narrowed, not blocked wholesale: a role must still be able to find
# its own work. Exit 2 with the reason on stderr, which reaches the model.

set -u
ORCH_PROG=task-scope
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

. "$ORCH_HOME/lib/ledger.sh" 2>/dev/null || {
  printf 'orch task-scope could not load its libraries; NOT blocking. Fix orch before relying on scoping.\n' >&2
  exit 0
}

role="${ORCH_ROLE:-}"
[ -n "$role" ] || exit 0   # unroled session: nothing to scope

# The roles that see the whole board. Deciding what to hide from an adjudicator
# is how you end up with an auditor that approves what it could not see.
case "$role" in director|auditor) exit 0 ;; esac

payload="$(cat 2>/dev/null)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"
case "$tool" in TaskGet|TaskList|TaskUpdate|mcp__*__Task*) ;; *) exit 0 ;; esac

my_feature="${ORCH_FEATURE:-$(orch_current_feature)}"

block() {  # block <reason> <guidance>
  ORCH_LEDGER_FEATURE="$my_feature" \
    ledger_append gate.blocked gate task-scope role "$role" tool "$tool" reason "$1"
  printf 'BLOCKED: %s may not %s here (%s).\n\n%s\n' "$role" "$tool" "$1" "$2" >&2
  exit 2
}

# --- the reviewer sees no tasks at all -------------------------------------
if [ "$role" = "code-reviewer" ]; then
  block "a code-reviewer reviews a diff, not a task list" \
"Your independence is the only reason you are worth running. Reading the task
list would show you the developer's reasoning, and a reviewer that has seen the
author's argument stops being a second opinion.

You are given the diff and the criteria. Report what you find:
  orch findings add <feature> --raised-by <your lens> --severity <blocking|major|minor> \\
    --file <path> --line <n> --claim \"...\" --consequence \"...\""
fi

# --- everyone else is scoped to their own feature --------------------------
target_feature="$(printf '%s' "$payload" \
  | jq -r '.tool_input.metadata.orch.feature // .tool_input.feature // ""' 2>/dev/null)"
target_owner="$(printf '%s' "$payload" \
  | jq -r '.tool_input.metadata.orch.role // ""' 2>/dev/null)"

if [ -n "$target_feature" ] && [ "$target_feature" != "$my_feature" ]; then
  block "it belongs to $target_feature, and you are on $my_feature" \
"Features are serial and each one is a separate context on purpose. Whatever
you need from $target_feature is either in its artifacts under
docs/features/$target_feature/, or it is not yours to act on."
fi

# The test-engineer writes the oracle. It must not be able to read the tasks of
# the role whose work the oracle is supposed to judge.
if [ "$role" = "test-engineer" ] && [ "$target_owner" = "developer" ]; then
  block "it is the developer's task, and you write the oracle it has to satisfy" \
"Tests come from requirements.md, not from what the developer decided to build.
A test written against the implementation passes by construction and checks
nothing.

If requirements.md is genuinely ambiguous, say so — do not resolve it by
reading the implementation:
  orch findings add $my_feature --raised-by test-engineer --severity major \\
    --file docs/features/$my_feature/requirements.md --line 0 \\
    --claim \"...\" --consequence \"...\""
fi

exit 0
