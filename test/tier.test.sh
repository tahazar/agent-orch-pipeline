#!/bin/bash
# tier.test.sh - the developer's half of the ladder.
#
# The properties worth asserting are the ones that stop a tier from quietly
# becoming a preference rather than a decision:
#
#   - nothing is spawned before a human confirms
#   - a recommendation without a stated reason is refused
#   - a tier sets a floor, never a ceiling: it cannot walk back an escalation
#   - a signal can still raise a developer-chosen tier
#   - the crew is derived from the rung and nowhere else

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
setup_repo tier
trap teardown_repo EXIT

printf 'tiers\n\n'

printf 'a feature starts with no tier and therefore no crew:\n'
out="$("$ORCH" feature start F020-tier 2>&1)"
contains "$out" "No tier yet, so no crew yet" "starting a feature does not choose a tier for you"
[ "$("$ORCH" tier show F020-tier | jq -r '.is_confirmed')" = "false" ]
chk $? "the tier is unconfirmed"
[ "$("$ORCH" tier show F020-tier | jq -r '.confirmed')" = "" ]
chk $? "and nothing is recorded as confirmed"

printf '\na recommendation is not a decision:\n'
out="$("$ORCH" tier recommend F020-tier standard 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "recommending without --why is refused"
contains "$out" "a guess" "and the refusal says why that matters"

out="$("$ORCH" tier recommend F020-tier standard --why "three files and real branching" 2>&1)"
contains "$out" "Nothing is spawned until a human confirms" "a recommendation says it is not binding"
[ "$("$ORCH" escalate rung F020-tier)" = "0" ]
chk $? "recommending alone does not move the rung"
[ "$("$ORCH" tier show F020-tier | jq -r '.is_confirmed')" = "false" ]
chk $? "and does not confirm anything"

printf '\nconfirming takes the recommendation and sizes the crew:\n'
out="$("$ORCH" tier confirm F020-tier 2>&1)"
contains "$out" "standard" "confirming with no argument takes the recommendation"
[ "$("$ORCH" escalate rung F020-tier)" = "1" ]; chk $? "standard is rung 1"
crew="$("$ORCH" tier crew F020-tier)"
contains "$crew" "code-reviewer" "standard includes an independent code-reviewer"
not_contains "$crew" "test-engineer" "standard does not pay for a separate test author"
not_contains "$crew" "director" "the director is not per-feature crew"
not_contains "$crew" "auditor" "nor is the auditor"

printf '\na tier is a floor, never a ceiling:\n'
out="$("$ORCH" tier confirm F020-tier --tier quick 2>&1)"
contains "$out" "does not lower it" "confirming a lower tier says so plainly"
[ "$("$ORCH" escalate rung F020-tier)" = "1" ]
chk $? "and the rung does not walk back down"

printf '\nsignals still raise a developer-chosen tier:\n'
# Two DISTINCT signals, not two observations of one: the ladder counts firing
# signals, so compacting twice is still a single piece of evidence.
"$ORCH" health observe --feature F020-tier --kind compaction >/dev/null 2>&1
"$ORCH" health observe --feature F020-tier --kind context --pct 85 >/dev/null 2>&1
[ "$("$ORCH" health signals F020-tier | jq 'length')" = "2" ]
chk $? "two distinct signals are firing"
out="$("$ORCH" escalate check F020-tier 2>&1)"
[ "$("$ORCH" escalate rung F020-tier)" -ge 2 ]
chk $? "asking for a tier does not buy immunity from the evidence"
contains "$("$ORCH" tier crew F020-tier)" "test-engineer" "and the crew grows to match the rung"

printf '\nchoosing up front skips the recommendation:\n'
out="$("$ORCH" feature start F021-strict --tier strict 2>&1)"
contains "$out" "strict" "a tier can be named at feature start"
[ "$("$ORCH" escalate rung F021-strict)" = "2" ]; chk $? "strict is rung 2"
crew="$("$ORCH" tier crew F021-strict)"
contains "$crew" "test-engineer" "strict adds the blind test author"
contains "$crew" "code-reviewer" "and keeps the code-reviewer"

out="$("$ORCH" feature start F022-bad --tier turbo 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "an unknown tier is refused rather than defaulted"
contains "$out" "quick standard strict" "and the refusal lists the real ones"

printf '\nconfirming needs something to confirm:\n'
"$ORCH" feature start F023-none >/dev/null 2>&1
out="$("$ORCH" tier confirm F023-none 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "confirming with no recommendation and no --tier is refused"
contains "$out" "nothing to confirm" "rather than silently defaulting to a tier"

printf '\nthe decision is on disk, and says who made it:\n'
LEDGER="$ORCH_REPO/docs/features/F020-tier/ledger.jsonl"
jq -e -s 'any(.[]; .event=="tier.recommended" and .tier=="standard" and (.why|length>0))' "$LEDGER" >/dev/null
chk $? "the recommendation and its reason are in the ledger"
jq -e -s 'any(.[]; .event=="tier.confirmed" and .tier=="standard")' "$LEDGER" >/dev/null
chk $? "so is the confirmation"
jq -e -s 'any(.[]; .event=="escalation" and (.reason|test("confirmed by a human")))' "$LEDGER" >/dev/null
chk $? "a human-chosen rung is distinguishable from a signal-forced one"

finish tier
