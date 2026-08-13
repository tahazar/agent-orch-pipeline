#!/bin/bash
# common.sh - shared helpers for orch.
#
# Portability: must run under macOS stock /bin/bash 3.2.
#   - no associative arrays, no mapfile/readarray, no ${var,,}
#   - no `readlink -f`, no GNU `sed -i`
# Dependencies: jq, git.
#
# Sourced by bin/orch, by every lib/*.sh, and by every hooks/*.sh. Hooks are
# spawned by Claude Code with an unpredictable cwd and a minimal environment,
# so nothing here may assume the repo root is the working directory.

[ -n "${ORCH_COMMON_SOURCED:-}" ] && return 0
ORCH_COMMON_SOURCED=1

ORCH_VERSION="2.0.0"

# Substrate facts this build was verified against. `orch doctor` compares the
# installed CLI to this and warns on drift; see docs/PROVENANCE.md [P35].
ORCH_VERIFIED_CLI="2.1.228"

: "${ORCH_PROG:=orch}"

die()  { printf '%s: %s\n' "$ORCH_PROG" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "$ORCH_PROG" "$*" >&2; }
note() { [ "${ORCH_QUIET:-0}" = "1" ] || printf '%s\n' "$*" >&2; }

now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() { have "$1" || die "required command not found: $1"; }

# Resolve the directory a script lives in, following symlinks, without
# `readlink -f` (absent on macOS).
orch_resolve_dir() {
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  ( cd -P "$(dirname "$src")" && pwd )
}

