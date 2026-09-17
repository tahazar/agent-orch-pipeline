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

_UUID_RE='[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}'

# Workspace title for a spawn: the feature's crew tiles together; run-scoped
# roles (no ORCH_FEATURE in their env) share orch:run.
_cmux_ws_title() {  # _cmux_ws_title [KEY=VALUE...]
  local kv
  for kv in "$@"; do
    case "$kv" in ORCH_FEATURE=*) printf 'orch:%s' "${kv#ORCH_FEATURE=}"; return 0 ;; esac
  done
  printf 'orch:run'
}

# Every cmux call goes through here. The remote Linux shim reports an
# unknown command as "ERROR: ..." on stdout with exit 0, so an exit code
# proves nothing and `2>/dev/null || fallback` guards never fire — the
# version probe (#12) and workspace creation (#13) both half-missed that.
# Output is the verdict: error text is a failure, whatever the exit code.
_cmux_try() {  # _cmux_try <args...> -> stdout, rc 1 on failure or error text
  local out rc
  out="$(cmux "$@" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || return 1
  case "$out" in ERROR*|Error*|error:*|*"Unknown command"*|*"unknown command"*) return 1 ;; esac
  printf '%s\n' "$out"
}

# The first command form that answers. The native CLI and the shim name the
# same operations differently (workspace list / list-workspaces; tree /
# list-surfaces), so each lookup lists its forms and takes the first that
# is not an error.
_cmux_first() {  # _cmux_first "<form>" "<form>"...
  local f
  # shellcheck disable=SC2086 — each form is word-split on purpose
  for f in "$@"; do _cmux_try $f && return 0; done
  return 1
}

# An id from a line of cmux output: a UUID when there is one (native with
# --id-format both; the shim always), else the short ref (workspace:N,
# surface:N), else the shim's leading index ("2: ..." -> kind:2).
_cmux_id_in() {  # _cmux_id_in <kind> <text>
  local id
  id="$(printf '%s' "$2" | grep -o "$_UUID_RE" | head -1)"
  [ -n "$id" ] || id="$(printf '%s' "$2" | grep -oE "$1:[0-9]+" | head -1)"
  [ -n "$id" ] || id="$(printf '%s' "$2" | sed -n "s/^[[:space:]]*\*\{0,1\}[[:space:]]*\([0-9]\{1,\}\):.*/$1:\1/p")"
  printf '%s' "$id"
}

