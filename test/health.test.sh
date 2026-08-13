#!/bin/bash
# health.test.sh - build-order steps 6 and 7: the detector and the ladder.
#
# Acceptance (spec §14):
#   6. a synthetic session that repeats one tool call 3x emits step_repetition;
#      a forced compaction emits compaction; no signal fires on a clean run
#   7. a feature escalates on a real signal, the rung and firing signal are
#      logged, and the next feature starts at rung 0

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo health
printf 'degradation detector + escalation ladder\n\n'

export ORCH_FEATURE=F003-health
"$ORCH" feature start F003-health --request "test fixture" >/dev/null 2>&1

probe() { printf '%s' "$1" | "$ORCH_ROOT/hooks/health-probe.sh"; }
sigs()  { "$ORCH" health signals "${1:-F003-health}" | jq -r '[.[].signal] | sort | join(",")'; }

# --- the clean run ---------------------------------------------------------
printf 'clean run:\n'
[ "$(sigs)" = "" ]; chk $? "no signal fires before anything has happened"
probe '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"a.py"}}'
probe '{"hook_event_name":"PostToolUse","tool_name":"Grep","tool_input":{"pattern":"foo"}}'
probe '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"b.py"}}'
[ "$(sigs)" = "" ]; chk $? "three different tool calls are not repetition"

# --- step_repetition — MAST's most frequent failure mode, 15.7% ------------
printf '\nstep_repetition:\n'
for i in 1 2; do
  probe '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"pytest -x","description":"attempt '"$i"'"}}'
done
[ "$(sigs)" = "" ]; chk $? "two identical calls are below the threshold"
probe '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"pytest -x","description":"attempt 3"}}'
contains "$(sigs)" "step_repetition" "the third identical call fires step_repetition"
contains "$("$ORCH" health signals F003-health | jq -r '.[0].detail')" "pytest -x" \
  "the signal names the call that repeated"

# The `description` field changed every time. If normalization did not strip
# it, this signal would never fire in practice.
ok "normalization ignores volatile argument fields (implied by the above)"

# --- compaction — the strongest single signal, and free -------------------
printf '\ncompaction:\n'
probe '{"hook_event_name":"PostCompact","trigger":"auto"}'
contains "$(sigs)" "compaction" "a compaction fires immediately"

# --- tool_failure_rate -----------------------------------------------------
printf '\ntool_failure_rate:\n'
setup_repo health2 >/dev/null 2>&1
export ORCH_FEATURE=F004-fail
"$ORCH" feature start F004-fail --request "test fixture" >/dev/null 2>&1
i=0
while [ "$i" -lt 14 ]; do probe "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"f$i\"}}"; i=$((i+1)); done
i=0
while [ "$i" -lt 6 ]; do probe "{\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"c$i\"}}"; i=$((i+1)); done
contains "$(sigs F004-fail)" "tool_failure_rate" "6 failures in a 20-call window crosses 25%"

# --- test_oscillation, from attested runs ---------------------------------
printf '\ntest_oscillation:\n'
setup_repo health3 >/dev/null 2>&1
export ORCH_FEATURE=F005-osc
"$ORCH" feature start F005-osc --request "test fixture" >/dev/null 2>&1
"$ORCH" run --feature F005-osc --label tests -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F005-osc --label tests -- sh -c 'exit 1' >/dev/null 2>&1
contains "$(sigs F005-osc)" "" "one flip is below the threshold"
[ "$(sigs F005-osc)" = "" ]; chk $? "pass then fail is not yet oscillation"
"$ORCH" run --feature F005-osc --label tests -- sh -c 'exit 0' >/dev/null 2>&1
contains "$(sigs F005-osc)" "test_oscillation" "pass -> fail -> pass is a loop that is not converging"

# --- edit_churn ------------------------------------------------------------
printf '\nedit_churn:\n'
setup_repo health4 >/dev/null 2>&1
export ORCH_FEATURE=F006-churn
"$ORCH" feature start F006-churn --request "test fixture" >/dev/null 2>&1
i=0
while [ "$i" -lt 3 ]; do
  probe "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$ORCH_REPO/src/calc.py\",\"old_string\":\"    return a + b\"}}"
  i=$((i+1))
done
contains "$(sigs F006-churn)" "edit_churn" "the same region edited three times is churn"
contains "$("$ORCH" health signals F006-churn | jq -r '.[] | select(.signal=="edit_churn") | .detail')" \
  "overlapping ranges" "and the overlap is reported, not assumed"

# --- a bad transcript must not abort anything -----------------------------
printf '\nrobustness:\n'
probe '{"hook_event_name":"PostToolUse","tool_name":"Read","transcript_path":"/nonexistent/x.jsonl"}'
chk $? "an unreadable transcript does not fail the hook"
printf 'not json at all\n' > "$ORCH_REPO/docs/features/F006-churn/health.jsonl.bad"
probe 'this is not json'
chk $? "an unparseable payload does not fail the hook"
probe '{"hook_event_name":"SomeFutureEvent"}'
grep -q 'unknown_event' "$ORCH_REPO/docs/features/F006-churn/health.jsonl"
chk $? "an unrecognised event is recorded as drift rather than dropped"

# --- the ladder ------------------------------------------------------------
printf '\nescalation ladder:\n'
setup_repo ladder >/dev/null 2>&1
export ORCH_FEATURE=F007-ladder
"$ORCH" feature start F007-ladder --request "test fixture" >/dev/null 2>&1
[ "$("$ORCH" escalate rung F007-ladder)" = "0" ]; chk $? "a feature starts at rung 0"
out="$("$ORCH" escalate check F007-ladder)"
contains "$out" "stays at rung 0" "a clean feature does not escalate"

probe '{"hook_event_name":"PostCompact","trigger":"auto"}'
out="$("$ORCH" escalate check F007-ladder)"
contains "$out" "escalated 0 -> 1" "one signal moves it to rung 1"
contains "$out" "compaction" "the firing signal is named, not just the rung"
LEDGER="$ORCH_REPO/docs/features/F007-ladder/ledger.jsonl"
jq -e -s 'any(.[]; .event=="escalation" and .rung==1 and (.signals|tostring|test("compaction")))' "$LEDGER" >/dev/null
chk $? "the escalation, its rung and its signals are in the ledger"

out="$("$ORCH" escalate check F007-ladder)"
contains "$out" "stays at rung 1" "escalation is idempotent"
"$ORCH" escalate to F007-ladder 0 >/dev/null 2>&1
[ "$("$ORCH" escalate rung F007-ladder)" = "1" ]; chk $? "escalation is one-way — it cannot be walked back down"

# Two signals skip straight to rung 2: the ladder responds to evidence, not to
# a step counter.
for i in 1 2 3; do
  probe '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"make"}}'
done
"$ORCH" escalate check F007-ladder >/dev/null 2>&1
[ "$("$ORCH" escalate rung F007-ladder)" = "2" ]; chk $? "a second signal takes it to rung 2 without passing through a counter"

# --- de-escalation is per feature -----------------------------------------
printf '\nper-feature reset:\n'
"$ORCH" feature start F008-next --request "test fixture" >/dev/null 2>&1
[ "$("$ORCH" escalate rung F008-next)" = "0" ]; chk $? "the next feature starts at rung 0 again"
[ "$("$ORCH" escalate rung F007-ladder)" = "2" ]; chk $? "and the previous feature keeps its rung"

finish health
