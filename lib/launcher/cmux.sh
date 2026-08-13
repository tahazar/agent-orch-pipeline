#!/bin/bash
# cmux.sh - sessions as cmux workspaces.
#
# The default, and the reason the launcher seam exists at all. A cmux workspace
# is persistent, named, survives the terminal closing, can be watched working in
# real time, and can be read as plain text from any other terminal with
# `cmux read-screen` — without orch owning a single line of terminal plumbing.
#
# What it does NOT do is carry messages. Coordination is the shared task list;
# cmux only decides where a session lives and how you look at it. Keeping those
# separate is the whole point — the moment a launcher starts relaying state, it
# has become a transport, and transports are what this pipeline stopped
# writing.

orch_lnch_spawn() {  # <role> <name> <cwd> [KEY=VALUE...]
  local role="$1" name="$2" cwd="$3"; shift 3
  local args cmd kv

  cmd="$(launcher_claude_cmd "$role" "$name")"

  # One workspace group per repo keeps a six-agent crew from scattering itself
  # through a tab strip that also has your editor in it.
  args="--name orch:$name --cwd $cwd --focus false"

  set -- "$@"
  local envargs=''
  while [ "$#" -gt 0 ]; do
    kv="$1"; shift
    case "$kv" in *=*) envargs="$envargs --env $kv" ;; esac
  done

  # shellcheck disable=SC2086 — args and envargs are deliberately word-split
  if cmux new-workspace $args $envargs --command "$cmd" >/dev/null 2>&1; then
    printf 'spawned %s as cmux workspace `orch:%s`\n' "$role" "$name" >&2
    return 0
  fi
  warn "cmux could not create a workspace for $name"
  return 1
}

_cmux_ws() {  # _cmux_ws <name> -> the workspace ref, or empty
  cmux workspace list 2>/dev/null \
    | sed -n "s/^[* ]*\(workspace:[0-9]*\)[[:space:]]*.*orch:$1\([[:space:]].*\)\{0,1\}$/\1/p" \
    | head -1
}

orch_lnch_kill() {  # <name>
  local ws; ws="$(_cmux_ws "$1")"
  [ -n "$ws" ] || { warn "no cmux workspace named orch:$1"; return 1; }
  cmux close-workspace --workspace "$ws" >/dev/null 2>&1 || return 1
  printf 'closed %s\n' "$1" >&2
}

orch_lnch_peek() {  # <name> [lines]
  local ws; ws="$(_cmux_ws "$1")"
  [ -n "$ws" ] || { warn "no cmux workspace named orch:$1"; return 1; }
  cmux read-screen --workspace "$ws" --scrollback --lines "${2:-60}" 2>/dev/null
}

orch_lnch_list() {
  cmux workspace list 2>/dev/null | sed -n 's/.*orch:\([A-Za-z0-9_-]*\).*/\1/p'
}

orch_lnch_notify() {  # <title> <body>
  cmux notify --title "$1" --body "${2:-}" >/dev/null 2>&1
}

orch_lnch_probe() {
  local ok=false ver=''
  if cmux ping >/dev/null 2>&1; then ok=true; ver="$(cmux version 2>/dev/null | head -1)"; fi
  jq -n -c --arg launcher cmux --argjson reachable "$ok" --arg version "$ver" \
    --argjson sessions "$(orch_lnch_list | jq -R -s -c 'split("\n") | map(select(length>0))')" \
    '$ARGS.named'
}
