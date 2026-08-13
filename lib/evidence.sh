#!/bin/bash
# evidence.sh - attested execution.
#
# Invariant 7: nothing is claimed that was not attested. v1's evidence header
# was the best mechanism it had and it was still an agent's claim about its own
# diligence - a model that wanted to skip the tests could simply say it had run
# them. Here the only way to produce an evidence row is to actually execute the
# command, and every approval path checks the rows rather than the prose.

[ -n "${ORCH_EVIDENCE_SOURCED:-}" ] && return 0
ORCH_EVIDENCE_SOURCED=1

# shellcheck source=ledger.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ledger.sh"

evidence_path() { printf '%s/evidence.jsonl' "$(orch_feature_dir "$1")"; }

# Which worktree we are in, so a best-of-N candidate's evidence is not
# mistaken for the main checkout's.
_evidence_worktree() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf ''; return 0; }
  printf '%s' "$top"
}

# evidence_run <feature> <label> -- <cmd...>
#
# Streams stdout and stderr through unchanged (both are captured together, so
# the recorded tail matches what a human watching the terminal saw), then
# appends one evidence row. Exits with the command's own status: `orch run`
# has to be transparent enough to sit inside `&&` chains and CI.
evidence_run() {
  local feature="$1" label="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  [ "$#" -gt 0 ] || die "run: no command given"
  orch_valid_feature "$feature" || die "run: invalid feature '$feature'"

  local out start end rc dur sha tail_txt cmd_json row had_e=0
  out="$(mktemp "${TMPDIR:-/tmp}/orch-run.XXXXXX")" || die "run: mktemp failed"
  start="$(now_epoch)"

  # Restore errexit to whatever the caller had, not to "on". Turning it on
  # unconditionally is how a caller that loops over several runs silently stops
  # after the first failing one - which for the diagnostic stage would mean
  # executing one hypothesis and calling the other two unfalsified.
  case "$-" in *e*) had_e=1 ;; esac

  # PIPESTATUS is what makes this honest: `tee` succeeding must not mask the
  # command failing, which is the classic way a green light gets faked.
  set +e
  "$@" 2>&1 | tee "$out"
  rc="${PIPESTATUS[0]}"
  [ "$had_e" = "1" ] && set -e

  end="$(now_epoch)"
  dur=$((end - start))
  sha="$(orch_sha256 < "$out")"
  tail_txt="$(tail -c 2000 "$out" 2>/dev/null)"
  cmd_json="$(printf '%s\n' "$@" | jq -Rs 'split("\n")[:-1]')"

  row="$(orch_json \
    ts "$(now_iso)" \
    agent "$(orch_actor)" \
    label "$label" \
    cmd:raw "$cmd_json" \
    exit_code:raw "$rc" \
    duration_s:raw "$dur" \
    stdout_sha256 "$sha" \
    stdout_tail "$tail_txt" \
    git_sha "$(orch_head_sha)" \
    worktree "$(_evidence_worktree)")"
  orch_append_jsonl "$(evidence_path "$feature")" "$row"
  ORCH_LEDGER_FEATURE="$feature" ledger_append run.attested \
    label "$label" exit_code:raw "$rc" duration_s:raw "$dur"

  rm -f "$out"
  return "$rc"
}

# The most recent evidence row for a label, or empty.
evidence_latest() {  # evidence_latest <feature> <label>
  local f; f="$(evidence_path "$1")"
  [ -r "$f" ] || return 0
  jq -c --arg l "$2" 'select(type=="object" and .label==$l)' "$f" 2>/dev/null | tail -1
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
#
# Exit codes, so callers and hooks can branch without parsing prose:
#   0  attested and consistent with the claim
#   3  EVIDENCE_UNATTESTED   - no row for that label
#   4  EVIDENCE_CONTRADICTED - a row exists and refutes the claim
#   5  EVIDENCE_STALE        - the branch tip moved after the evidence was taken
#
# Neither 3 nor 4 consumes a repair cycle. Rejecting a false claim is not the
# same event as failing an honest attempt, and conflating them is how a loop
# burns its budget punishing the wrong thing.
evidence_verify() {  # evidence_verify <feature> <label> [--claim pass|fail] [--fresh]
  local feature="$1" label="$2"; shift 2
  local claim=pass fresh=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --claim) claim="${2:-pass}"; shift 2 ;;
      --fresh) fresh=1; shift ;;
      *) die "evidence verify: unexpected argument '$1'" ;;
    esac
  done

  local row rc row_sha head
  row="$(evidence_latest "$feature" "$label")"
  if [ -z "$row" ]; then
    printf 'EVIDENCE_UNATTESTED: no `orch run --label %s` entry for %s\n' "$label" "$feature" >&2
    printf 'Run it, do not describe it:  orch run --feature %s --label %s -- <command>\n' "$feature" "$label" >&2
    ORCH_LEDGER_FEATURE="$feature" ledger_append evidence.rejected label "$label" reason EVIDENCE_UNATTESTED
    return 3
  fi

  rc="$(printf '%s' "$row" | jq -r '.exit_code // 1')"
  case "$claim" in
    pass) [ "$rc" = "0" ] || {
            printf 'EVIDENCE_CONTRADICTED: %s claimed passing, but the attested run exited %s\n' "$label" "$rc" >&2
            printf '%s\n' "$(printf '%s' "$row" | jq -r '.stdout_tail // ""' | tail -20)" >&2
            ORCH_LEDGER_FEATURE="$feature" ledger_append evidence.rejected label "$label" reason EVIDENCE_CONTRADICTED exit_code:raw "$rc"
            return 4; } ;;
    fail) [ "$rc" != "0" ] || {
            printf 'EVIDENCE_CONTRADICTED: %s was required to fail, but the attested run exited 0\n' "$label" >&2
            printf 'A test that passes before the implementation exists is a broken test, not a green light.\n' >&2
            ORCH_LEDGER_FEATURE="$feature" ledger_append evidence.rejected label "$label" reason EVIDENCE_CONTRADICTED exit_code:raw "$rc"
            return 4; } ;;
    *) die "evidence verify: --claim must be pass or fail" ;;
  esac

  if [ "$fresh" = "1" ]; then
    row_sha="$(printf '%s' "$row" | jq -r '.git_sha // ""')"
    head="$(orch_head_sha)"
    if [ "$row_sha" != "$head" ]; then
      printf 'EVIDENCE_STALE: %s was attested at %s but HEAD is now %s\n' "$label" "${row_sha:0:12}" "${head:0:12}" >&2
      ORCH_LEDGER_FEATURE="$feature" ledger_append evidence.rejected label "$label" reason EVIDENCE_STALE
      return 5
    fi
  fi
  return 0
}
