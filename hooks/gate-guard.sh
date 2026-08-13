#!/bin/bash
# gate-guard.sh - PreToolUse. Blocks a merge, push, or PR without approval.
#
# Claude Code's own gate-strength ranking puts a hook returning exit 2 above an
# in-prompt instruction [P1][P5]. It is easy to wire a full set of hooks that
# only ever exit 0 — setting colours, ringing bells — and believe the boundary
# is enforced. A hook that cannot say no is decoration.
#
# Exit 2 with the reason on stderr; stderr reaches the model as feedback, so
# the reason has to be actionable rather than merely disapproving.

set -u
ORCH_PROG=gate-guard
ORCH_HOME="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ORCH_HOME ORCH_PROG

# A hook that cannot load its own libraries must not block the session: a
# broken guard should be visible, not paralysing. It fails open and says so.
. "$ORCH_HOME/lib/substrate/base.sh" 2>/dev/null || {
  printf 'orch gate-guard could not load its libraries; NOT blocking. Fix orch before relying on gates.\n' >&2
  exit 0
}

payload="$(cat 2>/dev/null)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# The declarative `if` field in settings.json pre-filters with permission-rule
# syntax, so this process is not even spawned for unrelated Bash calls. The
# match below is the belt to that braces: a hook wired by hand, or an `if` that
# a future settings schema drops, must still be correct on its own.
case "$cmd" in
  *"git merge"*|*"git push"*|*"gh pr create"*) ;;
  *) exit 0 ;;
esac

# `git merge --abort` and `--continue` resolve a merge that is already
# underway. Blocking them strands the tree mid-merge, which is worse than the
# thing the gate protects against.
case "$cmd" in
  *"--abort"*|*"--continue"*|*"--quit"*) exit 0 ;;
esac

feature="$(orch_current_feature)"
head="$(orch_head_sha)"
state_json="$(substrate_read_gate "$feature" human 2>/dev/null)"
state="$(printf '%s' "$state_json" | jq -r '.state // "absent"' 2>/dev/null)"
sha="$(printf '%s' "$state_json" | jq -r '.sha // ""' 2>/dev/null)"

ORCH_LEDGER_FEATURE="$feature" ledger_append gate.checked gate human state "$state" cmd "$cmd"

if [ "$state" = "met" ] && [ "$sha" = "$head" ]; then
  exit 0
fi

if [ "$state" = "met" ]; then
  ORCH_LEDGER_FEATURE="$feature" ledger_append gate.blocked gate human reason stale_sha cmd "$cmd"
  cat >&2 <<EOF
BLOCKED: the human gate for $feature was approved at ${sha} but HEAD is now ${head}.

An approval is a statement about a specific diff. The branch tip moved after it
was given, so it no longer describes what you are about to merge.

Re-review, then:  orch approve $feature --gate human
EOF
  exit 2
fi

ORCH_LEDGER_FEATURE="$feature" ledger_append gate.blocked gate human reason "state=$state" cmd "$cmd"
cat >&2 <<EOF
BLOCKED: no human approval for $feature at ${head}.

The human gate is $state. Nothing merges, pushes, or opens a PR without an
approval task marked done for the current sha.

From any terminal, including one with no live session:

  orch approve $feature --gate human

That writes to the shared task list under the first-party lock. It survives a
dead session and it is greppable afterwards — which is more than typing into a
tmux pane ever gave you.
EOF
exit 2
