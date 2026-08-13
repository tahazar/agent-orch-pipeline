#!/bin/bash
# base.sh - the launcher seam.
#
# Coordination has a seam (lib/substrate/) because the platform's messaging and
# task-list internals move. Session *lifecycle* needs one for a different
# reason: how you start a session is a property of the terminal you live in,
# not of the pipeline. cmux, a bare shell, and a headless CI runner all want
# different answers, and none of them should be able to reach into orch.
#
#   launcher_spawn <role> <name> <cwd> [KEY=VALUE...]  -> start a session
#   launcher_kill <name>                               -> stop it
#   launcher_peek <name> [lines]                       -> read its screen
#   launcher_list                                      -> what this launcher started
#   launcher_notify <title> <body>                     -> tell the human
#   launcher_probe                                     -> JSON, for `orch doctor`
#
# Every implementation is best-effort on notify and peek, and honest about it:
# a launcher that cannot show you a screen says so rather than returning empty
# output that reads like a quiet agent.
#
# What is NOT in here: anything that decides *whether* to spawn. The crew comes
# from lib/tier.sh, the gate from a confirmed tier. A launcher only launches.

[ -n "${ORCH_LAUNCHER_SOURCED:-}" ] && return 0
ORCH_LAUNCHER_SOURCED=1

# shellcheck source=../common.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
# shellcheck source=../ledger.sh
. "$ORCH_HOME/lib/ledger.sh"

# Every session in a team must share a permission-mode class or messages
# between them are held and then silently dropped after dialogExpiry. One
# setting, applied to every spawn, is the only way to guarantee that — which is
# why this is a single variable and not a per-role field.
: "${ORCH_PERMISSION_MODE:=acceptEdits}"

# Auto-detect, overridable. cmux wins when present because it is the only one
# that gives you a watchable, persistent, addressable session.
if [ -z "${ORCH_LAUNCHER:-}" ]; then
  if [ -n "${CMUX_SOCKET_PATH:-}${CMUX_SESSION:-}" ] && have cmux; then ORCH_LAUNCHER=cmux
  elif have cmux;   then ORCH_LAUNCHER=cmux
  elif have claude; then ORCH_LAUNCHER=bg
  else ORCH_LAUNCHER=print
  fi
fi

# ---------------------------------------------------------------------------
# Shared: what a role's session actually is
# ---------------------------------------------------------------------------

# The settings file a role launches with. The hook wiring lives in the
# project's .claude/settings.json (installed once, loaded automatically), so
# this is only the per-role permission set — `claude --settings` is documented
# as taking one file, and depending on it accepting two is the kind of
# assumption that works until it doesn't.
launcher_role_settings() {  # launcher_role_settings <role>
  case "$1" in
    director) printf '%s/settings/role-director.json' "$ORCH_HOME" ;;
    *)        printf '%s/settings/role-crew.json' "$ORCH_HOME" ;;
  esac
}

launcher_known_role() {  # launcher_known_role <role>
  [ -r "$ORCH_HOME/agents/$1.md" ]
}

# The command a session runs. Single-quoted for the shell it will be pasted or
# sent into, so a repo path with a space does not silently split.
launcher_claude_cmd() {  # launcher_claude_cmd <role> <name>
  printf "claude --agent %s -n %s --permission-mode %s --settings '%s'" \
    "$1" "$2" "$ORCH_PERMISSION_MODE" "$(launcher_role_settings "$1")"
}

# The environment every session in the team must share. Emitted as KEY=VALUE
# lines so each implementation can pass them in whatever form it needs.
launcher_env() {  # launcher_env <role> [feature] [extra KEY=VALUE...]
  local role="$1" feature="${2:-}"; shift 2 2>/dev/null || shift $#
  printf 'ORCH_ROLE=%s\n' "$role"
  [ -n "$feature" ] && printf 'ORCH_FEATURE=%s\n' "$feature"
  printf 'ORCH_HOME=%s\n' "$ORCH_HOME"
  printf 'CLAUDE_PROJECT_DIR=%s\n' "${ORCH_REPO:-$(orch_repo_root)}"
  # Propagated, not queried. Which task list a team shares is the team's
  # environment, and the launcher has no business asking the substrate about
  # it — it only has to make sure every session it starts inherits the same
  # value. The default matches what `orch init` prints.
  printf 'CLAUDE_CODE_TASK_LIST_ID=%s\n' \
    "${CLAUDE_CODE_TASK_LIST_ID:-orch-$(basename "${ORCH_REPO:-$(orch_repo_root)}")}"
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1"; shift; done
}

# The session name for a role. Best-of-N is the only case that needs more than
# one session of the same role alive at once, so the suffix is explicit rather
# than always-on: `developer` reads better than `developer-1` in a tab strip.
launcher_session_name() {  # launcher_session_name <role> [suffix]
  if [ -n "${2:-}" ]; then printf '%s-%s' "$1" "$2"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------------------

case "$ORCH_LAUNCHER" in
  cmux)  . "$ORCH_HOME/lib/launcher/cmux.sh" ;;
  bg)    . "$ORCH_HOME/lib/launcher/bg.sh" ;;
  print) . "$ORCH_HOME/lib/launcher/print.sh" ;;
  *) die "unknown ORCH_LAUNCHER '$ORCH_LAUNCHER' (expected: cmux, bg, print)" ;;
esac

for _op in spawn kill peek list notify probe; do
  if ! declare -f "orch_lnch_$_op" >/dev/null 2>&1; then
    die "launcher '$ORCH_LAUNCHER' does not implement $_op"
  fi
done
unset _op

launcher_name()   { printf '%s' "$ORCH_LAUNCHER"; }
launcher_kill()   { orch_lnch_kill "$@"; }
launcher_peek()   { orch_lnch_peek "$@"; }
launcher_list()   { orch_lnch_list "$@"; }
launcher_notify() { orch_lnch_notify "$@" 2>/dev/null || true; }
launcher_probe()  { orch_lnch_probe "$@"; }

# launcher_spawn <role> <name> <cwd> [KEY=VALUE...]
#
# Logged either way. A spawn that failed is more interesting than one that
# worked, so the ledger records the outcome rather than the intent.
launcher_spawn() {
  local role="$1" name="$2" cwd="$3"; shift 3
  launcher_known_role "$role" || die "spawn: no such role '$role' (agents/$role.md does not exist)"
  [ -d "$cwd" ] || die "spawn: '$cwd' is not a directory"
  if orch_lnch_spawn "$role" "$name" "$cwd" "$@"; then
    # The print launcher starts nothing, so recording a spawn would put a
    # session in the ledger that does not exist — and `orch report` would then
    # attribute a feature's cost to an agent nobody ever ran.
    if [ "$ORCH_LAUNCHER" = "print" ]; then
      ledger_append agent.printed role "$role" name "$name" cwd "$cwd"
    else
      ledger_append agent.spawned role "$role" name "$name" launcher "$ORCH_LAUNCHER" cwd "$cwd"
    fi
    return 0
  fi
  ledger_append agent.spawn_failed role "$role" name "$name" launcher "$ORCH_LAUNCHER"
  return 1
}
