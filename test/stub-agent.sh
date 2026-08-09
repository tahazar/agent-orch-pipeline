#!/bin/bash
# stub-agent.sh - a deterministic, protocol-conformant stand-in for an agent.
#
# This is the executable form of the protocol. It runs in a real tmux pane and
# receives `pipeline tell` keystrokes through the real send-keys path, exactly
# as a Claude session would. It implements what the role prompts specify -
# channel authentication, msg_id dedupe, artifact-before-signal, the feature
# state machine, evidence-header validation, write-ahead idempotent merges -
# and drives the whole session to completion without an LLM.
#
# What this proves: the protocol has no deadlocks or gaps, and the CLI supports
# it end to end. What it does not prove: that an LLM follows the prompts. That
# is what a live run on the developer's machine is for.
#
# Fault injections are read from $PIPELINE_DIR/inject.conf so the smoke test can
# reproduce specific failure modes deterministically.

set -u

ROLE="${1:-unknown}"
ME="${PIPELINE_ALIAS:-$ROLE}"
DIR="${PIPELINE_DIR:-/tmp/pipeline-unknown}"
REPO="$PWD"
CUR="docs/features/current"

HANDLED="$DIR/handled-$ME.log"
IGNORED="$DIR/ignored-$ME.log"
VIOLATIONS="$DIR/violations-$ME.log"
ACTIONS="$DIR/actions-$ME.log"
: > "$HANDLED"; : > "$IGNORED"; : > "$VIOLATIONS"; : > "$ACTIONS"

log_action() { printf '%s\n' "$*" >> "$ACTIONS"; }

inject() {
  # inject <key> -> prints the configured value, empty if unset
  [ -f "$DIR/inject.conf" ] || return 0
  grep "^$1=" "$DIR/inject.conf" 2>/dev/null | head -1 | cut -d= -f2-
}

say() { pipeline tell "$@" >> "$DIR/send-$ME.log" 2>&1; }

# Atomic write: temp file then move, per the single-writer rule.
write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path.tmp.$$" && mv "$path.tmp.$$" "$path"
}

# --------------------------------------------------------------------------
# Feature state (orch only) - the explicit FSM plus counters.
# --------------------------------------------------------------------------

fs_file() { printf '%s/feature-state.json' "$CUR"; }

fs_init() { printf '{}\n' | write_file "$(fs_file)"; }

fs_set() {  # fs_set <feature> <key> <value>
  local f="$1" k="$2" v="$3" out
  [ -f "$(fs_file)" ] || fs_init
  out="$(jq --arg f "$f" --arg k "$k" --arg v "$v" \
    '.[$f] = ((.[$f] // {}) + {($k): $v})' "$(fs_file)")" || return 1
  printf '%s\n' "$out" | write_file "$(fs_file)"
}

fs_get() {  # fs_get <feature> <key>
  jq -r --arg f "$1" --arg k "$2" '.[$f][$k] // empty' "$(fs_file)" 2>/dev/null
}

fs_bump() {  # fs_bump <feature> <counter>
  local n
  n="$(fs_get "$1" "$2")"; [ -n "$n" ] || n=0
  fs_set "$1" "$2" "$((n + 1))"
}

# A signal that is not legal for the feature's current state is a protocol
# violation: log it and do not act on it.
state_allows() {  # state_allows <feature> <signal>
  local st; st="$(fs_get "$1" state)"
  case "$2:$st" in
    PLAN_READY:PLANNING)            return 0 ;;
    APPROVED:PLAN_GATE)             return 0 ;;
    REJECTED:PLAN_GATE)             return 0 ;;
    DEV_APPROVE_PLAN:DEV_APPROVAL)  return 0 ;;
    FEATURE_COMPLETE:EXECUTING)     return 0 ;;
    WORK_APPROVED:WORK_GATE)        return 0 ;;
    WORK_REJECTED:WORK_GATE)        return 0 ;;
    *) return 1 ;;
  esac
}

violation() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$VIOLATIONS"
  log_action "VIOLATION $*"
}

# --------------------------------------------------------------------------
# Session helpers
# --------------------------------------------------------------------------

session_base() { sed -n 's/^- base: //p' "$CUR/session.md" 2>/dev/null | head -1; }
session_mode() { sed -n 's/^- mode: //p' "$CUR/session.md" 2>/dev/null | head -1; }

