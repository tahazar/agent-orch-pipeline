#!/bin/bash
# cmux.sh - a crew is one workspace; each agent is a pane in it.
#
# The default, and the reason the launcher seam exists at all. The tiling is
# the point: the predecessor's best property was six agents visible on one
# screen, working, interruptible — and the first cut of this launcher lost it
# by giving every agent its own workspace, which reads as a drawer of separate
# terminals rather than a team at work.
#
#   orch:run          the director (and anything else run-scoped)
#   orch:<feature>    the feature's crew, one pane per role
#
# The first agent into a workspace creates it; the rest split into it. The
# launcher keeps a name→pane map under .orch/, keyed by UUID: cmux's short
# refs (surface:N) are positional and renumber as panes come and go — closing
# by short ref closed the wrong thing in testing — while UUIDs are stable for
# the pane's lifetime. Every targeting call passes the workspace UUID too,
# because close-surface resolves within a workspace. All of this is verified
# against cmux 0.64, not assumed.
#
# What it does NOT do is carry messages. Coordination is the shared task list;
# cmux only decides where a session lives and how you look at it. The moment a
# launcher starts relaying state it has become a transport, and transports are
# what this pipeline stopped writing.

export CMUX_QUIET=1

_cmux_map() { printf '%s/.orch/cmux-panes' "${ORCH_REPO:-.}"; }

_UUID_RE='[0-9A-Fa-f-]\{36\}'

# Workspace title for a spawn: the feature's crew tiles together; run-scoped
# roles (no ORCH_FEATURE in their env) share orch:run.
_cmux_ws_title() {  # _cmux_ws_title [KEY=VALUE...]
  local kv
  for kv in "$@"; do
    case "$kv" in ORCH_FEATURE=*) printf 'orch:%s' "${kv#ORCH_FEATURE=}"; return 0 ;; esac
  done
  printf 'orch:run'
}

_cmux_ws_uuid() {  # _cmux_ws_uuid <title> -> workspace uuid, or empty
  cmux workspace list --id-format both 2>/dev/null \
    | grep -F " $1" | head -1 | grep -o "$_UUID_RE" | head -1
}

_cmux_alive() {  # _cmux_alive <surface-uuid>
  [ -n "$1" ] && cmux tree --all --id-format both 2>/dev/null | grep -q "$1"
}

# Map bookkeeping: name -> surface uuid -> workspace uuid -> workspace title.
# Pruned lazily: a dead pane is dropped the first time anything looks it up.
_cmux_map_get() {  # _cmux_map_get <name> -> "surface_uuid ws_uuid ws_title"
  local f line
  f="$(_cmux_map)"; [ -r "$f" ] || return 1
  line="$(grep "^$1	" "$f" 2>/dev/null | tail -1)" || true
  [ -n "$line" ] || return 1
  if ! _cmux_alive "$(printf '%s' "$line" | cut -f2)"; then
    grep -v "^$1	" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    return 1
  fi
  printf '%s %s %s' "$(printf '%s' "$line" | cut -f2)" \
                    "$(printf '%s' "$line" | cut -f3)" \
                    "$(printf '%s' "$line" | cut -f4)"
}

_cmux_map_put() {  # _cmux_map_put <name> <surface-uuid> <ws-uuid> <ws-title>
  local f; f="$(_cmux_map)"
  mkdir -p "$(dirname "$f")"
  { grep -v "^$1	" "$f" 2>/dev/null; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; } > "$f.tmp"
  mv "$f.tmp" "$f"
}

_cmux_map_del() {  # _cmux_map_del <name>
  local f; f="$(_cmux_map)"; [ -r "$f" ] || return 0
  grep -v "^$1	" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f"
}