# ORCH_HOME is where orch itself is installed — the directory holding bin/,
# lib/, agents/ and hooks/. Usually the repo root, but not necessarily: orch can
# be installed anywhere and pointed at a different repo via ORCH_REPO.
if [ -z "${ORCH_HOME:-}" ]; then
  ORCH_HOME="$(cd -P "$(orch_resolve_dir "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export ORCH_HOME

# ---------------------------------------------------------------------------
# Repo
# ---------------------------------------------------------------------------

# The repo orch operates on.
#
# Order matters, and it is not the obvious one. git's own idea of the working
# tree comes BEFORE CLAUDE_PROJECT_DIR, because a developer at rung 3 runs inside
# a worktree while CLAUDE_PROJECT_DIR still points at the main checkout. Taking
# the env var first would send that candidate's evidence to the main checkout —
# which the platform blocks it from writing to, so the attestation would simply
# vanish and every gate would read as unattested.
#
# CLAUDE_PROJECT_DIR remains the fallback for hooks, which Claude Code can spawn
# with a cwd outside any repository.
orch_repo_root() {
  local top
  if [ -n "${ORCH_REPO:-}" ]; then printf '%s' "$ORCH_REPO"; return 0; fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then printf '%s' "$top"; return 0; fi
  # A worktree's .git is a file, not a directory, so test for either.
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -e "$CLAUDE_PROJECT_DIR/.git" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"; return 0
  fi
  printf ''
}

# Physical path of an existing file or directory, symlinks resolved.
#
# macOS makes this necessary rather than pedantic: /var is a symlink to
# /private/var, so `git rev-parse --show-toplevel` returns the resolved form
# while $TMPDIR and most tool inputs carry the unresolved one. Comparing those
# two as strings fails silently — and in hooks/write-scope.sh a failed prefix
# strip means refusing a write the role is entitled to make, on macOS only.
#
# No `readlink -f`: it does not exist there either.
orch_realpath() {
  local p="$1" d b
  [ -n "$p" ] || { printf ''; return 0; }
  if [ -d "$p" ]; then
    ( cd -P "$p" 2>/dev/null && pwd ) || printf '%s' "$p"
    return 0
  fi
  d="$(dirname "$p")"; b="$(basename "$p")"
  d="$( cd -P "$d" 2>/dev/null && pwd )"
  if [ -n "$d" ]; then printf '%s/%s' "$d" "$b"; else printf '%s' "$p"; fi
}

orch_require_repo() {
  ORCH_REPO="$(orch_repo_root)"
  [ -n "$ORCH_REPO" ] || die "not inside a git repository (set ORCH_REPO)"
  export ORCH_REPO
}

# HEAD sha of the repo, or the literal "unknown" when there is no commit yet.
# Gates bind to a sha, so a missing one must not silently become the empty
# string and compare equal to another missing one.
orch_head_sha() {
  local sha
  sha="$(git -C "${ORCH_REPO:-$(orch_repo_root)}" rev-parse HEAD 2>/dev/null)"
  printf '%s' "${sha:-unknown}"
}

# Feature slug: F001-parser style. Validated because it becomes a path.
orch_valid_feature() {
  case "$1" in
    ''|*/*|*..*) return 1 ;;
    F[0-9][0-9][0-9]*) return 0 ;;
    _orch) return 0 ;;
    *) return 1 ;;
  esac
}

orch_feature_dir() {  # orch_feature_dir <feature>
  printf '%s/docs/features/%s' "${ORCH_REPO:-$(orch_repo_root)}" "$1"
}

# The feature a hook should attribute an event to. Hooks get no arguments, so
# this is the only way they can find one.
orch_current_feature() {
  if [ -n "${ORCH_FEATURE:-}" ]; then printf '%s' "$ORCH_FEATURE"; return 0; fi
  local f state
  state="${ORCH_REPO:-$(orch_repo_root)}/.orch/current-feature"
  if [ -r "$state" ]; then
    f="$(head -1 "$state" 2>/dev/null | tr -d ' \t\r\n')"
    if orch_valid_feature "$f"; then printf '%s' "$f"; return 0; fi
  fi
  printf '_orch'
}

orch_set_current_feature() {  # orch_set_current_feature <feature>
  orch_valid_feature "$1" || die "invalid feature name: $1"
  mkdir -p "${ORCH_REPO}/.orch"
  printf '%s\n' "$1" > "${ORCH_REPO}/.orch/current-feature"
}

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

# Build a JSON object from alternating key/value arguments. Values are always
# emitted as strings; use orch_json_raw for numbers and nested objects.
#
#   orch_json ts "$(now_iso)" kind gate exit_code:raw 0
#
# A key suffixed with `:raw` has its value spliced in verbatim.
orch_json() {
  local out='{}' k v
  while [ "$#" -gt 0 ]; do
    k="$1"; v="${2-}"; shift 2 2>/dev/null || shift
    case "$k" in
      *:raw)
        k="${k%:raw}"
        out="$(printf '%s' "$out" | jq -c --arg k "$k" --argjson v "${v:-null}" '.[$k]=$v')" ;;
      *)
        out="$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" '.[$k]=$v')" ;;
    esac
  done
  printf '%s' "$out"
}

# Read a dotted path out of a JSON document on stdin, empty string if absent.
orch_jget() { jq -r --arg p "$1" 'getpath($p|split(".")) // "" | if type=="string" then . else tojson end' 2>/dev/null; }

# Append one JSON object as a line to a file, creating parents. Uses O_APPEND,
# which is atomic for writes under PIPE_BUF on every filesystem we support, so
# concurrent agents appending to the same ledger do not interleave.
orch_append_jsonl() {  # orch_append_jsonl <file> <json>
  local f="$1" line="$2"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf '%s\n' "$line" >> "$f"
}

# sha256 of stdin, portable across coreutils and macOS.
orch_sha256() {
  if have sha256sum; then sha256sum | cut -d' ' -f1
  elif have shasum;    then shasum -a 256 | cut -d' ' -f1
  else die "no sha256 tool found (need sha256sum or shasum)"; fi
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

# Run a command with an exclusive lock held on <lockfile>.
#
# Claude Code's shared task list carries its own `.lock`, and we take it where
# the platform lets us: flock(1) exists on Linux and gives us the same advisory
# lock the CLI holds. macOS ships no flock(1), so there we fall back to an
# O_EXCL directory lock, which interlocks orch processes with each other but
# NOT with the CLI's own writer. That gap is why orch never allocates task ids
# by scanning-then-writing - see substrate/messaging.sh, which allocates with
# O_EXCL create and retries on collision, and so is race-free either way.
orch_with_lock() {  # orch_with_lock <lockfile> <cmd...>
  local lock="$1"; shift
  mkdir -p "$(dirname "$lock")"
  if have flock; then
    ( : > "$lock" 2>/dev/null || true
      exec 9>>"$lock" || exit 1
      flock -w "${ORCH_LOCK_TIMEOUT:-10}" 9 || { printf 'orch: lock timeout on %s\n' "$lock" >&2; exit 75; }
      "$@" )
    return $?
  fi
  local d="${lock}.d" waited=0
  while ! mkdir "$d" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -gt "$(( ${ORCH_LOCK_TIMEOUT:-10} * 10 ))" ] && { warn "lock timeout on $lock"; return 75; }
    sleep 0.1
  done
  "$@"; local rc=$?
  rmdir "$d" 2>/dev/null || true
  return $rc
}

# Atomically replace a file with the contents of stdin.
orch_atomic_write() {  # orch_atomic_write <path>
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${dest}.orch.XXXXXX")" || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

# Who is acting. Prefer the role orch was invoked as, then the Claude Code
# session name, then the session id.
orch_actor() {
  if [ -n "${ORCH_ROLE:-}" ]; then printf '%s' "$ORCH_ROLE"; return 0; fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf 'session:%s' "${CLAUDE_CODE_SESSION_ID%%-*}"; return 0; fi
  printf 'human:%s' "${USER:-unknown}"
}