FEATURES="F001-config-file F002-off-by-one"

next_feature() {  # next_feature <current or empty>
  case "${1:-}" in
    "")                 printf 'F001-config-file' ;;
    F001-config-file)   printf 'F002-off-by-one' ;;
    *)                  printf '' ;;
  esac
}

# --------------------------------------------------------------------------
# orch
# --------------------------------------------------------------------------

orch_kickoff() {
  local body="$1" base mode slug sess
  base="$(git rev-parse --abbrev-ref HEAD)"
  case "$base" in
    main|master)
      log_action "REFUSED kickoff on $base"
      return 0 ;;
  esac

  mode="normal"
  case "$body" in *"test mode"*) mode="test" ;; esac

  slug="toy"
  sess="session-$(date -u +%Y-%m-%d)-$slug"
  mkdir -p "docs/features/$sess"
  ln -sfn "$sess" docs/features/current

  # request.md is frozen and verbatim.
  printf '%s\n' "$body" | write_file "$CUR/request.md"
  cp docs/specs/toy-design.md "$CUR/design.md" 2>/dev/null || true

  {
    printf '# Session\n'
    printf -- '- id: %s\n' "$sess"
    printf -- '- mode: %s\n' "$mode"
    printf -- '- base: %s\n' "$base"
    printf -- '- started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- pr-target: main\n\n'
    printf '## Kickoff (verbatim)\n%s\n' "$body"
  } | write_file "$CUR/session.md"
  log_action "SESSION base=$base mode=$mode"

  # Decompose.
  {
    printf '# Feature order\n\n'
    printf '1. F001-config-file - add config/app.json (direct)\n'
    printf '2. F002-off-by-one - fix the off-by-one in scripts/count.sh (lite)\n\n'
    printf 'No parallel group: F002 depends on nothing from F001, but grouping\n'
    printf 'is not justified for two features this small.\n'
  } | write_file "$CUR/feature-order.md"

  {
    printf '# F001-config-file\n\n## Acceptance criteria\n'
    printf -- '- config/app.json exists and is valid JSON\n'
    printf -- '- it contains {"name": "toy", "version": 1}\n\n'
    printf '## Verbatim example from the design\n\n```json\n{"name": "toy", "version": 1}\n```\n'
  } | write_file "$CUR/F001-config-file/requirements.md"

  {
    printf '# F002-off-by-one\n\n## Acceptance criteria\n'
    printf -- '- scripts/count.sh prints the number of arguments it was given\n'
    printf -- '- a regression test covers the reported case\n\n'
    printf '## Verbatim example from the design\n\n```\ncount.sh a b c  ->  3\n```\n'
  } | write_file "$CUR/F002-config.md.placeholder" 2>/dev/null
  {
    printf '# F002-off-by-one\n\n## Acceptance criteria\n'
    printf -- '- scripts/count.sh prints the number of arguments it was given\n'
    printf -- '- a regression test covers the reported case\n\n'
    printf '## Verbatim example from the design\n\n```\ncount.sh a b c  ->  3\n```\n'
  } | write_file "$CUR/F002-off-by-one/requirements.md"
  rm -f "$CUR/F002-config.md.placeholder"

  fs_init
  local f
  for f in $FEATURES; do fs_set "$f" state PLANNING; fs_set "$f" spotcheck_cycles 0; done

  say principal "Decomposition ready: 2 features. Request at $CUR/request.md, design at $CUR/design.md, order at $CUR/feature-order.md. [SIGNAL:DECOMPOSITION_READY]"
}

orch_status_md() {
  {
    printf '# Session status\n\n'
    printf -- '- mode: %s\n- base: %s\n\n' "$(session_mode)" "$(session_base)"
    printf '## Features\n'
    local f
    for f in $FEATURES; do
      printf -- '- %s: %s\n' "$f" "$(fs_get "$f" state)"
    done
    printf '\n## Waiting on\n%s\n' "${1:-nothing}"
  } | write_file "$CUR/status.md"
}

ask_developer() { printf '%s\n' "$1" > "$DIR/awaiting-developer"; log_action "ASK_DEV $1"; }

