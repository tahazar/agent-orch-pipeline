#!/bin/bash
# doctor.sh - the operational constraints, checked rather than documented.
#
# Every check here corresponds to a §1 constraint that will silently break
# coordination rather than fail loudly:
#
#   same filesystem          a peer in a container cannot reach the host
#   permission-mode class    messages across mismatched classes are HELD and
#                            dropped after dialogExpiry (default 5m), so
#                            coordination expires instead of erroring
#   crossSessionInbound      must be `accept` for the team
#   socket presence          0600 per-session Unix socket
#   task-list agreement      two sessions coordinate only if they share
#                            CLAUDE_CODE_TASK_LIST_ID
#   worktree support         rung 3 is unavailable without it
#   PID 1 in a container     socket ownership cannot be verified at all, so
#                            messages are treated as untrusted
#
# doctor never mutates anything. It exits non-zero when a FAIL is present so it
# can gate CI.

[ -n "${ORCH_DOCTOR_SOURCED:-}" ] && return 0
ORCH_DOCTOR_SOURCED=1

# shellcheck source=substrate/base.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/substrate/base.sh"

_D_FAIL=0
_D_WARN=0
_d_ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
_d_warn() { _D_WARN=$((_D_WARN + 1)); printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
_d_bad()  { _D_FAIL=$((_D_FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }

doctor_run() {
  local p cli peers n_peers classes n_classes csi expiry

  if [ "${ORCH_NO_COLOR:-0}" = "1" ] || [ ! -t 1 ]; then
    _d_ok()   { printf '  ok    %s\n' "$*"; }
    _d_warn() { _D_WARN=$((_D_WARN + 1)); printf '  warn  %s\n' "$*"; }
    _d_bad()  { _D_FAIL=$((_D_FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
  fi

  printf 'orch doctor — substrate: %s\n\n' "$(substrate_name)"
  p="$(substrate_probe)"
  if ! printf '%s' "$p" | jq -e 'type=="object"' >/dev/null 2>&1; then
    _d_bad "substrate probe returned nothing usable"
    return 1
  fi

  # --- toolchain ----------------------------------------------------------
  printf 'toolchain:\n'
  for c in git jq; do
    if have "$c"; then _d_ok "$c present"; else _d_bad "$c not found — orch cannot run without it"; fi
  done
  have flock || _d_warn "flock(1) absent (expected on macOS) — orch falls back to an O_EXCL directory lock, which interlocks orch processes but not the CLI's own writer; task ids are still allocated race-free"

  cli="$(printf '%s' "$p" | jq -r '.cli // ""')"
  if [ -z "$cli" ]; then
    _d_warn "could not read \`claude --version\` — roster and messaging checks will be incomplete"
  elif [ "$cli" = "$(printf '%s' "$p" | jq -r '.cli_verified')" ]; then
    _d_ok "claude $cli (the version orch's substrate facts were verified against)"
  else
    _d_warn "claude $cli, but orch's substrate facts were verified on $(printf '%s' "$p" | jq -r '.cli_verified') — re-verify §1 and [P35] before trusting them"
  fi

  # --- coordination state -------------------------------------------------
  printf '\ncoordination:\n'
  if [ "$(printf '%s' "$p" | jq -r '.task_list_env')" = "true" ]; then
    _d_ok "CLAUDE_CODE_TASK_LIST_ID=$(printf '%s' "$p" | jq -r '.task_list_id')"
  else
    _d_bad "CLAUDE_CODE_TASK_LIST_ID is not set — this session has a private task list and coordinates with nobody. Export: CLAUDE_CODE_TASK_LIST_ID=$(printf '%s' "$p" | jq -r '.task_list_id')"
  fi
  if [ "$(printf '%s' "$p" | jq -r '.task_list_exists')" = "true" ]; then
    _d_ok "task list at $(printf '%s' "$p" | jq -r '.task_list_dir')"
    [ "$(printf '%s' "$p" | jq -r '.lock_present')" = "true" ] \
      && _d_ok "first-party .lock present" \
      || _d_warn "no .lock in the task list yet — it appears on the CLI's first write"
  else
    _d_warn "task list directory does not exist yet — created on first write"
  fi

  # --- peers --------------------------------------------------------------
  printf '\npeers:\n'
  peers="$(printf '%s' "$p" | jq -c '.peers // []')"
  n_peers="$(printf '%s' "$peers" | jq 'length')"
  if [ "${n_peers:-0}" = "0" ]; then
    _d_warn "no live sessions in the roster — nothing to coordinate with yet"
  else
    printf '%s' "$peers" | jq -r '.[] | "  •     \(.name // .sessionId) pid=\(.pid) class=\(.permission_class) cwd=\(.cwd)"'
    # same filesystem
    if [ "$(printf '%s' "$peers" | jq '[.[] | select(.cwd_present | not)] | length')" != "0" ]; then
      _d_bad "$(printf '%s' "$peers" | jq -r '[.[] | select(.cwd_present | not) | .name] | join(", ")') report a cwd this machine cannot see — sessions must share a filesystem; a container cannot reach the host"
    else
      _d_ok "every peer's cwd is reachable from here"
    fi
    if [ "$(printf '%s' "$peers" | jq '[.[] | select(.socket_present | not)] | length')" != "0" ]; then
      _d_bad "$(printf '%s' "$peers" | jq -r '[.[] | select(.socket_present | not) | .name] | join(", ")') have no messaging socket under $(printf '%s' "$p" | jq -r '.socket_dir') — SendMessage cannot reach them"
    else
      _d_ok "every peer has a messaging socket"
    fi
    # permission-mode class
    classes="$(printf '%s' "$peers" | jq -r '[.[] | .permission_class] | unique | map(select(. != "unknown")) | join(",")')"
    n_classes="$(printf '%s' "$peers" | jq '[.[] | .permission_class] | unique | map(select(. != "unknown")) | length')"
    if [ "${n_classes:-0}" -gt 1 ]; then
      _d_bad "mixed permission-mode classes across sessions ($classes) — messages between them are HELD for approval and DROPPED after dialogExpiry, so coordination expires silently instead of failing"
    elif [ "${n_classes:-0}" = "1" ]; then
      _d_ok "all sessions share one permission-mode class ($classes)"
    else
      _d_warn "could not read any session's permission-mode class from its process arguments — cannot verify they match"
    fi
    if [ "$(printf '%s' "$peers" | jq '[.[] | select(.permission_class=="unknown")] | length')" != "0" ]; then
      _d_warn "$(printf '%s' "$peers" | jq -r '[.[] | select(.permission_class=="unknown") | .name] | join(", ")') — permission class unreadable (ps restricted or a different user)"
    fi
  fi

  # --- messaging settings -------------------------------------------------
  printf '\nmessaging:\n'
  csi="$(printf '%s' "$p" | jq -r '.cross_session_inbound // ""')"
  case "$csi" in
    accept) _d_ok "crossSessionInbound=accept" ;;
    '')     _d_warn "crossSessionInbound is unset — set it to \"accept\" in .claude/settings.json for the orchestrator team, or inbound messages get parked behind a prompt" ;;
    *)      _d_bad "crossSessionInbound=$csi — inbound coordination will be held or refused; set it to \"accept\"" ;;
  esac
  expiry="$(printf '%s' "$p" | jq -r '.dialog_expiry // ""')"
  [ -n "$expiry" ] && _d_ok "dialogExpiry=$expiry" \
    || _d_ok "dialogExpiry unset (default 5m — a held message is dropped after that)"
  if [ "$(printf '%s' "$p" | jq -r '.self_socket_present')" = "true" ]; then
    _d_ok "this session's socket is live"
  else
    _d_warn "CLAUDE_CODE_MESSAGING_SOCKET is not a live socket here — expected outside a Claude session"
  fi

  # --- platform -----------------------------------------------------------
  printf '\nplatform:\n'
  case "$(uname -s)" in
    Darwin) _d_ok "macOS — socket ownership is verified only while the posting child process lives, so a hook that posts must not exit before delivery completes" ;;
    Linux)  _d_ok "Linux — socket ownership verification survives the posting process exiting" ;;
    *)      _d_bad "$(uname -s) is unsupported; cross-session messaging is macOS and Linux only" ;;
  esac
  if [ "$(printf '%s' "$p" | jq -r '.containerized')" = "true" ]; then
    if [ "$(printf '%s' "$p" | jq -r '.pid1')" = "true" ]; then
      _d_bad "running as PID 1 in a container — socket ownership cannot be verified at all and messages are treated as untrusted"
    else
      _d_warn "containerized — sessions outside this container share no filesystem and cannot be coordinated with"
    fi
  fi
  [ "$(printf '%s' "$p" | jq -r '.worktree_ok')" = "true" ] \
    && _d_ok "git worktrees available (rung 3 needs them)" \
    || _d_bad "git worktree is unavailable — best-of-N cannot isolate candidates, so rung 3 must not run"

  # --- launcher -----------------------------------------------------------
  printf '\nlauncher:\n'
  . "$ORCH_HOME/lib/launcher/base.sh"
  lp="$(launcher_probe 2>/dev/null)"
  lname="$(printf '%s' "$lp" | jq -r '.launcher // "?"')"
  case "$lname" in
    cmux)
      if [ "$(printf '%s' "$lp" | jq -r '.reachable')" = "true" ]; then
        _d_ok "cmux — sessions are persistent, named, and watchable ($(printf '%s' "$lp" | jq -r '.version'))"
      else
        _d_bad "cmux is on PATH but its socket is not answering; \`orch spawn\` will fail. Start cmux, or set ORCH_LAUNCHER=bg"
      fi
      ;;
    bg)
      _d_warn "no cmux — falling back to \`claude --bg\`. Sessions run headless: \`orch peek\` cannot show you one and \`orch kill\` cannot stop one"
      ;;
    print)
      _d_warn "no cmux and no claude on PATH — \`orch spawn\` will print commands rather than run them"
      ;;
  esac
  # Agent definitions have to be installed where the CLI looks for them, or
  # --agent resolves to nothing and the session comes up as a plain assistant
  # with none of the role's tool restrictions. That failure is silent, which is
  # why it is checked here rather than discovered mid-run.
  missing=''
  for r in director tech-lead test-engineer developer code-reviewer auditor; do
    [ -r "$ORCH_REPO/.claude/agents/$r.md" ] || missing="$missing $r"
  done
  if [ -z "$missing" ]; then
    _d_ok "all six role definitions are installed in .claude/agents/"
  else
    _d_bad "not installed in .claude/agents/:$missing — \`claude --agent\` cannot resolve them and the session silently comes up unroled. Run ./install.sh"
  fi

  printf '\n%s failed, %s warned.\n' "$_D_FAIL" "$_D_WARN"
  [ "$_D_FAIL" = "0" ]
}
