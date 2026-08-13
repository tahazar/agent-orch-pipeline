#!/bin/bash
# install.sh - put orch on your PATH and wire it into a project.
#
# Two separate things, and it is worth knowing which you are doing:
#
#   the CLI       symlinked into ~/.local/bin once, machine-wide
#   the project   agent definitions and hook wiring, per repository
#
# Run it from the orch checkout to do both against the current directory, or
# point it at another repo:
#
#   ./install.sh                    install the CLI, wire up this repo
#   ./install.sh ~/code/my-project  install the CLI, wire up that repo
#   ./install.sh --cli-only         just the CLI
#
# Re-running is safe. Nothing here overwrites a file it did not write without
# saying so first.

set -u

HERE="$(cd -P "$(dirname "$0")" && pwd)"
BIN_DIR="${ORCH_BIN_DIR:-$HOME/.local/bin}"
ROLES="director tech-lead test-engineer developer code-reviewer auditor"

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'; fi
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %swarn%s %s\n' "$YEL" "$OFF" "$1"; }
die()  { printf '  %sfail%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

CLI_ONLY=0
TARGET=''
for a in "$@"; do
  case "$a" in
    --cli-only) CLI_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $a" ;;
    *) TARGET="$a" ;;
  esac
done

# ---------------------------------------------------------------------------
printf '\nprerequisites:\n'
# ---------------------------------------------------------------------------

for c in git jq; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required (brew install $c)"
  ok "$c"
done

if command -v claude >/dev/null 2>&1; then
  ok "claude $(claude --version 2>/dev/null | head -1)"
else
  die "claude is required — https://claude.com/claude-code"
fi

# cmux is optional, and the only thing that is. Without it sessions still run;
# you just cannot watch them.
if command -v cmux >/dev/null 2>&1; then
  ok "cmux — sessions will be persistent, named and watchable"
else
  warn "no cmux — sessions will run headless via 'claude --bg'."
  warn "     'orch peek' and 'orch kill' need cmux: https://github.com/manaflow-ai/cmux"
fi

case "$(uname -s)" in
  Darwin|Linux) ok "$(uname -s)" ;;
  *) die "$(uname -s) is unsupported — cross-session messaging is macOS and Linux only" ;;
esac

# ---------------------------------------------------------------------------
printf '\nthe CLI:\n'
# ---------------------------------------------------------------------------

mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
if [ -e "$BIN_DIR/orch" ] && [ ! -L "$BIN_DIR/orch" ]; then
  die "$BIN_DIR/orch exists and is not a symlink — move it aside first"
fi
ln -sf "$HERE/bin/orch" "$BIN_DIR/orch"
ok "orch -> $BIN_DIR/orch"

case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
  *)
    warn "$BIN_DIR is NOT on your PATH. Persist it where an interactive shell reads it:"
    warn "     echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && exec zsh"
    ;;
esac

[ "$CLI_ONLY" = "1" ] && { printf '\nDone (CLI only).\n\n'; exit 0; }

# ---------------------------------------------------------------------------
printf '\nthe project:\n'
# ---------------------------------------------------------------------------

REPO="$(cd -P "${TARGET:-$PWD}" 2>/dev/null && pwd)" || die "no such directory: $TARGET"
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "$REPO is not a git repository (orch scopes everything to a repo)"
REPO="$(git -C "$REPO" rev-parse --show-toplevel)"
ok "$REPO"

# Agent definitions. `claude --agent <name>` resolves from .claude/agents/, and
# when it cannot resolve a name the session comes up as a plain assistant with
# none of the role's tool restrictions — silently. That failure is why this is
# checked by `orch doctor` as well as done here.
mkdir -p "$REPO/.claude/agents" || die "could not create $REPO/.claude/agents"
for r in $ROLES; do
  src="$HERE/agents/$r.md"
  dst="$REPO/.claude/agents/$r.md"
  [ -r "$src" ] || die "missing role definition: $src"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    warn "$dst exists and is not a symlink — leaving your version alone"
    continue
  fi
  ln -sf "$src" "$dst"
done
ok "six role definitions in .claude/agents/"

