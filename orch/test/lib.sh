#!/bin/bash
# lib.sh - shared harness for the orch test suite.
#
# Every test runs against a throwaway git repo and a throwaway task-list root,
# so the suite never touches ~/.claude and never leaves branches behind. No
# Claude session is required: these prove the protocol and the CLI, not a
# model's adherence to the prompts.

set -u

TEST_HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_ROOT="$(cd -P "$TEST_HERE/.." && pwd)"
REPO_ROOT="$(cd -P "$ORCH_ROOT/.." && pwd)"
ORCH="$ORCH_ROOT/bin/orch"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

# chk_rc <expected> <actual> <label>
chk_rc() {
  if [ "$1" = "$2" ]; then ok "$3 (rc=$2)"; else bad "$3 (expected rc=$1, got $2)"; fi
}

# contains <haystack> <needle> <label>
contains() {
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — output lacked '$2'" ;; esac
}

# not_contains <haystack> <needle> <label>
not_contains() {
  case "$1" in *"$2"*) bad "$3 — output unexpectedly contained '$2'" ;; *) ok "$3" ;; esac
}

WORK=''
setup_repo() {  # setup_repo [name]
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/orch-test-${1:-x}.XXXXXX")"
  # Pin the session id so ledger rows are deterministic. Without this the suite
  # behaves differently depending on whether it happens to be running inside a
  # Claude session, which is exactly the kind of environment dependence a test
  # suite must not have.
  export CLAUDE_CODE_SESSION_ID="orch-test-session"
  export ORCH_TASKS_ROOT="$WORK/.tasks"
  export CLAUDE_CODE_TASK_LIST_ID="orch-test-$$"
  export ORCH_REPO="$WORK/repo"
  export CLAUDE_PROJECT_DIR="$WORK/repo"
  export ORCH_BASE_BRANCH=main
  mkdir -p "$ORCH_REPO/src" "$ORCH_REPO/test"
  cd "$ORCH_REPO" || exit 1
  git init -q .
  git config user.email orch@example.com
  git config user.name "orch test"
  git config commit.gpgsign false
  printf '# fixture\n' > README.md
  printf 'def add(a, b):\n    return a + b\n' > src/calc.py
  printf 'from src.calc import add\n\n\ndef test_add():\n    assert add(1, 2) == 3\n' > test/test_calc.py
  git add -A && git commit -q -m "initial"
  git branch -M main
  PATH="$ORCH_ROOT/bin:$PATH"; export PATH
}

teardown_repo() {
  [ -n "$WORK" ] || return 0
  if [ -d "$ORCH_REPO" ]; then
    git -C "$ORCH_REPO" worktree list --porcelain 2>/dev/null \
      | sed -n 's/^worktree //p' | while IFS= read -r w; do
          [ "$w" = "$ORCH_REPO" ] && continue
          git -C "$ORCH_REPO" worktree remove --force "$w" 2>/dev/null || true
        done
  fi
  cd /
  [ "${KEEP_WORK:-0}" = "1" ] || rm -rf "$WORK"
}

finish() {  # finish <suite-name>
  printf '\n%s: %s passed, %s failed\n' "$1" "$PASS" "$FAIL"
  [ "$FAIL" = "0" ]
}