# A listing line with everything that is not the title removed: UUIDs and
# short refs (native), and the shim's "* 1: " index prefix and the "◆" it
# puts on the current workspace — seen live:
#   0: B2EEA155-... ~
#   * 1: 36FD19FE-... ◆ LasiAppCDK
#     2: CB65437A-... kiro-cli
_cmux_title_of() {  # stdin -> title
  sed -e "s/$_UUID_RE//g" -e 's/workspace:[0-9]*//g' -e 's/surface:[0-9]*//g' \
      -e 's/^[[:space:]]*\*[[:space:]]*//' -e 's/^[[:space:]]*[0-9]\{1,\}:[[:space:]]*//' \
      -e 's/◆//g' -e 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

_cmux_ws_list() {
  _cmux_first "workspace list --id-format both" "list-workspaces --id-format both" "list-workspaces" "workspace list"
}

# Workspace id by exact title: the line's text with its ids removed must be
# the title. A substring match found "--name orch:run" — the shim's own
# mis-titled workspace — when looking for "orch:run".
_cmux_ws_uuid() {  # _cmux_ws_uuid <title> -> workspace id, or empty
  local line rest
  _cmux_ws_list | while IFS= read -r line; do
    rest="$(printf '%s' "$line" | _cmux_title_of)"
    [ "$rest" = "$1" ] || continue
    _cmux_id_in workspace "$line"; printf '\n'; break
  done | head -1
}

# The tree of one workspace, or of everything, in whichever form answers.
_cmux_tree() {  # _cmux_tree [--workspace ID | --all]
  _cmux_first "tree $* --id-format both" "tree $*" "list-surfaces $* --id-format both" "list-surfaces $*" "list-panes $*" \
    || { [ "$#" -gt 0 ] && _cmux_first "list-surfaces" "list-panes"; }
}

# The surfaces of a workspace. The native tree names them ("surface
# surface:1 <uuid>"); the shim's listing is the same shape as its workspace
# listing, an index and an id per line. Lines that name a surface or pane
# win when there are any; otherwise every line that carries an id counts.
_cmux_surfaces_in() {  # _cmux_surfaces_in <workspace-id> -> one surface id per line
  local out lines line
  out="$(_cmux_tree --workspace "$1")"
  lines="$(printf '%s\n' "$out" | grep -iE 'surface|pane')"
  [ -n "$lines" ] || lines="$(printf '%s\n' "$out" | grep -E "$_UUID_RE|^[[:space:]]*\*?[[:space:]]*[0-9]+:")"
  printf '%s\n' "$lines" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    _cmux_id_in surface "$line"; printf '\n'
  done | grep .
}

_cmux_alive() {  # _cmux_alive <surface-id>
  [ -n "$1" ] && _cmux_tree --all | grep -qF "$1"
}

# Native CLI or the remote shim? The native CLI answers `workspace list`;
# the shim does not. Decided once per process.
_cmux_native() {
  if [ -z "${_CMUX_NATIVE:-}" ]; then
    if _cmux_try workspace list --id-format both >/dev/null; then _CMUX_NATIVE=1; else _CMUX_NATIVE=0; fi
  fi
  [ "$_CMUX_NATIVE" = 1 ]
}

# Typing into a pane. On the native CLI, `send --surface` and `send-key
# --surface` are verified. On the shim they are a trap: `send --surface
# <id> text` returns OK and types the whole argument list into whichever
# pane is FOCUSED — found live, with the director's command line sitting in
# the human's shell. The shim's targeted forms are send-surface and
# send-key-surface, and they want an id of their own (an index, not the
# UUID the listing shows), so the id is proved first with a harmless key:
# a form that answers "Surface not found" for the wrong id is one that can
# be trusted with the right one. No proof, no typing — the spawn refuses.
_cmux_shim_target() {  # _cmux_shim_target <ws-id> <surface-id> -> the id the shim accepts, or rc 1
  local line idx cand
  line="$(_cmux_tree --workspace "$1" | grep -F "$2" | head -1)"
  idx="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\*\{0,1\}[[:space:]]*\([0-9]\{1,\}\):.*/\1/p')"
  for cand in "$2" "$idx" "${idx:+surface:$idx}"; do
    [ -n "$cand" ] || continue
    _cmux_try send-key-surface "$cand" enter >/dev/null && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

_cmux_type() {  # _cmux_type <ws-id> <surface-id> <text>
  local t
  if _cmux_native; then _cmux_try send --surface "$2" "$3" >/dev/null; return $?; fi
  t="$(_cmux_shim_target "$1" "$2")" || return 1
  _cmux_try send-surface "$t" "$3" >/dev/null
}

_cmux_key() {  # _cmux_key <ws-id> <surface-id> <key>
  local t
  if _cmux_native; then _cmux_try send-key --surface "$2" "$3" >/dev/null; return $?; fi
  t="$(_cmux_shim_target "$1" "$2")" || return 1
  _cmux_try send-key-surface "$t" "$3" >/dev/null
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
  local wst wsuuid cmd kv envprefix='' out suuid pane_count dir stray

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
    # First agent in: create the workspace, by name and nothing else. The
    # native CLI takes --cwd, --env and --command here; the remote Linux
    # shim implements new_workspace with a name only, and given the flag
    # form it made a workspace titled with the whole argv and ran nothing —
    # found live, with `team start` reporting success over a director that
    # never launched. The pane starts as a plain shell either way, and the
    # command goes in the same way a crew-mate's does: typed, then Enter.
    # new-workspace echoes no UUID whatever --id-format says, so the
    # workspace is looked up by title; the flag form is tried first (native),
    # the positional form second (the shim).
    _cmux_try new-workspace --name "$wst" >/dev/null || true
    wsuuid="$(_cmux_ws_uuid "$wst")"
    if [ -z "$wsuuid" ]; then
      # The shim, given the flag form, makes a workspace titled with the
      # whole argv. Take that one back before trying its own form.
      stray="$(_cmux_ws_uuid "--name $wst")"
      [ -z "$stray" ] || _cmux_try close-workspace --workspace "$stray" >/dev/null || true
      _cmux_try new-workspace "$wst" >/dev/null || true
      wsuuid="$(_cmux_ws_uuid "$wst")"
    fi
    [ -n "$wsuuid" ] || { warn "cmux could not create workspace $wst, or created it under another title (cmux list-workspaces)"; return 1; }
    suuid="$(_cmux_surfaces_in "$wsuuid" | head -1)"
    [ -n "$suuid" ] || { warn "workspace $wst has no identifiable surface"; return 1; }
  else
    # Crew-mates tile into the existing workspace. Direction alternates so
    # four panes make a grid instead of four slivers in a row.
    pane_count="$(_cmux_surfaces_in "$wsuuid" | grep -c .)"
    dir='right'; [ "${pane_count:-1}" -gt 1 ] && dir='down'
    out="$(_cmux_first "new-split $dir --workspace $wsuuid --id-format both" "new-split $dir --workspace $wsuuid")" \
      || { warn "cmux could not split $wst for $name"; return 1; }
    suuid="$(_cmux_id_in surface "$out")"
    # A split that echoes no id is found as the newest surface in the tree.
    [ -n "$suuid" ] || suuid="$(_cmux_surfaces_in "$wsuuid" | tail -1)"
    [ -n "$suuid" ] || { warn "split created in $wst but its surface has no id"; return 1; }
  fi
  # Every pane opens as a plain shell: cwd and environment ride the command
  # line. send delivers text WITHOUT executing it — found live, when two crew
  # panes sat one keypress from starting while the roster showed only the
  # first agent. The Enter is its own call, and required.
  for kv in "$@"; do
    case "$kv" in *=*) envprefix="$envprefix${kv%%=*}=$(launcher_shq "${kv#*=}") " ;; esac
  done
  if ! _cmux_native && ! _cmux_shim_target "$wsuuid" "$suuid" >/dev/null; then
    warn "cmux cannot target $name's pane: this cmux is the remote shim and none of its send-surface id forms accepted the surface. Nothing was typed anywhere. Use ORCH_LAUNCHER=bg, or send \`cmux list-surfaces --workspace $wsuuid\` and a working \`cmux send-key-surface <id> enter\` upstream."
    return 1
  fi
  _cmux_type "$wsuuid" "$suuid" "cd $(launcher_shq "$cwd") && ${envprefix}${cmd}" \
    || { warn "could not start $name in its pane"; return 1; }
  _cmux_key "$wsuuid" "$suuid" enter \
    || { warn "typed $name's command but could not press enter — press it in the pane"; return 1; }

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
  if [ "$(_cmux_surfaces_in "$wsuuid" | grep -c .)" -le 1 ]; then
    _cmux_try close-workspace --workspace "$wsuuid" >/dev/null || return 1
  else
    _cmux_try close-surface --surface "$suuid" --workspace "$wsuuid" >/dev/null || return 1
  fi
  _cmux_map_del "$1"
  printf 'closed %s\n' "$1" >&2
}

orch_lnch_peek() {  # <name> [lines]
  local hit
  hit="$(_cmux_map_get "$1")" || { warn "no live pane for $1"; return 1; }
  _cmux_first "read-screen --surface $(printf '%s' "$hit" | cut -d' ' -f1) --scrollback --lines ${2:-60}" \
               "read-screen --surface $(printf '%s' "$hit" | cut -d' ' -f1)"
}

orch_lnch_list() {
  local f name suuid rest
  f="$(_cmux_map)"; [ -r "$f" ] || return 0
  while IFS=$(printf '\t') read -r name suuid rest; do
    [ -n "$name" ] && _cmux_alive "$suuid" && printf '%s\n' "$name"
  done < "$f"
}

orch_lnch_notify() {  # <title> <body>
  _cmux_try notify --title "$1" --body "${2:-}" >/dev/null
}

# No version probe: the remote Python shim has no `version` command and
# writes its "Unknown command" to stdout, which doctor then printed as the
# version. Reachable and the session list are what doctor decides on.
# A green launcher line must mean spawning can work, not that the socket
# answers ping: a title round-trip through the listing is what spawn needs,
# so the probe reports whether any listing form answers and parses.
orch_lnch_probe() {
  local ok=false ver='' listing=false titles=0
  if _cmux_try ping >/dev/null; then ok=true; fi
  if [ "$ok" = true ] && _cmux_ws_list >/dev/null 2>&1; then
    listing=true; titles="$(_cmux_ws_list | _cmux_title_of | grep -c .)"
  fi
  jq -n -c --arg launcher cmux --argjson reachable "$ok" --argjson listing "$listing" --argjson titles "${titles:-0}" \
    --argjson native "$([ "$ok" = true ] && _cmux_native && echo true || echo false)" --arg version "$ver" \
    --argjson sessions "$(orch_lnch_list | jq -R -s -c 'split("\n") | map(select(length>0))')" \
    '$ARGS.named'
}
