#!/bin/bash
# merge.sh - the merge queue.
#
# Two features that each passed alone can fail together. With features in
# parallel worktrees, the base branch is a shared resource and landing on it
# is serialised: one lock, one integration worktree, the suite run on the
# merged result BEFORE the base moves. A feature that is green alone and red
# with the base is that feature's to fix — merge the base in, re-run the
# floor, re-approve — and the base never carries a red commit.
#
#   orch merge <F>          land F: gates, lock, integration, floor, advance
#   orch merge status       approved and not landed, landed, rejected
#
# What it checks before touching the base: the human gate at F's HEAD, the
# statement and the oracle as frozen, the holdout if F has one. What it
# checks after merging into the integration worktree: the build and test
# commands (ORCH_BUILD_CMD, ORCH_TEST_CMD), attested under the run ledger.

[ -n "${ORCH_MERGE_SOURCED:-}" ] && return 0
ORCH_MERGE_SOURCED=1

# shellcheck source=statement.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statement.sh"
# shellcheck source=holdout.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/holdout.sh"

merge_lock() { printf '%s/merge.lock' "$(orch_state_dir)"; }
merge_wt()   { printf '%s/worktrees/_integration' "$(orch_state_dir)"; }

merge_landed() {  # merge_landed <feature> -> 0 if landed
  ledger_read "$1" | jq -e -s 'any(.[]; type=="object" and .event=="merge.landed")' >/dev/null 2>&1
}

# The serialised part: runs under the lock.
_merge_land_locked() {  # _merge_land_locked <feature> <feature-head> <base>
  local feature="$1" head="$2" base="$3" main wt title rc old new cur msg
  main="$(orch_main_repo)"; wt="$(merge_wt)"
  [ ! -e "$wt" ] || git -C "$main" worktree remove --force --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$main" worktree prune >/dev/null 2>&1
  old="$(git -C "$main" rev-parse "$base" 2>/dev/null)" || die "merge: no base branch '$base'"
  msg="$(git -C "$main" worktree add -f -q --detach "$wt" "$old" 2>&1)" || die "merge: could not create the integration worktree: $msg"

  title="$(head -1 "$(orch_feature_dir "$feature")/request.md" 2>/dev/null | cut -c1-72)"
  if ! git -C "$wt" merge -q --squash "$head" >/dev/null 2>&1; then
    git -C "$main" worktree remove --force --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$main" worktree prune >/dev/null 2>&1
    ORCH_LEDGER_FEATURE="$feature" ledger_append merge.rejected reason conflict base_sha "$old" head "$head"
    die "merge: $feature conflicts with $base at $(printf '%s' "$old" | cut -c1-12). Merge $base into feature/$feature, resolve, re-run the floor, re-approve."
  fi
  git -C "$wt" -c user.email=orch@merge -c user.name=orch commit -q -m "$feature: ${title:-merged}" >/dev/null 2>&1 \
    || { git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1; die "merge: nothing to merge — $feature has no changes against $base"; }
  new="$(git -C "$wt" rev-parse HEAD)"

  # The floor on the merged result, attested under the run ledger.
  rc=0
  if [ -n "${ORCH_BUILD_CMD:-}" ]; then
    ( cd "$wt" && ORCH_REPO="$wt" evidence_run _orch "integration-$feature-build" -- sh -c "$ORCH_BUILD_CMD" ) >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" = "0" ] && [ -n "${ORCH_TEST_CMD:-}" ]; then
    ( cd "$wt" && ORCH_REPO="$wt" evidence_run _orch "integration-$feature" -- sh -c "$ORCH_TEST_CMD" ) >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" != "0" ]; then
    git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    ORCH_LEDGER_FEATURE="$feature" ledger_append merge.rejected reason integration_red exit_code:raw "$rc" base_sha "$old" head "$head"
    die "merge: $feature is green alone and red merged with $base (exit $rc). The base did not move.
This is $feature's to fix: merge $base into feature/$feature, re-run the floor, re-approve."
  fi

  # Advance the base. If the main checkout is on it, fast-forward the
  # checkout; otherwise move the ref, guarded against a concurrent move.
  cur="$(git -C "$main" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$cur" = "$base" ]; then
    git -C "$main" merge -q --ff-only "$new" >/dev/null 2>&1 || die "merge: could not fast-forward $base in the main checkout — is it dirty?"
  else
    git -C "$main" update-ref "refs/heads/$base" "$new" "$old" || die "merge: $base moved while the floor ran; run the merge again"
  fi
  git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  ORCH_LEDGER_FEATURE="$feature" ledger_append merge.landed base "$base" base_sha "$old" sha "$new" head "$head"
  ORCH_LEDGER_FEATURE=_orch ledger_append merge.landed feature "$feature" base "$base" sha "$new"
  printf 'landed %s on %s: %s -> %s\n' "$feature" "$base" "$(printf '%s' "$old" | cut -c1-12)" "$(printf '%s' "$new" | cut -c1-12)"
}