# The hooks, same pattern. settings.json refers to
# $CLAUDE_PROJECT_DIR/.claude/orch-hooks/, which this symlink satisfies on each
# machine — so the committed settings stay portable while the hooks execute
# from this checkout. Pointing settings at $CLAUDE_PROJECT_DIR/hooks/ was the
# first-run bug this replaces: correct only when orch was installed into its
# own repository, and silently absent everywhere else, which is an enforcement
# layer that reports itself as wired and never fires.
if [ -e "$REPO/.claude/orch-hooks" ] && [ ! -L "$REPO/.claude/orch-hooks" ]; then
  die "$REPO/.claude/orch-hooks exists and is not a symlink — move it aside first"
fi
ln -sfn "$HERE/hooks" "$REPO/.claude/orch-hooks"
[ -x "$REPO/.claude/orch-hooks/gate-guard.sh" ] \
  || die ".claude/orch-hooks does not resolve to executable hooks — the enforcement layer would be silently absent"
ok "hooks reachable at .claude/orch-hooks/"

# Those symlinks point at wherever orch is checked out on THIS machine, so
# committing them hands the next person six dangling paths. settings.json is a
# different case: it refers to $CLAUDE_PROJECT_DIR, which Claude Code expands
# at hook time, so it is portable and worth committing.
if ! grep -qs '^agents/$' "$REPO/.claude/.gitignore" 2>/dev/null; then
  {
    printf "# Symlinks into this machine's orch checkout. Not portable.\n"
    printf 'agents/\norch-hooks\n'
    printf '# Settings we backed up before merging, and per-developer overrides.\n'
    printf '*.orch-backup\nsettings.local.json\n'
  } >> "$REPO/.claude/.gitignore"
fi
ok ".claude/.gitignore keeps the machine-specific symlinks out of git"

# Hook wiring. Merged rather than replaced: this file is the project's, not
# ours, and it usually has settings in it that have nothing to do with orch.
SETTINGS="$REPO/.claude/settings.json"
ORCH_SETTINGS="$HERE/settings.json"
if [ -e "$SETTINGS" ]; then
  jq -e . "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON — fix it first"
  cp "$SETTINGS" "$SETTINGS.orch-backup"
  merged="$(jq -s '
    .[0] as $existing | .[1] as $orch
    # Idempotent: strip every entry that is one of OURS before appending the
    # current set, so re-running the install replaces stale orch wiring (old
    # paths, superseded hooks) instead of stacking a second copy beside it.
    # The project'"'"'s own hooks are untouched — the filter matches our hook
    # basenames, nothing else.
    | ("(gate-guard|audit-message|write-scope|task-scope|artifact-scope|health-probe|task-guard)\\.sh$") as $ours
    | ($existing.hooks // {}
       | with_entries(.value = (.value
           | map(.hooks = (.hooks // [] | map(select((.command // "" | test($ours)) | not))))
           | map(select(.hooks | length > 0))))
       | with_entries(select(.value | length > 0))) as $clean
    | $existing
    | .hooks = (reduce ($orch.hooks | keys[]) as $ev ($clean;
        .[$ev] = (($clean[$ev] // []) + ($orch.hooks[$ev]))))
    | .crossSessionInbound = ($orch.crossSessionInbound)
  ' "$SETTINGS" "$ORCH_SETTINGS")" || die "could not merge settings"
  printf '%s\n' "$merged" > "$SETTINGS"
  ok "hooks merged into .claude/settings.json (backup: settings.json.orch-backup)"
else
  # $CLAUDE_PROJECT_DIR is expanded by Claude Code at hook time, so the file is
  # portable across checkouts and safe to commit.
  jq 'del(.["$comment"])' "$ORCH_SETTINGS" > "$SETTINGS" || die "could not write $SETTINGS"
  ok "wrote .claude/settings.json"
fi

jq -e . "$SETTINGS" >/dev/null 2>&1 || die "the merged settings are not valid JSON"
for h in gate-guard task-guard write-scope task-scope audit-message health-probe; do
  grep -q "$h.sh" "$SETTINGS" || warn "$h.sh is not wired in $SETTINGS"
done

# ---------------------------------------------------------------------------
printf '\nnext:\n\n'
# ---------------------------------------------------------------------------

cat <<EOF
  Every session in a team must share this, or they coordinate with nobody.
  Put it in your shell profile:

    export CLAUDE_CODE_TASK_LIST_ID=orch-$(basename "$REPO")

  Then, from $REPO:

    orch doctor                     check the install and the platform
    orch team start                 bring up the director and the auditor
    orch feature start F001-<slug>  begin a feature

EOF