orch_lnch_spawn() {  # <role> <name> <cwd> [KEY=VALUE...]
  local role="$1" name="$2" cwd="$3"; shift 3
  local wst wsuuid cmd kv envargs='' envprefix='' out suuid pane_count dir

  # A live pane under this name is a session already doing this job; a second
  # would fight it for the same tasks. rc=3 = present, not newly spawned.
  if _cmux_map_get "$name" >/dev/null; then
    printf '%s is already running; not spawning a second.\n' "$name" >&2
    return 3
  fi

  wst="$(_cmux_ws_title "$@")"
  wsuuid="$(_cmux_ws_uuid "$wst")"
  cmd="$(launcher_claude_cmd "$role" "$name")"

  if [ -z "$wsuuid" ]; then
    # First agent in: create the workspace around it. new-workspace does not
    # echo a UUID whatever --id-format says, so it is looked up by title.
    for kv in "$@"; do case "$kv" in *=*) envargs="$envargs --env $kv" ;; esac; done
    # shellcheck disable=SC2086 — envargs is deliberately word-split
    cmux new-workspace --name "$wst" --cwd "$cwd" $envargs --command "$cmd" >/dev/null 2>&1 \
      || { warn "cmux could not create workspace $wst"; return 1; }
    wsuuid="$(_cmux_ws_uuid "$wst")"
    [ -n "$wsuuid" ] || { warn "workspace $wst created but not found by title"; return 1; }
    suuid="$(cmux tree --workspace "$wsuuid" --id-format both 2>/dev/null \
      | grep 'surface surface:' | head -1 | grep -o "$_UUID_RE" | head -1)"
    [ -n "$suuid" ] || { warn "workspace $wst has no identifiable surface"; return 1; }
  else
    # Crew-mates tile into the existing workspace. Direction alternates so
    # four panes make a grid instead of four slivers in a row.
    pane_count="$(cmux tree --workspace "$wsuuid" 2>/dev/null | grep -c 'pane pane:')"
    dir='right'; [ "${pane_count:-1}" -gt 1 ] && dir='down'
    out="$(cmux new-split "$dir" --workspace "$wsuuid" --id-format both 2>/dev/null)" \
      || { warn "cmux could not split $wst for $name"; return 1; }
    suuid="$(printf '%s' "$out" | grep -o "$_UUID_RE" | head -1)"
    [ -n "$suuid" ] || { warn "split created in $wst but its surface has no uuid"; return 1; }
    # A split opens a plain shell: environment rides the command line.
    for kv in "$@"; do
      case "$kv" in *=*) envprefix="$envprefix${kv%%=*}=$(launcher_shq "${kv#*=}") " ;; esac
    done
    cmux send --surface "$suuid" "cd $(launcher_shq "$cwd") && ${envprefix}${cmd}" >/dev/null 2>&1 \
      || { warn "could not start $name in its pane"; return 1; }
  fi

  _cmux_map_put "$name" "$suuid" "$wsuuid" "$wst"
  printf 'spawned %s as a pane in cmux workspace `%s`\n' "$name" "$wst" >&2
  return 0
}

orch_lnch_kill() {  # <name>
  local hit suuid wsuuid
  hit="$(_cmux_map_get "$1")" || { warn "no live pane for $1"; return 1; }
  suuid="$(printf '%s' "$hit" | cut -d' ' -f1)"
  wsuuid="$(printf '%s' "$hit" | cut -d' ' -f2)"
  # cmux refuses to close a workspace's last surface (invalid_state), so the
  # final crew member takes the whole workspace with it — which is also the
  # right reading of what killing the last agent means.
  if [ "$(cmux tree --workspace "$wsuuid" 2>/dev/null | grep -c 'surface surface:')" -le 1 ]; then
    cmux close-workspace --workspace "$wsuuid" >/dev/null 2>&1 || return 1
  else
    cmux close-surface --surface "$suuid" --workspace "$wsuuid" >/dev/null 2>&1 || return 1
  fi
  _cmux_map_del "$1"
  printf 'closed %s\n' "$1" >&2
}

orch_lnch_peek() {  # <name> [lines]
  local hit
  hit="$(_cmux_map_get "$1")" || { warn "no live pane for $1"; return 1; }
  cmux read-screen --surface "$(printf '%s' "$hit" | cut -d' ' -f1)" \
    --scrollback --lines "${2:-60}" 2>/dev/null
}

orch_lnch_list() {
  local f name suuid rest
  f="$(_cmux_map)"; [ -r "$f" ] || return 0
  while IFS=$(printf '\t') read -r name suuid rest; do
    [ -n "$name" ] && _cmux_alive "$suuid" && printf '%s\n' "$name"
  done < "$f"
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