# merge_land <feature> [--close]
merge_land() {
  local feature="$1" close=0 head base g msg
  shift; while [ "$#" -gt 0 ]; do case "$1" in --close) close=1 ;; esac; shift; done
  orch_valid_feature "$feature" || die "merge: invalid feature '$feature'"
  ! merge_landed "$feature" || die "merge: $feature already landed"
  head="$(git -C "$(orch_feature_repo "$feature")" rev-parse HEAD 2>/dev/null)" || die "merge: no tree for $feature"
  base="$(escalate_base_branch)"

  g="$(substrate_read_gate "$feature" human 2>/dev/null)"
  [ "$(printf '%s' "$g" | jq -r '.state // "absent"')" = met ] && [ "$(printf '%s' "$g" | jq -r '.sha // ""')" = "$head" ] \
    || die "merge: no human approval for $feature at $(printf '%s' "$head" | cut -c1-12).  orch packet $feature; orch approve $feature --gate human"
  msg="$(statement_check "$feature" 2>&1)" || die "merge: $msg"
  msg="$(oracle_check "$feature" "$head" 2>&1)" || die "merge: $msg"
  if holdout_has "$feature"; then
    g="$(substrate_read_gate "$feature" holdout 2>/dev/null)"
    [ "$(printf '%s' "$g" | jq -r '.state // "absent"')" = met ] && [ "$(printf '%s' "$g" | jq -r '.sha // ""')" = "$head" ] \
      || die "merge: $feature has a holdout that has not passed at $(printf '%s' "$head" | cut -c1-12).  orch holdout run $feature -- <cmd>"
  fi

  orch_with_lock "$(merge_lock)" _merge_land_locked "$feature" "$head" "$base" || return 1

  if [ "$close" = "1" ]; then
    # The ledger rows written since the feature's last commit — the approval,
    # the landing — exist only in the worktree. Carry the artifact directory
    # into the checkout before the worktree goes, so the record survives.
    local src dst
    src="$(orch_feature_dir "$feature")"; dst="$(orch_main_repo)/docs/features/$feature"
    mkdir -p "$dst" && cp -R "$src/." "$dst/" 2>/dev/null
    git -C "$(orch_main_repo)" worktree remove --force "$(orch_feature_repo "$feature")" >/dev/null 2>&1 || true
    printf 'closed the worktree for %s; artifacts are in docs/features/%s of the checkout (commit them); branch feature/%s is kept\n' "$feature" "$feature" "$feature"
  fi
}

merge_status() {
  local f g head st
  printf '%-24s %s\n' feature state
  for f in $(orch_features_list); do
    if merge_landed "$f"; then st="landed"
    else
      head="$(git -C "$(orch_feature_repo "$f")" rev-parse HEAD 2>/dev/null)"
      g="$(substrate_read_gate "$f" human 2>/dev/null)"
      if [ "$(ledger_read "$f" | jq -r -s '[.[] | select(type=="object" and .event=="merge.rejected")] | if length==0 then "" else last.head end')" = "$head" ]; then
        st="rejected at this head — $(ledger_read "$f" | jq -r -s '[.[] | select(type=="object" and .event=="merge.rejected")] | last | .reason')"
      elif [ "$(printf '%s' "$g" | jq -r '.state // "absent"')" = met ] && [ "$(printf '%s' "$g" | jq -r '.sha // ""')" = "$head" ]; then
        st="approved — orch merge $f"
      else st="in progress"; fi
    fi
    printf '%-24s %s\n' "$f" "$st"
  done
}