orch_start_feature() {
  local f="$1" base
  base="$(session_base)"
  git checkout -q "$base" 2>/dev/null
  git checkout -q -b "feature/$f" 2>/dev/null || git checkout -q "feature/$f"
  fs_set "$f" state PLANNING
  orch_status_md "lead-$f to plan $f"
  pipeline spawn "lead:opus:lead-$f" >> "$DIR/send-$ME.log" 2>&1
  say "lead-$f" "Start $f. Requirements at $CUR/$f/requirements.md, branch feature/$f, base $base. Reply to orch. [SIGNAL:FEATURE_START feature=$f]"
}

# Evidence-header validation. Missing/incomplete header, or a SHA that is not
# the current branch tip, invalidates the approval - and does NOT consume a
# spot-check cycle, because it is a process failure and not a review cycle.
validate_evidence() {  # validate_evidence <feature>; echoes the sha on success
  local f="$1" wr="$CUR/$f/work-review.md" sha tip
  [ -f "$wr" ] || { printf 'no-artifact'; return 1; }
  head -8 "$wr" | grep -q '^## Evidence' || { printf 'no-header'; return 1; }
  for field in commit-sha diff-command files-read tests-run; do
    grep -q "^- $field:" "$wr" || { printf 'incomplete-header:%s' "$field"; return 1; }
  done
  sha="$(sed -n 's/^- commit-sha: //p' "$wr" | head -1)"
  tip="$(git rev-parse "feature/$f" 2>/dev/null)"
  [ -n "$sha" ] || { printf 'no-sha'; return 1; }
  if [ "$sha" != "$tip" ]; then printf 'stale-sha'; return 1; fi
  printf '%s' "$sha"
  return 0
}

# Write-ahead + idempotent. Called again after a crash, this must not produce a
# second squash commit.
orch_merge() {  # orch_merge <feature> <reviewed-sha>
  local f="$1" sha="$2" base
  base="$(session_base)"

  # 1. Record the intent BEFORE acting.
  fs_set "$f" state MERGING
  fs_set "$f" target_sha "$sha"

  git checkout -q "$base"

  # 2. Idempotence: if this work is already on base, record and return.
  if [ -n "$(fs_get "$f" merge_sha)" ] || git log --oneline "$base" 2>/dev/null | grep -q "($f)"; then
    log_action "MERGE_SKIPPED $f already on $base"
    fs_set "$f" state DONE
    [ -n "$(fs_get "$f" merge_sha)" ] || fs_set "$f" merge_sha "$(git rev-parse HEAD)"
    return 0
  fi

  # 3. Merge the REVIEWED SHA, never the branch name.
  git merge --squash "$sha" >/dev/null 2>&1
  git commit -q -m "feat($f): $(sed -n '1s/^# //p' "$CUR/$f/requirements.md")" 2>/dev/null

  # 4. Record the outcome.
  fs_set "$f" merge_sha "$(git rev-parse HEAD)"
  fs_set "$f" state DONE
  log_action "MERGED $f sha=$sha"
}

orch_finish() {
  local mode; mode="$(session_mode)"
  git add -A docs/features >/dev/null 2>&1
  git commit -q -m "docs: session artifacts" 2>/dev/null || true
  if [ "$mode" = "test" ]; then
    {
      printf '# Test mode complete\n\n'
      printf 'No PR created and main untouched, as required in test mode.\n'
      printf 'Work is on %s. Manual follow-up: review the branch and open a PR yourself.\n' "$(session_base)"
    } | write_file "$CUR/final-report.md"
    log_action "TEST_MODE_STOP no PR created"
  else
    log_action "NORMAL_MODE would run gh pr create"
  fi
  orch_status_md "nothing - session complete"
  touch "$DIR/session-complete"
}

