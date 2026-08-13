#!/bin/bash
# messaging.sh - substrate implementation on Claude Code's native primitives.
#
# Coordination state:  the shared, file-locked task list at
#                      ~/.claude/tasks/<CLAUDE_CODE_TASK_LIST_ID>/
# Roster:              `claude agents --json`
# Notification:        the SendMessage tool (agents) or a durable inbox file
#                      (shell); see orch_sub_post.
#
# The load-bearing half is the task list. Two sessions that export the same
# CLAUDE_CODE_TASK_LIST_ID share one directory with first-party locking, and
# that directory is the state machine. Verified empirically on CLI 2.1.228:
# `<id>/N.json` per task plus a zero-byte `.lock`, with `metadata` round-tripped
# verbatim - which is where orch keeps its own fields, namespaced under `orch`.

# ---------------------------------------------------------------------------
# Task list location
# ---------------------------------------------------------------------------

# A session that does not export CLAUDE_CODE_TASK_LIST_ID gets a list keyed by
# its own session id and shares with nobody. We derive a repo-stable default so
# the shell path works out of the box; `orch doctor` is what catches a session
# that failed to opt in.
orch_task_list_id() {
  if [ -n "${CLAUDE_CODE_TASK_LIST_ID:-}" ]; then printf '%s' "$CLAUDE_CODE_TASK_LIST_ID"; return 0; fi
  printf 'orch-%s' "$(basename "${ORCH_REPO:-$(orch_repo_root)}")"
}

_tl_dir()  { printf '%s/%s' "${ORCH_TASKS_ROOT:-$HOME/.claude/tasks}" "$(orch_task_list_id)"; }
_tl_lock() { printf '%s/.lock' "$(_tl_dir)"; }

_tl_ensure() { mkdir -p "$(_tl_dir)"; }

# ---------------------------------------------------------------------------
# Task primitives
# ---------------------------------------------------------------------------

# Allocate an id and create the task file, race-free.
#
# We deliberately do NOT allocate under the task-list lock. The CLI's lock is
# advisory and we cannot take it identically on every platform (see
# orch_with_lock), so a scan-then-write would reintroduce exactly the id race
# a read-modify-write on a counter file would. Instead: pick the next free
# number, create the file with
# O_EXCL (`set -C` makes bash's `>` do that), and retry on collision. Whoever
# else is writing - the CLI, another orch, both - the loser retries.
_tl_create() {  # _tl_create <json-without-id>  -> prints id
  local body="$1" dir n f attempts=0
  _tl_ensure
  dir="$(_tl_dir)"
  n="$(ls "$dir" 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.json$/\1/p' | sort -n | tail -1)"
  n=$(( ${n:-0} + 1 ))
  while :; do
    f="$dir/$n.json"
    if ( set -C; : > "$f" ) 2>/dev/null; then
      printf '%s' "$body" | jq -c --arg id "$n" '.id=$id' | jq . > "$f" || { rm -f "$f"; return 1; }
      printf '%s' "$n"
      return 0
    fi
    n=$((n + 1))
    attempts=$((attempts + 1))
    [ "$attempts" -gt 500 ] && { warn "could not allocate a task id in $dir"; return 1; }
  done
}

# Read-modify-write one task file with a jq program, under the lock.
_tl_mutate_unlocked() {  # _tl_mutate_unlocked <file> <jq-prog> [jq-args...]
  local f="$1"; shift
  local prog="$1"; shift
  local out
  out="$(jq "$@" "$prog" "$f" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | orch_atomic_write "$f"
}

_tl_mutate() {
  orch_with_lock "$(_tl_lock)" _tl_mutate_unlocked "$@"
}

# All task files, numerically ordered. Empty output when the list does not
# exist yet - not an error; the list is created on first write.
_tl_files() {
  local dir; dir="$(_tl_dir)"
  [ -d "$dir" ] || return 0
  ls "$dir" 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.json$/\1/p' | sort -n |
    while IFS= read -r n; do printf '%s/%s.json\n' "$dir" "$n"; done
}

