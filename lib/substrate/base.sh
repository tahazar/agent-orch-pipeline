#!/bin/bash
# base.sh - the substrate seam.
#
# Six operations, one implementation selected at load time. Everything above
# this file talks to coordination only through these names. Nothing above this
# directory may call `claude agents`, invoke SendMessage, or touch
# ~/.claude/tasks - test/substrate.test.sh enforces that mechanically.
#
# The seam exists because the substrate is a moving target: agent teams are
# experimental today, the messaging socket is an internal, and the task-list
# layout is undocumented. When one of those changes, exactly one directory
# changes with it.
#
#   substrate_roster                      -> JSON array of live sessions
#   substrate_post <to> <body>            -> notify a peer (best effort)
#   substrate_claim_task <id> <owner>     -> take ownership, non-blocking
#   substrate_release_task <id>           -> give it back
#   substrate_set_gate <feature> <gate> <state> [sha]
#   substrate_read_gate <feature> <gate>  -> JSON {state, sha, at, by}
#   substrate_probe                       -> JSON diagnostics for `orch doctor`
#
# probe is here rather than in doctor.sh on purpose: the platform facts it
# reports (socket paths, task-list location, permission-mode class) are exactly
# the internals the seam exists to contain. doctor renders what probe says; it
# does not know where any of it lives.
#
# Contract shared by both implementations:
#   - every operation is idempotent
#   - `post` failing is never fatal; a message is never load-bearing (spec §3)
#   - gate state is durable, message delivery is not

[ -n "${ORCH_SUBSTRATE_SOURCED:-}" ] && return 0
ORCH_SUBSTRATE_SOURCED=1

# shellcheck source=../common.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
# Implementations log through the ledger, so it has to exist before they load.
# shellcheck source=../ledger.sh
. "$ORCH_HOME/lib/ledger.sh"

: "${ORCH_SUBSTRATE:=messaging}"

case "$ORCH_SUBSTRATE" in
  messaging) . "$ORCH_HOME/lib/substrate/messaging.sh" ;;
  teams)     . "$ORCH_HOME/lib/substrate/teams.sh" ;;
  *) die "unknown ORCH_SUBSTRATE '$ORCH_SUBSTRATE' (expected: messaging, teams)" ;;
esac

for _op in roster post claim_task release_task set_gate read_gate probe; do
  if ! declare -f "orch_sub_$_op" >/dev/null 2>&1; then
    die "substrate '$ORCH_SUBSTRATE' does not implement $_op"
  fi
done
unset _op

substrate_name()         { printf '%s' "$ORCH_SUBSTRATE"; }
substrate_roster()       { orch_sub_roster "$@"; }
substrate_post()         { orch_sub_post "$@"; }
substrate_claim_task()   { orch_sub_claim_task "$@"; }
substrate_release_task() { orch_sub_release_task "$@"; }
substrate_set_gate()     { orch_sub_set_gate "$@"; }
substrate_read_gate()    { orch_sub_read_gate "$@"; }
substrate_probe()        { orch_sub_probe "$@"; }