orch_handle() {
  local sig="$1" params="$2" body="$3" f
  f="$(printf '%s' "$params" | sed -n 's/.*feature=\([^ ]*\).*/\1/p')"

  case "$sig" in
    KICKOFF) orch_kickoff "$body" ;;

    APPROVED)
      case "$params" in
        *feature=*)
          state_allows "$f" APPROVED || { violation "APPROVED for $f in state $(fs_get "$f" state)"; return; }
          fs_set "$f" state DEV_APPROVAL
          orch_status_md "developer approval of the $f plan"
          ask_developer "plan:$f" ;;
        *contract*) log_action "CONTRACT_APPROVED" ;;
        *)
          # Bare discriminator = the decomposition verdict.
          orch_status_md "developer approval of the decomposition"
          ask_developer "decomposition" ;;
      esac ;;

    DEV_APPROVE_DECOMPOSITION)
      rm -f "$DIR/awaiting-developer"
      orch_start_feature "$(next_feature "")" ;;

    DEV_APPROVE_PLAN)
      rm -f "$DIR/awaiting-developer"
      state_allows "$f" DEV_APPROVE_PLAN || { violation "DEV_APPROVE_PLAN for $f in state $(fs_get "$f" state)"; return; }
      fs_set "$f" state EXECUTING
      orch_status_md "lead-$f executing $f"
      say "lead-$f" "Plan approved by principal and the developer. Proceed. [SIGNAL:PLAN_APPROVED feature=$f]" ;;

    PLAN_READY)
      state_allows "$f" PLAN_READY || { violation "PLAN_READY for $f in state $(fs_get "$f" state)"; return; }
      fs_set "$f" state PLAN_GATE
      say principal "Plan ready for $f. Plan at $CUR/$f/plan.md. [SIGNAL:PLAN_REVIEW_READY feature=$f]" ;;

    FEATURE_COMPLETE)
      state_allows "$f" FEATURE_COMPLETE || { violation "FEATURE_COMPLETE for $f in state $(fs_get "$f" state)"; return; }
      fs_set "$f" state WORK_GATE
      orch_status_md "principal spot-check of $f"
      say principal "$f reports complete on feature/$f. Spot-check it. [SIGNAL:WORK_REVIEW_READY feature=$f]"
      # Artifact fallback: if the verdict never arrives, poke ourselves so we
      # recover it from the review file instead of stalling forever.
      ( sleep 10; pipeline tell "$ME" "fallback check for $f [SIGNAL:STATUS_REQUEST feature=$f]" \
          >> "$DIR/send-$ME.log" 2>&1 ) & ;;

    STATUS_REQUEST)
      if [ -n "$f" ] && [ "$(fs_get "$f" state)" = "WORK_GATE" ] && [ -f "$CUR/$f/work-review.md" ]; then
        # The sender looks done but no verdict arrived. Recover it from the
        # artifact and note the dropped signal.
        local verdict
        verdict="$(sed -n 's/^verdict: //p' "$CUR/$f/work-review.md" | head -1)"
        log_action "DROPPED_SIGNAL recovered verdict=$verdict for $f from artifact"
        printf '%s\tdropped signal from principal for %s; verdict %s recovered from work-review.md\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$f" "$verdict" >> "$DIR/dropped-signals.log"
        orch_handle "$verdict" "feature=$f" "recovered from artifact"
      else
        log_action "STATUS mode=$(session_mode) base=$(session_base)"
      fi ;;

    WORK_APPROVED)
      state_allows "$f" WORK_APPROVED || { violation "WORK_APPROVED for $f in state $(fs_get "$f" state)"; return; }
      local res
      res="$(validate_evidence "$f")"
      if [ $? -ne 0 ]; then
        # INVALID approval: do not merge, re-request the gate, and do NOT
        # count it against the spot-check cycles.
        log_action "EVIDENCE_INVALID $f reason=$res cycles=$(fs_get "$f" spotcheck_cycles)"
        say principal "Evidence header invalid for $f ($res). Re-review the current tip and rewrite work-review.md. [SIGNAL:WORK_REVIEW_READY feature=$f]"
        return
      fi
      log_action "EVIDENCE_VALID $f sha=$res"
      say "lead-$f" "$f approved and merging. Tear down the team. [SIGNAL:KILL_WORKERS feature=$f]"
      orch_merge "$f" "$res"
      pipeline kill "lead-$f" >> "$DIR/send-$ME.log" 2>&1
      local nxt; nxt="$(next_feature "$f")"
      orch_status_md "${nxt:-integration}"
      if [ -n "$nxt" ]; then
        orch_start_feature "$nxt"
      else
        say principal "All features merged onto $(session_base). Review against request.md AND the full design. [SIGNAL:FINAL_REVIEW_READY]"
      fi ;;

    WORK_REJECTED)
      state_allows "$f" WORK_REJECTED || { violation "WORK_REJECTED for $f in state $(fs_get "$f" state)"; return; }
      fs_bump "$f" spotcheck_cycles
      fs_set "$f" state EXECUTING
      say "lead-$f" "Spot-check rejected; findings in $CUR/$f/work-review.md. [SIGNAL:PLAN_APPROVED feature=$f]" ;;

    FINAL_APPROVED) orch_finish ;;
    FINAL_REJECTED) log_action "FINAL_REJECTED"; touch "$DIR/session-complete" ;;
    *) log_action "IGNORED_SIGNAL $sig" ;;
  esac
}