# First task file matching a jq boolean predicate.
_tl_find() {  # _tl_find <jq-predicate> [jq-args...]
  local prog="$1"; shift
  local f
  _tl_files | while IFS= read -r f; do
    if [ "$(jq -r "$@" "($prog) // false" "$f" 2>/dev/null)" = "true" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done | head -1
}

# ---------------------------------------------------------------------------
# Seam: roster
# ---------------------------------------------------------------------------

# `claude agents --json` is the supported read path. Parsing ~/.claude/sessions
# directly would work today and is exactly the kind of internal that moves
# under you, so we do not.
orch_sub_roster() {
  local out
  if ! have claude; then printf '[]'; return 0; fi
  out="$(claude agents --json 2>/dev/null)" || out=''
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then
    printf '[]'; return 0
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Seam: post
# ---------------------------------------------------------------------------

# Notify a peer. Best effort by contract - a dropped notification costs a
# delay, never a transition (spec §3).
#
# There are two transports and they are not interchangeable:
#
#   tool   an agent inside a session calls SendMessage. Ephemeral, subject to
#          permission-mode class matching and dialogExpiry, and audited by
#          hooks/audit-message.sh. Roles are told to use it; the shell cannot,
#          because the socket is 0600 and ownership-verified.
#   inbox  this function. Appends to a durable, greppable per-recipient file
#          that the recipient reads on its next turn.
#
# Both land in the ledger, tagged with which one ran, so `orch report` can tell
# you how much of your coordination actually depended on the ephemeral path.
orch_sub_post() {  # orch_sub_post <to> <body> [kind]
  local to="$1" body="$2" kind="${3:-notice}" feature dir line
  feature="$(orch_current_feature)"
  dir="$(orch_feature_dir "$feature")/inbox"
  case "$to" in ''|*/*) warn "post: invalid recipient '$to'"; return 1 ;; esac
  line="$(orch_json ts "$(now_iso)" from "$(orch_actor)" to "$to" kind "$kind" body "$body")"
  orch_append_jsonl "$dir/$to.jsonl" "$line" || return 1
  ledger_append message.posted \
    to "$to" kind "$kind" transport inbox bytes:raw "${#body}"
  return 0
}

# ---------------------------------------------------------------------------
# Seam: claim / release
# ---------------------------------------------------------------------------

orch_sub_claim_task() {  # orch_sub_claim_task <id> <owner>
  local id="$1" owner="$2" f cur
  f="$(_tl_dir)/$id.json"
  [ -f "$f" ] || { warn "no such task: $id"; return 1; }
  cur="$(jq -r '.owner // ""' "$f" 2>/dev/null)"
  if [ -n "$cur" ] && [ "$cur" != "$owner" ]; then
    warn "task $id already owned by $cur"
    return 1
  fi
  _tl_mutate "$f" '.owner=$o | .status=(if .status=="completed" then .status else "in_progress" end)' \
    --arg o "$owner" || return 1
  ledger_append task.claimed task_id "$id" owner "$owner"
}

orch_sub_release_task() {  # orch_sub_release_task <id>
  local id="$1" f
  f="$(_tl_dir)/$id.json"
  [ -f "$f" ] || { warn "no such task: $id"; return 1; }
  _tl_mutate "$f" 'del(.owner) | .status=(if .status=="completed" then .status else "pending" end)' || return 1
  ledger_append task.released task_id "$id"
}

# ---------------------------------------------------------------------------
# Seam: gates
# ---------------------------------------------------------------------------
#
# A gate is a task carrying metadata.orch = {kind:"gate", gate, feature, sha}.
# Storing gates as tasks rather than as files is what makes `orch approve`
# work from any terminal and makes the gate visible in the same list the
# director is already reading.

_gate_subject() { printf 'gate: %s · %s' "$2" "$1"; }  # _gate_subject <feature> <gate>

_gate_file() {  # _gate_file <feature> <gate>
  _tl_find '.metadata.orch.kind=="gate" and .metadata.orch.gate==$g and .metadata.orch.feature==$f' \
    --arg g "$2" --arg f "$1"
}

# read_gate prints one JSON object. state is one of:
#   absent  no gate task exists
#   open    exists, not completed
#   met     completed; `sha` is the sha it was met at ("" if unbound)
orch_sub_read_gate() {  # orch_sub_read_gate <feature> <gate>
  local feature="$1" gate="$2" f
  f="$(_gate_file "$feature" "$gate")"
  if [ -z "$f" ]; then
    orch_json feature "$feature" gate "$gate" state absent sha '' at '' by '' task_id ''
    return 0
  fi
  jq -c --arg feature "$feature" --arg gate "$gate" '
    {feature: $feature, gate: $gate,
     state: (if .status=="completed" then "met" else "open" end),
     sha: (.metadata.orch.sha // ""),
     at:  (.metadata.orch.at // ""),
     by:  (.metadata.orch.by // ""),
     task_id: (.id // "")}' "$f"
}

# set_gate is idempotent and always records who set it and at which sha.
orch_sub_set_gate() {  # orch_sub_set_gate <feature> <gate> <met|open> [sha]
  local feature="$1" gate="$2" state="$3" sha="${4:-}" f id status
  case "$state" in met|open) ;; *) warn "set_gate: bad state '$state'"; return 1 ;; esac
  [ "$state" = "met" ] && status=completed || status=pending
  f="$(_gate_file "$feature" "$gate")"
  if [ -z "$f" ]; then
    id="$(_tl_create "$(jq -cn \
        --arg subj "$(_gate_subject "$feature" "$gate")" \
        --arg desc "orch gate '$gate' for $feature. Managed by orch; mark done only through \`orch approve\`." \
        --arg status "$status" --arg gate "$gate" --arg feature "$feature" \
        --arg sha "$sha" --arg at "$(now_iso)" --arg by "$(orch_actor)" \
        '{subject:$subj, description:$desc, status:$status, blocks:[], blockedBy:[],
          metadata:{orch:{kind:"gate", gate:$gate, feature:$feature, sha:$sha, at:$at, by:$by}}}')")" || return 1
  else
    _tl_mutate "$f" '.status=$status
        | .metadata = ((.metadata // {}) * {orch: ((.metadata.orch // {}) * {sha:$sha, at:$at, by:$by})})' \
      --arg status "$status" --arg sha "$sha" --arg at "$(now_iso)" --arg by "$(orch_actor)" || return 1
    id="$(jq -r '.id // ""' "$f" 2>/dev/null)"
  fi
  ledger_append gate.set feature "$feature" gate "$gate" state "$state" sha "$sha" task_id "${id:-}"
}

# ---------------------------------------------------------------------------
# Seam: probe
# ---------------------------------------------------------------------------
#
# Every platform internal `orch doctor` needs, gathered in one place. Nothing
# above lib/substrate/ knows that sockets live in /tmp/cc-socks or that the
# permission-mode class has to be recovered from the process arguments.

_sock_dir() { printf '%s' "${ORCH_SOCKET_DIR:-/tmp/cc-socks}"; }

# Permission-mode class of a running session, derived from how it was invoked.
#
# `claude agents --json` does not report permission mode - verified on 2.1.228,
# whose roster carries pid/cwd/kind/startedAt/sessionId/name and nothing else -
# and the session registry does not carry it either. So we read the process
# arguments, which is the only mechanical source available. A session we cannot
# see (different user, ps restricted) is reported "unknown" rather than guessed:
# a wrong class here would produce a confident all-clear for the exact failure
# it exists to catch.
_pm_class() {  # _pm_class <pid>
  local args
  args="$(ps -o args= -p "$1" 2>/dev/null)" || { printf 'unknown'; return 0; }
  [ -n "$args" ] || { printf 'unknown'; return 0; }
  case "$args" in
    *--dangerously-skip-permissions*|*"--permission-mode bypassPermissions"*|*"--permission-mode=bypassPermissions"*)
      printf 'bypassing' ;;
    *) printf 'prompting' ;;
  esac
}

# A setting as the CLI would resolve it: project settings override user
# settings. Local overrides are checked first because that is where a machine's
# actual behaviour usually gets set.
_setting() {  # _setting <key>
  local key="$1" v f
  for f in "${ORCH_REPO:-.}/.claude/settings.local.json" \
           "${ORCH_REPO:-.}/.claude/settings.json" \
           "$HOME/.claude/settings.json"; do
    [ -r "$f" ] || continue
    v="$(jq -r --arg k "$key" '.[$k] // empty' "$f" 2>/dev/null)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  printf ''
}

orch_sub_probe() {
  local roster tl dir peers pid self_pid
  roster="$(orch_sub_roster)"
  tl="$(orch_task_list_id)"
  dir="$(_tl_dir)"
  self_pid="${CLAUDE_PID:-}"

  peers='[]'
  for pid in $(printf '%s' "$roster" | jq -r '.[].pid // empty' 2>/dev/null); do
    peers="$(printf '%s' "$peers" | jq -c \
      --argjson entry "$(printf '%s' "$roster" | jq -c --argjson p "$pid" '.[] | select(.pid==$p)')" \
      --arg sock "$(_sock_dir)/$pid.sock" \
      --arg sock_present "$([ -S "$(_sock_dir)/$pid.sock" ] && echo true || echo false)" \
      --arg cwd_present "$([ -d "$(printf '%s' "$roster" | jq -r --argjson p "$pid" '.[] | select(.pid==$p) | .cwd // ""')" ] && echo true || echo false)" \
      --arg pm "$(_pm_class "$pid")" \
      '. + [$entry + {socket:$sock, socket_present:($sock_present=="true"),
                      cwd_present:($cwd_present=="true"), permission_class:$pm}]')"
  done

  jq -n \
    --arg substrate messaging \
    --arg cli "$(claude --version 2>/dev/null | awk '{print $1}')" \
    --arg cli_verified "$ORCH_VERIFIED_CLI" \
    --arg task_list_id "$tl" \
    --arg task_list_dir "$dir" \
    --argjson task_list_env "$([ -n "${CLAUDE_CODE_TASK_LIST_ID:-}" ] && echo true || echo false)" \
    --argjson task_list_exists "$([ -d "$dir" ] && echo true || echo false)" \
    --argjson lock_present "$([ -e "$dir/.lock" ] && echo true || echo false)" \
    --arg socket_dir "$(_sock_dir)" \
    --arg self_socket "${CLAUDE_CODE_MESSAGING_SOCKET:-}" \
    --argjson self_socket_present "$([ -S "${CLAUDE_CODE_MESSAGING_SOCKET:-/nonexistent}" ] && echo true || echo false)" \
    --arg cross_session_inbound "$(_setting crossSessionInbound)" \
    --arg dialog_expiry "$(_setting dialogExpiry)" \
    --argjson containerized "$([ -n "${CLAUDE_CODE_CONTAINER_ID:-}" ] || [ -e /.dockerenv ] && echo true || echo false)" \
    --argjson pid1 "$([ "$$" = "1" ] && echo true || echo false)" \
    --arg self_pid "$self_pid" \
    --argjson worktree_ok "$(git -C "${ORCH_REPO:-.}" worktree list >/dev/null 2>&1 && echo true || echo false)" \
    --argjson peers "$peers" \
    '$ARGS.named' 2>/dev/null || printf '{"substrate":"messaging","error":"probe failed"}'
}
