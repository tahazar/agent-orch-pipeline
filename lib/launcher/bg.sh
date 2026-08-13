#!/bin/bash
# bg.sh - sessions as background agents.
#
# For terminals that are not cmux, and for anything headless: CI, a cron run,
# an SSH session you intend to close. `claude --bg` starts a session and
# returns, and the platform's own roster manages it from there.
#
# The tradeoff is the one worth stating plainly: you give up watching. There is
# no screen to read, so `orch peek` cannot show you one and says so instead of
# printing nothing. Everything else still works, because none of it was ever
# riding on the terminal — state is the task list, the ledger, and
# docs/features/**, all of which are on disk and readable from anywhere.

orch_lnch_spawn() {  # <role> <name> <cwd> [KEY=VALUE...]
  local role="$1" name="$2" cwd="$3"; shift 3
  local kv script

  # env(1) rather than exporting into this shell: a spawn must not leak the
  # role of the session it started into the session doing the starting.
  script="cd $(printf '%q' "$cwd") && env"
  while [ "$#" -gt 0 ]; do
    kv="$1"; shift
    case "$kv" in *=*) script="$script $(printf '%q' "$kv")" ;; esac
  done
  script="$script $(launcher_claude_cmd "$role" "$name") --bg"

  if ( eval "$script" ) >/dev/null 2>&1; then
    printf 'spawned %s as a background session\n' "$name" >&2
    return 0
  fi
  warn "claude --bg failed for $name"
  return 1
}

orch_lnch_kill() {  # <name>
  # No process table walking and no killing by name match: a background session
  # is the platform's to manage, and guessing at pids is how you kill the wrong
  # editor. Ask the roster, then ask the human.
  warn "the bg launcher does not stop sessions. Find it with \`claude agents\` and stop it there."
  return 1
}

orch_lnch_peek() {  # <name> [lines]
  warn "the bg launcher has no screen to read — a background session is not attached to a terminal.
Read its work instead:  orch watch, orch report, docs/features/**
Or switch launcher:     ORCH_LAUNCHER=cmux orch spawn ..."
  return 1
}

orch_lnch_list() { printf ''; }

orch_lnch_notify() {  # <title> <body>
  # OSC 9 reaches most modern terminals and is inert in the ones it does not.
  printf '\033]9;%s\007' "$1: ${2:-}" >&2
}

orch_lnch_probe() {
  jq -n -c --arg launcher bg \
    --argjson reachable "$(have claude && printf true || printf false)" \
    --arg version "" --argjson sessions '[]' \
    --arg note "background sessions cannot be watched or stopped from orch" \
    '$ARGS.named'
}