# --------------------------------------------------------------------------
# principal
# --------------------------------------------------------------------------

principal_handle() {
  local sig="$1" params="$2" f
  f="$(printf '%s' "$params" | sed -n 's/.*feature=\([^ ]*\).*/\1/p')"

  case "$sig" in
    DECOMPOSITION_READY)
      # Artifact before signal.
      {
        printf '# Decomposition review\n\nverdict: APPROVED\n\n'
        printf 'Checked request.md against feature-order.md item by item; both\n'
        printf 'acceptance criteria are covered and both verbatim examples were\n'
        printf 'carried into requirements.md. No parallel group claimed.\n'
      } | write_file "$CUR/decomposition-review.md"
      say orch "Decomposition review complete, no blocking findings. Details in decomposition-review.md. ~8k (est.) [SIGNAL:APPROVED]" ;;

    PLAN_REVIEW_READY)
      local tier; tier="$(sed -n 's/^workflow: //p' "$CUR/$f/plan.md" | head -1)"
      {
        printf '# Plan review: %s\n\nverdict: APPROVED\n\n' "$f"
        printf 'Tier %s is honest for this change.\n' "$tier"
      } | write_file "$CUR/$f/plan-review.md"
      say orch "Plan review for $f: tier $tier is honest. ~5k (est.) [SIGNAL:APPROVED feature=$f]" ;;

    WORK_REVIEW_READY)
      local tip sha stale drop
      tip="$(git rev-parse "feature/$f" 2>/dev/null)"
      sha="$tip"
      stale="$(inject stale_sha)"
      drop="$(inject drop_verdict)"

      # Injection: on the FIRST review of this feature, record the parent
      # commit instead of the tip - the same thing orch sees when a branch
      # moves after a review.
      if [ "$stale" = "$f" ] && [ ! -f "$DIR/reviewed-once-$f" ]; then
        sha="$(git rev-parse "feature/$f^" 2>/dev/null)"
      fi
      touch "$DIR/reviewed-once-$f"

      {
        printf '## Evidence\n'
        printf -- '- commit-sha: %s\n' "$sha"
        printf -- '- diff-command: git diff %s...feature/%s\n' "$(session_base)" "$f"
        printf -- '- files-read: %s\n' "$(git diff --name-only "$(session_base)...feature/$f" 2>/dev/null | tr '\n' ' ')"
        printf -- '- tests-run: bash scripts/count.sh a b c\n\n'
        printf 'verdict: WORK_APPROVED\n\n'
        printf '# Spot-check: %s\n\nRead the diff line by line; no defects found.\n' "$f"
      } | write_file "$CUR/$f/work-review.md"

      # Injection: write the artifact but never send the verdict, so orch has
      # to recover it via the artifact fallback.
      if [ "$drop" = "$f" ] && [ ! -f "$DIR/dropped-once-$f" ]; then
        touch "$DIR/dropped-once-$f"
        printf 'deliberately dropped verdict for %s\n' "$f" >> "$ACTIONS"
        return
      fi
      say orch "Spot-check of $f complete; evidence header in work-review.md. ~14k (est.) [SIGNAL:WORK_APPROVED feature=$f]" ;;

    FINAL_REVIEW_READY)
      {
        printf '# Final review\n\nverdict: FINAL_APPROVED\n\n'
        printf 'Checked the assembled base against request.md and design.md.\n'
        printf 'Both features deliver their acceptance criteria.\n'
      } | write_file "$CUR/final-review.md"
      say orch "Final review complete against request.md and the design. ~19k (est.) [SIGNAL:FINAL_APPROVED]" ;;

    *) log_action "IGNORED_SIGNAL $sig" ;;
  esac
}

