#!/bin/bash
# install.sh - install the Agent Orchestrator Pipeline on this machine.
#
#   - checks prerequisites (tmux >= 3.2, claude, jq; warns about gh)
#   - builds prompts and renders per-role settings
#   - symlinks `pipeline` into ~/.local/bin
#   - symlinks the pipeline-awareness skill into ~/.claude/skills

set -u

HERE="$(cd -P "$(dirname "$0")" && pwd)"
BIN_DIR="${PIPELINE_BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="${PIPELINE_SKILL_DIR:-$HOME/.claude/skills}"

problems=0

ok()    { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn()  { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; problems=$((problems + 1)); }

printf '\nAgent Orchestrator Pipeline - install\n\n'
printf 'Prerequisites:\n'

# --- tmux >= 3.2 ----------------------------------------------------------
if command -v tmux >/dev/null 2>&1; then
  raw="$(tmux -V 2>/dev/null | sed -e 's/^tmux //' -e 's/^next-//')"
  major="$(printf '%s' "$raw" | sed -e 's/[^0-9.].*$//' -e 's/\..*$//')"
  minor="$(printf '%s' "$raw" | sed -e 's/[^0-9.].*$//' -e 's/^[0-9]*\.//' -e 's/^$/0/')"
  if [ -n "$major" ] && { [ "$major" -gt 3 ] 2>/dev/null || \
     { [ "$major" -eq 3 ] 2>/dev/null && [ "$minor" -ge 2 ] 2>/dev/null; }; }; then
    ok "tmux $raw"
  else
    bad "tmux >= 3.2 required (found $raw). On macOS: brew install tmux"
  fi
else
  bad "tmux not found. On macOS: brew install tmux"
fi

# --- claude ---------------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
  ok "claude $(claude --version 2>/dev/null | head -1)"
else
  bad "claude CLI not found - see https://claude.com/claude-code"
fi

# --- jq -------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  ok "jq $(jq --version 2>/dev/null)"
else
  bad "jq not found. On macOS: brew install jq"
fi

# --- gh (only needed to open the final PR in normal mode) -----------------
if command -v gh >/dev/null 2>&1; then
  ok "gh $(gh --version 2>/dev/null | head -1)"
else
  warn "gh not found - test mode works without it, but normal mode cannot open the final PR. On macOS: brew install gh"
fi

if [ "$problems" != "0" ]; then
  printf '\n%s prerequisite problem(s); fix them and re-run.\n\n' "$problems"
  exit 1
fi

# --- build ----------------------------------------------------------------
printf '\nBuilding prompts and settings:\n'
if bash "$HERE/build-prompts.sh" > /tmp/pipeline-install-build.$$ 2>&1; then
  sed 's/^/  /' /tmp/pipeline-install-build.$$
  rm -f /tmp/pipeline-install-build.$$
else
  sed 's/^/  /' /tmp/pipeline-install-build.$$
  rm -f /tmp/pipeline-install-build.$$
  printf '\nbuild-prompts.sh failed; aborting.\n\n'
  exit 1
fi

# A settings file that fails validation is silently ignored by the CLI in some
# modes. That would drop the permission allowlist, and every `pipeline tell`
# would then land behind a permission dialog that swallows it. Verify here too.
printf '\nValidating settings:\n'
for f in "$HERE"/settings/role-*.json; do
  [ -f "$f" ] || continue
  if jq -e . "$f" >/dev/null 2>&1; then
    ok "$(basename "$f")"
  else
    bad "$(basename "$f") is not valid JSON"
  fi
done
[ "$problems" = "0" ] || { printf '\nAborting.\n\n'; exit 1; }

# --- link the CLI ---------------------------------------------------------
printf '\nInstalling:\n'
mkdir -p "$BIN_DIR" || { printf '  cannot create %s\n' "$BIN_DIR"; exit 1; }
chmod +x "$HERE/pipeline" "$HERE/hooks/"*.sh 2>/dev/null || true
ln -sf "$HERE/pipeline" "$BIN_DIR/pipeline"
ok "pipeline -> $BIN_DIR/pipeline"

case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on PATH" ;;
  *) warn "$BIN_DIR is NOT on PATH - add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# --- link the skill -------------------------------------------------------
if [ -d "$HERE/skills/pipeline-awareness" ]; then
  mkdir -p "$SKILL_DIR" 2>/dev/null || true
  if ln -sfn "$HERE/skills/pipeline-awareness" "$SKILL_DIR/pipeline-awareness" 2>/dev/null; then
    ok "pipeline-awareness skill -> $SKILL_DIR/pipeline-awareness"
  else
    warn "could not link the pipeline-awareness skill into $SKILL_DIR"
  fi
fi

printf '\nDone.\n\n'
printf 'Next:\n'
printf '  1. cd into your project and check out a working branch (NOT main)\n'
printf '  2. put your design at docs/specs/<name>.md\n'
printf '  3. pipeline start --session <name> --agents "orch,principal"\n'
printf '  4. pipeline tell orch "Build docs/specs/<name>.md. [SIGNAL:KICKOFF]"\n\n'
