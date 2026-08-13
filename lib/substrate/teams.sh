#!/bin/bash
# teams.sh - adapter stub for Claude Code agent teams.
#
# Deliberately not implemented. Agent teams are gated behind
# CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS, do not isolate teammates in worktrees
# (the docs state same-file edits overwrite each other), allow one team per
# session, and are not restored by /resume. Three of those four are
# disqualifying for a system whose first invariant is single-threaded writes.
#
# What this file is for: proving the seam is real. If teams graduate, this is
# the only file that has to be written, and test/substrate.test.sh already
# fails the build if anything above lib/substrate/ has reached around it.
#
# To adopt:
#   1. implement the six orch_sub_* functions below against the team API
#   2. keep gate state durable - a team message is not state
#   3. delete the guard in _teams_unavailable

_teams_unavailable() {
  cat >&2 <<'EOF'
orch: the `teams` substrate is a stub, not an implementation.

Agent teams are experimental (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS), give
teammates no worktree isolation, allow one team per session, and are not
restored by /resume. orch's first invariant is that exactly one candidate diff
reaches the base branch at a time, and teams cannot currently uphold it.

Run with the default substrate:  ORCH_SUBSTRATE=messaging
EOF
  return 78  # EX_CONFIG
}

orch_sub_roster()       { _teams_unavailable; }
orch_sub_post()         { _teams_unavailable; }
orch_sub_claim_task()   { _teams_unavailable; }
orch_sub_release_task() { _teams_unavailable; }
orch_sub_set_gate()     { _teams_unavailable; }
orch_sub_read_gate()    { _teams_unavailable; }
orch_sub_probe()        { printf '{"substrate":"teams","available":false,"reason":"stub"}'; }