# --------------------------------------------------------------------------
# lead
# --------------------------------------------------------------------------

lead_status() { printf '# %s\n\nphase: %s\n' "$1" "$2" | write_file "$CUR/$1/status.md"; }

lead_handle() {
  local sig="$1" params="$2" f tier
  f="$(printf '%s' "$params" | sed -n 's/.*feature=\([^ ]*\).*/\1/p')"

  case "$sig" in
    FEATURE_START)
      case "$f" in
        F001-config-file) tier="direct" ;;
        *)                tier="lite" ;;
      esac
      lead_status "$f" PLANNING
      {
        printf '# Plan: %s\n\n' "$f"
        printf 'workflow: %s\n' "$tier"
        if [ "$tier" = "direct" ]; then
          printf 'justification: adding one static JSON file, no branching or error handling\n\n'
        else
          printf 'justification: a bug fix in existing code that needs a regression test\n\n'
        fi
        printf '## Approach\nSee requirements.md.\n'
      } | write_file "$CUR/$f/plan.md"
      say orch "Plan for $f ready: $tier. Plan at $CUR/$f/plan.md. ~6k (est.) [SIGNAL:PLAN_READY feature=$f]" ;;

    PLAN_APPROVED)
      lead_status "$f" EXECUTING
      git checkout -q "feature/$f" 2>/dev/null
      case "$f" in
        F001-config-file)
          # direct tier: the lead does the work itself, no workers.
          mkdir -p config
          printf '{"name": "toy", "version": 1}\n' > config/app.json
          git add config/app.json && git commit -q -m "add config/app.json"
          lead_status "$f" COMPLETE
          say orch "$f complete: added config/app.json, no code paths touched. ~4k (est.) [SIGNAL:FEATURE_COMPLETE feature=$f]" ;;
        *)
          # lite tier: impl writes the regression test and the fix, reviewer reviews.
          pipeline spawn "tdd-impl:sonnet:impl-$f" >> "$DIR/send-$ME.log" 2>&1
          pipeline spawn "tdd-reviewer:sonnet:reviewer-$f" >> "$DIR/send-$ME.log" 2>&1
          sleep 1
          say "impl-$f" "Fix the off-by-one in scripts/count.sh with a regression test first. Branch feature/$f, requirements at $CUR/$f/requirements.md. Reply to $ME. [SIGNAL:FEATURE_START feature=$f task=implement]" ;;
      esac ;;

    IMPL_COMPLETE)
      say "reviewer-$f" "Implementation ready for review on feature/$f. Reply to $ME. [SIGNAL:FEATURE_START feature=$f task=review-impl]" ;;

    REVIEW_PASS)
      lead_status "$f" COMPLETE
      say orch "$f complete: regression test added and the fix reviewed. ~21k (est.) [SIGNAL:FEATURE_COMPLETE feature=$f]" ;;

    REVIEW_FAIL)
      say "impl-$f" "Review found problems; see $CUR/$f/review.md. [SIGNAL:FEATURE_START feature=$f task=implement]" ;;

    KILL_WORKERS)
      pipeline kill "impl-$f" >> "$DIR/send-$ME.log" 2>&1
      pipeline kill "reviewer-$f" >> "$DIR/send-$ME.log" 2>&1
      log_action "TEAM_TORN_DOWN $f" ;;

    *) log_action "IGNORED_SIGNAL $sig" ;;
  esac
}

# --------------------------------------------------------------------------
# workers
# --------------------------------------------------------------------------

