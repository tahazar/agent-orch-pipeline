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

printf 'a feature needs something to build:\n'
out="$("$ORCH" feature start F019-noreq 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "starting a feature with no --request is refused"
contains "$out" "what
you are asking for" "and says why the crew cannot proceed without it"

# The request is COPIED, not referenced. Editing your spec mid-run must not
# silently change what the crew was asked to build, and the frozen copy is what
# a solo baseline gets so the comparison is against the same input.
printf 'spec v1\n' > "$ORCH_REPO/spec.md"
"$ORCH" feature start F018-frozen --request "$ORCH_REPO/spec.md" >/dev/null 2>&1
printf 'spec v2 — changed my mind\n' > "$ORCH_REPO/spec.md"
frozen="$(cat "$ORCH_REPO/docs/features/F018-frozen/request.md")"
[ "$frozen" = "spec v1" ]; chk $? "the request is frozen at start, not followed by reference"

printf '\neach feature gets its own branch:\n'
[ "$(git -C "$ORCH_REPO" rev-parse --abbrev-ref HEAD)" = "feature/F018-frozen" ]
chk $? "feature start checks out feature/<F>"
# Best-of-N takes refs under orch/<F>/cN, and git cannot hold a branch named
# orch/<F> and a directory of refs beneath it at the same time.
case "$(git -C "$ORCH_REPO" rev-parse --abbrev-ref HEAD)" in
  orch/*) bad "the feature branch is in the namespace best-of-N needs for candidates" ;;
  *) ok "and stays clear of the namespace best-of-N uses" ;;
esac
git -C "$ORCH_REPO" checkout -q main 2>/dev/null || git -C "$ORCH_REPO" checkout -q master

printf '\na feature starts with no tier and therefore no crew:\n'
out="$("$ORCH" feature start F020-tier --request "test fixture" 2>&1)"
contains "$out" "No tier yet, so no crew yet" "starting a feature does not choose a tier for you"
contains "$out" "orch spawn tech-lead --feature F020-tier" "and it names the command that summons the tech-lead — the recommender must be summonable"
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
out="$("$ORCH" feature start F021-strict --request "test fixture" --tier strict 2>&1)"
contains "$out" "strict" "a tier can be named at feature start"
[ "$("$ORCH" escalate rung F021-strict)" = "2" ]; chk $? "strict is rung 2"
crew="$("$ORCH" tier crew F021-strict)"
contains "$crew" "test-engineer" "strict adds the blind test author"
contains "$crew" "code-reviewer" "and keeps the code-reviewer"

out="$("$ORCH" feature start F022-bad --request "test fixture" --tier turbo 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "an unknown tier is refused rather than defaulted"
contains "$out" "quick standard strict" "and the refusal lists the real ones"

printf '\nconfirming needs something to confirm:\n'
"$ORCH" feature start F023-none --request "test fixture" >/dev/null 2>&1
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
