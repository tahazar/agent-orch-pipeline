#!/bin/bash
# print.sh - spawn nothing; print what you would have run.
#
# The fallback when there is no cmux and no claude on PATH, and the right
# choice when you want to place sessions yourself — your own tabs, your own
# window layout, a remote host.
#
# It is also the honest answer to "what does orch actually do to my machine".
# Every other launcher runs exactly this command; this one shows it to you
# first. Nothing here starts a process, so `spawn` succeeding means the command
# was printed, and the ledger records it as printed rather than as spawned.

orch_lnch_spawn() {  # <role> <name> <cwd> [KEY=VALUE...]
  local role="$1" name="$2" cwd="$3"; shift 3
  local kv

  printf '\n# %s — run this where you want it to live:\n' "$name"
  printf 'cd %s\n' "$(printf '%q' "$cwd")"
  while [ "$#" -gt 0 ]; do
    kv="$1"; shift
    case "$kv" in *=*) printf 'export %s\n' "$(printf '%q' "$kv")" ;; esac
  done
  printf '%s\n' "$(launcher_claude_cmd "$role" "$name")"
  return 0
}

orch_lnch_kill() {
  printf 'Stop %s in the terminal running it, or via `claude agents`.\n' "$1" >&2
  return 1
}

orch_lnch_peek() {
  printf 'Look at the terminal running %s. orch did not start it and cannot read it.\n' "$1" >&2
  return 1
}

orch_lnch_list() { printf ''; }

orch_lnch_notify() { printf '\n*** %s — %s ***\n' "$1" "${2:-}" >&2; }

orch_lnch_probe() {
  jq -n -c --arg launcher print --argjson reachable true --arg version "" \
    --argjson sessions '[]' \
    --arg note "prints commands; starts nothing" \
    '$ARGS.named'
}
