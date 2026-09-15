#!/bin/bash
# holdout.sh - the held-out oracle (docs/AGENT-TDD.md, phase 2, optional).
#
# The comparator's challenge file and the second kernel were checks the FLT
# agents never iterated against [P36]; Anthropic's reward-hacking defences
# use hidden tests for the same reason [P40]. A visible suite is both a
# specification the developer reads and an oracle it can overfit. A holdout
# is the part of the oracle it never sees, run once, in a clean worktree, at
# the sha being approved.
#
# The test-engineer designates holdout tests before the red phase:
#     orch holdout add <F> test/test_edge.py
# moves the file out of the tree into .orch/holdout/<F>/ — untracked, so it
# is in no commit the developer's worktree can diff. At the gate:
#     orch holdout run <F> -- <test command>
# checks out the approved sha in a throwaway worktree, puts the holdout files
# back, commits them on a throwaway branch (so the run is over a clean tree),
# runs the command as attested evidence, and sets the `holdout` gate on
# success. On failure it does NOT open a repair cycle against the holdout —
# that would just make it visible — it escalates to rung 3, where selection
# ranks on it.
#
# The boundary, honestly: the developer is denied .orch/holdout by the read
# and write guards, and `orch run` refuses a developer command that names it.
# A developer that goes looking with `orch run -- find` can find it. This is
# a discouragement with a ledger row, not a secret; a real secret needs a
# second machine.

[ -n "${ORCH_HOLDOUT_SOURCED:-}" ] && return 0
ORCH_HOLDOUT_SOURCED=1

# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"
# shellcheck source=escalate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/escalate.sh"
# shellcheck source=substrate/base.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/substrate/base.sh"

holdout_dir()  { printf '%s/.orch/holdout/%s' "${ORCH_REPO:-$(orch_repo_root)}" "$1"; }
holdout_list() { ( cd "$(holdout_dir "$1")" 2>/dev/null && find . -type f | sed 's|^\./||' | sort ); }
holdout_has()  { [ -n "$(holdout_list "$1")" ]; }

# holdout_add <feature> <path> — move a test out of the tree into the holdout.
holdout_add() {
  local feature="$1" path="$2" repo rel dest
  orch_valid_feature "$feature" || die "holdout add: invalid feature '$feature'"
  case "${ORCH_ROLE:-}" in developer) die "holdout add: the developer does not choose what it is not shown" ;; esac
  repo="${ORCH_REPO:-$(orch_repo_root)}"
  rel="${path#"$repo"/}"
  [ -f "$repo/$rel" ] || die "holdout add: $rel is not a file in the tree"
  dest="$(holdout_dir "$feature")/$rel"
  mkdir -p "$(dirname "$dest")"
  cp "$repo/$rel" "$dest"
  git -C "$repo" rm -q --cached "$rel" >/dev/null 2>&1 || true
  rm -f "$repo/$rel"
  ORCH_LEDGER_FEATURE="$feature" ledger_append holdout.added path "$rel"
  printf 'held out: %s (now at %s; commit the removal before the red phase)\n' "$rel" "$dest"
}

# holdout_run <feature> -- <cmd...>
holdout_run() {
  local feature="$1"; shift
  [ "${1:-}" = "--" ] && shift
  [ "$#" -gt 0 ] || die "holdout run: no command given"
  local repo sha wt br f rc rung
  orch_valid_feature "$feature" || die "holdout run: invalid feature '$feature'"
  holdout_has "$feature" || die "holdout run: no holdout files for $feature (orch holdout add)"
  repo="${ORCH_REPO:-$(orch_repo_root)}"
  sha="$(orch_head_sha)"
  evidence_verify "$feature" tests --claim pass --fresh >/dev/null 2>&1 \
    || die "holdout run: the visible suite is not attested green and clean at HEAD — the holdout runs after it, not instead of it"
  wt="$repo/.orch/worktrees/$feature/holdout"; br="orch/$feature/holdout"
  [ ! -e "$wt" ] || git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$repo" branch -D "$br" >/dev/null 2>&1 || true
  git -C "$repo" worktree add -q -b "$br" "$wt" "$sha" || die "holdout run: could not create worktree"
  for f in $(holdout_list "$feature"); do
    mkdir -p "$wt/$(dirname "$f")"
    cp "$(holdout_dir "$feature")/$f" "$wt/$f"
  done
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c user.email=orch@holdout -c user.name=orch commit -q -m "holdout for $feature at $sha" >/dev/null 2>&1
  # Evidence lands in the main checkout's feature dir (ORCH_REPO), attributed
  # to the approved sha; the throwaway commit is recorded beside it.
  ( cd "$wt" && ORCH_REPO="$repo" evidence_run "$feature" holdout -- "$@" ); rc=$?
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$repo" branch -D "$br" >/dev/null 2>&1 || true
  if [ "$rc" = "0" ]; then
    substrate_set_gate "$feature" holdout met "$sha" >/dev/null
    ORCH_LEDGER_FEATURE="$feature" ledger_append holdout.passed at_sha "$sha" files:raw "$(holdout_list "$feature" | grep -c .)"
    printf 'holdout for %s PASSED at %s — gate `holdout` met.\n' "$feature" "$(printf '%s' "$sha" | cut -c1-12)"
    return 0
  fi
  ORCH_LEDGER_FEATURE="$feature" ledger_append holdout.failed at_sha "$sha" exit_code:raw "$rc"
  rung="$(escalate_rung "$feature")"
  printf 'holdout for %s FAILED (exit %s) at %s.\n' "$feature" "$rc" "$(printf '%s' "$sha" | cut -c1-12)" >&2
  if [ "${rung:-0}" -lt 3 ]; then
    escalate_to "$feature" 3 "holdout failed at $sha: the visible suite was overfit" >/dev/null 2>&1
    printf 'Not a repair cycle — that would make the holdout visible. Escalated to rung 3: candidates are ranked on it.\n' >&2
  fi
  return 1
}