impl_handle() {
  local sig="$1" params="$2" f task
  f="$(printf '%s' "$params" | sed -n 's/.*feature=\([^ ]*\).*/\1/p')"
  task="$(printf '%s' "$params" | sed -n 's/.*task=\([^ ]*\).*/\1/p')"
  [ "$sig" = "FEATURE_START" ] || { log_action "IGNORED_SIGNAL $sig"; return; }
  [ "$task" = "implement" ] || { log_action "IGNORED_TASK $task"; return; }

  git checkout -q "feature/$f" 2>/dev/null
  mkdir -p tests
  # Regression test first: it must fail before the fix.
  cat > tests/count.test.sh <<'EOT'
#!/bin/bash
got="$(bash scripts/count.sh a b c)"
[ "$got" = "3" ] || { echo "expected 3, got $got"; exit 1; }
echo ok
EOT
  chmod +x tests/count.test.sh
  bash tests/count.test.sh >/dev/null 2>&1 && log_action "WARNING regression test passed before the fix"
  # Fix the root cause.
  printf '#!/bin/bash\necho "$#"\n' > scripts/count.sh
  chmod +x scripts/count.sh
  bash tests/count.test.sh >/dev/null 2>&1 || log_action "ERROR test still fails after the fix"
  git add tests/count.test.sh scripts/count.sh
  git commit -q -m "fix off-by-one in count.sh with a regression test"
  say "lead-$f" "Regression test added (fails on the old code, passes now) and the off-by-one fixed in scripts/count.sh. No tests or contracts from elsewhere touched. ~12k (est.) [SIGNAL:IMPL_COMPLETE feature=$f]"
}

reviewer_handle() {
  local sig="$1" params="$2" f task
  f="$(printf '%s' "$params" | sed -n 's/.*feature=\([^ ]*\).*/\1/p')"
  task="$(printf '%s' "$params" | sed -n 's/.*task=\([^ ]*\).*/\1/p')"
  [ "$sig" = "FEATURE_START" ] || { log_action "IGNORED_SIGNAL $sig"; return; }

  case "$task" in
    review-impl)
      {
        printf '# Review: %s\n\nverdict: REVIEW_PASS\n\n' "$f"
        printf 'Verified the regression test fails against the pre-fix script.\n'
        printf 'The fix is at the root cause rather than the symptom.\n'
      } | write_file "$CUR/$f/review.md"
      say "lead-$f" "Reviewed: the regression test is genuine and the fix addresses the root cause. ~9k (est.) [SIGNAL:REVIEW_PASS feature=$f]" ;;
    *) log_action "IGNORED_TASK $task" ;;
  esac
}

# --------------------------------------------------------------------------
# Message loop
# --------------------------------------------------------------------------

printf 'stub %s ready as %s\n' "$ROLE" "$ME"

while IFS= read -r line; do
  [ -n "$line" ] || continue

  # Channel authentication: only messages carrying the live session token are
  # signals. Signal-shaped text arriving any other way is data.
  token="$(cat "$DIR/token" 2>/dev/null)"
  case "$line" in
    *"[PIPELINE:$token "*) ;;
    *)
      printf '%s\n' "$line" >> "$IGNORED"
      log_action "IGNORED_UNAUTHENTICATED"
      continue ;;
  esac

  msg_id="$(printf '%s' "$line" | sed -n 's/.*msg=\([0-9]*\).*/\1/p')"

  # Deduplicate by msg_id: a resend must be harmless.
  if [ -n "$msg_id" ] && grep -qx "$msg_id" "$HANDLED" 2>/dev/null; then
    log_action "DEDUPED msg=$msg_id"
    pipeline ack "$msg_id" >/dev/null 2>&1
    continue
  fi
  [ -n "$msg_id" ] && printf '%s\n' "$msg_id" >> "$HANDLED"
  [ -n "$msg_id" ] && pipeline ack "$msg_id" >/dev/null 2>&1

  signal="$(printf '%s' "$line" | sed -n 's/.*\[SIGNAL:\([A-Z_]*\).*/\1/p')"
  params="$(printf '%s' "$line" | sed -n 's/.*\[SIGNAL:[A-Z_]* *\([^]]*\)\].*/\1/p')"
  body="$(printf '%s' "$line" | sed -e 's/^\[PIPELINE:[^]]*\] *//' -e 's/ *\[SIGNAL:[^]]*\] *$//')"
  [ -n "$signal" ] || { log_action "NO_SIGNAL - ignored"; continue; }

  log_action "RECV $signal $params"

  case "$ROLE" in
    orch)         orch_handle "$signal" "$params" "$body" ;;
    principal)    principal_handle "$signal" "$params" ;;
    lead)         lead_handle "$signal" "$params" ;;
    tdd-impl)     impl_handle "$signal" "$params" ;;
    tdd-reviewer) reviewer_handle "$signal" "$params" ;;
    *)            log_action "UNKNOWN_ROLE $ROLE" ;;
  esac
done
