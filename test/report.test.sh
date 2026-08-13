#!/bin/bash
# report.test.sh - build-order step 11: the report and the ablation.
#
# The claim this project rests on is that no controlled ablation of
# orchestrated versus solo agents on a coding task at matched budget has been
# published. What is testable here is not the claim but the instrument: that
# `orch report` computes its numbers from recorded facts and says so honestly
# when it has none — including saying "never ran", which is the output that
# tells you to delete a rung.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo report
printf 'report + ablation\n\n'

printf 'empty state:\n'
out="$("$ORCH" report --all 2>&1)"
chk $? "report on an empty repo exits 0"
contains "$out" "No features found" "and says there is nothing rather than printing zeros"

export ORCH_FEATURE=F020-report
"$ORCH" feature start F020-report --request "test fixture" >/dev/null 2>&1
"$ORCH" run --feature F020-report --label build -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" run --feature F020-report --label tests -- sh -c 'exit 0' >/dev/null 2>&1

printf '\nno guessed numbers:\n'
out="$("$ORCH" report F020-report 2>&1)"
contains "$out" "F020-report" "the feature appears"
contains "$out" "0·quick" "at rung 0"
not_contains "$out" "ablation" "report says nothing about an experiment nobody ran"
not_contains "$out" "escalation_precision" "and does not nag for a number it was never asked to compute"

# The experiment has its own namespace, and explains itself rather than
# appearing as an unfinished step of the normal report.
lab="$("$ORCH" lab ablation --all 2>&1)"
contains "$lab" "No baselines recorded" "orch lab ablation says there is nothing to compare"
contains "$lab" "opt-in" "and that the experiment is opt-in"
contains "$lab" "escalation_precision has no denominator" "and why partial data would not answer the question"
# A cost report is not an LLM writing "~13k (est.)". Nothing here may print an
# estimate: with no transcript to read, output tokens must be 0, not a guess.
# ORCH_TRANSCRIPTS is pointed at an empty directory so the assertion holds
# whether or not this suite happens to be running inside a live session.
export ORCH_TRANSCRIPTS="$WORK/no-transcripts"; mkdir -p "$ORCH_TRANSCRIPTS"
j="$(. "$ORCH_ROOT/lib/report.sh"; report_feature_json F020-report)"
[ "$(printf '%s' "$j" | jq -r '.usage.found')" = "0" ]
chk $? "with no transcript found, usage is reported as found:0"
[ "$(printf '%s' "$j" | jq -r '.usage.output')" = "0" ]
chk $? "and the token count is 0, not an estimate"

# And when a transcript IS there, the number comes from the file rather than
# from anybody's recollection. The session id is pinned by setup_repo, so this
# holds whether or not the suite is running inside a live Claude session — a
# ledger row records an empty session when there is none, and `// empty` does
# not drop an empty string.
sid="$(jq -s -r '[.[] | select((.session // "") != "") | .session] | .[0] // ""' \
        "$ORCH_REPO/docs/features/F020-report/ledger.jsonl")"
if [ -n "$sid" ]; then
  mkdir -p "$ORCH_TRANSCRIPTS/proj"
  printf '%s\n' \
    '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":7}}}' \
    '{"type":"assistant","message":{"usage":{"input_tokens":200,"output_tokens":60}}}' \
    '{"type":"summary","truncated-line-with-no-usage' \
    > "$ORCH_TRANSCRIPTS/proj/$sid.jsonl"
  j="$(. "$ORCH_ROOT/lib/report.sh"; report_feature_json F020-report)"
  [ "$(printf '%s' "$j" | jq -r '.usage.output')" = "100" ]
  chk $? "output tokens are summed from the transcript's usage events"
  [ "$(printf '%s' "$j" | jq -r '.usage.cache_read')" = "7" ]
  chk $? "cache reads are counted too"
  ok "a truncated final line — normal for a live session — did not break the sum"
else
  bad "no session id in the ledger to attach a transcript to"
fi
unset ORCH_TRANSCRIPTS

printf '\ngate yield:\n'
"$ORCH" gate check F020-report human >/dev/null 2>&1
"$ORCH" approve F020-report --gate human >/dev/null 2>&1
"$ORCH" gate check F020-report human >/dev/null 2>&1
j="$(. "$ORCH_ROOT/lib/report.sh"; report_feature_json F020-report)"
[ "$(printf '%s' "$j" | jq -r '.gates.checked')" = "2" ]; chk $? "both gate checks were counted"
[ "$(printf '%s' "$j" | jq -r '.gates.blocked')" = "1" ]; chk $? "the one that blocked was counted as blocked"
[ "$(printf '%s' "$j" | jq -r '.gates.yield_pct')" = "50" ]; chk $? "gate yield is 50%"

printf '\nstages that never ran say so:\n'
contains "$out" "never ran" "a stage with no data is reported as never having run"

printf '\nuptake against the published baseline:\n'
"$ORCH" findings add F020-report --raised-by correctness --severity major \
  --file src/calc.py --line 2 --claim c --consequence q >/dev/null 2>&1
"$ORCH" findings verify F020-report >/dev/null 2>&1
out="$("$ORCH" report F020-report 2>&1)"
contains "$out" "33.6" "the 33.6% figure from [P11] is printed as the thing to beat"

printf '\nreviewer yield across features:\n'
contains "$out" "deletion candidate" "a lens with no unique yield is named as deletable"

printf '\nablation, once the experiment has been run:\n'
# Synthesise a baseline rather than spending a real one: the arithmetic is what
# is under test, and a live `claude -p` run would make this suite non-hermetic.
cat > "$ORCH_REPO/docs/features/F020-report/baseline.json" <<'EOF'
{"feature":"F020-report","ran_at":"2026-01-01T00:00:00Z","exit_code":0,
 "solo_passed":false,"total_cost_usd":0.42,"output_tokens":1000,"duration_ms":60000}
EOF
"$ORCH" escalate to F020-report 3 "test fixture" >/dev/null 2>&1
out="$("$ORCH" report F020-report 2>&1)"
contains "$out" "solo-failed" "the ablation table appears once a baseline exists"
contains "$out" "escalation_precision: 100%" "escalation_precision is computed from the solo outcome"
contains "$out" "3–10x" "published multipliers are printed for comparison"
contains "$out" "trigger-happy" "and low precision is explained as a threshold problem"

printf '\nthe baseline refuses to guess:\n'
out="$("$ORCH" lab baseline F021-missing 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "a baseline for a feature with no requirements.md is refused"
contains "$out" "nothing to give the solo agent" "and the reason is the missing input"

printf '\nwatch renders without tmux:\n'
out="$(ORCH_WATCH_ONCE=1 "$ORCH" watch 2>&1)"
chk $? "orch watch exits 0"
contains "$out" "F020-report" "it renders feature state"
contains "$out" "rung 3" "including the rung"
not_contains "$out" "tmux" "with no tmux anywhere in the path"

finish report
