#!/bin/bash
# status.test.sh - status is rendered, never authored.
#
# The property under test is derivation: every fact in status.md must come from
# a source of record, so regenerating after an edit must destroy the edit, and
# every state change must show up without anyone writing prose about it.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
setup_repo status
trap teardown_repo EXIT

printf 'generated status\n\n'

"$ORCH" feature start F040-status --request "test fixture" --tier standard >/dev/null 2>&1
enter_feature F040-status >/dev/null 2>&1 || true
ST="$ORCH_REPO/docs/features/F040-status/status.md"

printf 'the rendering is derived:\n'
out="$("$ORCH" status show F040-status)"
[ -s "$ST" ]; chk $? "status render writes status.md"
contains "$out" "GENERATED" "and the file says it is generated"
contains "$out" "do not edit" "and says editing is futile"
contains "$out" "standard" "the tier comes from the ledger"
contains "$out" "feature/F040-status" "the branch comes from feature.started"

printf '\nstate changes appear without anyone writing prose:\n'
"$ORCH" run --feature F040-status --label tests -- sh -c 'exit 0' >/dev/null 2>&1
"$ORCH" approve F040-status --gate human >/dev/null 2>&1
"$ORCH" findings add F040-status --raised-by correctness --severity blocking \
  --file src/calc.py --line 2 --claim "adds wrong" --consequence "wrong sums" >/dev/null 2>&1
out="$("$ORCH" status show F040-status)"
contains "$out" '`tests`: exit 0' "an attested run appears"
contains "$out" '`human`: **met**' "an approval appears"
contains "$out" "adds wrong" "an open finding appears"

printf '\nediting the file is futile, which is the point:\n'
printf 'HAND-WRITTEN LIE: everything is fine\n' >> "$ST"
"$ORCH" status render F040-status >/dev/null 2>&1
grep -q "HAND-WRITTEN LIE" "$ST"; [ $? != 0 ]
chk $? "a hand edit does not survive a render — the ledger is the source, not the file"

printf '\ndecisions are events, not a hand-numbered log:\n'
out="$("$ORCH" decision record F040-status --text "reject rows, do not pad" --why "padding hid data loss")"
contains "$out" "decision #1" "the first decision is #1"
out="$("$ORCH" decision record F040-status --text "BOM is stripped")"
contains "$out" "decision #2" "numbering derives from the ledger count"
out="$("$ORCH" decision record F040-status 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "a decision with no text is refused"

out="$("$ORCH" decision list F040-status)"
contains "$out" "#1  reject rows" "the list renders from the ledger"
contains "$out" "why: padding hid data loss" "with the reason attached"
out="$("$ORCH" status show F040-status)"
contains "$out" "**#2** BOM is stripped" "and decisions appear in the status rendering"

LEDGER="$ORCH_REPO/docs/features/F040-status/ledger.jsonl"
jq -e -s '[.[] | select(.event=="decision.recorded")] | length == 2' "$LEDGER" >/dev/null
chk $? "both decisions are ledger rows, greppable forever"

printf '\nempty sections say so:\n'
"$ORCH" feature start F041-bare --request "test fixture" >/dev/null 2>&1
enter_feature F041-bare >/dev/null 2>&1 || true
out="$("$ORCH" status show F041-bare)"
contains "$out" "no gate has been set" "an empty gates section names itself"
contains "$out" "nothing attested yet" "so does an empty evidence section"
contains "$out" "none recorded" "and an empty decisions section"
contains "$out" "no tier yet" "a missing tier is called out, not omitted"
"$ORCH" tier recommend F041-bare quick --why "one line" >/dev/null 2>&1
out="$("$ORCH" status show F041-bare)"
contains "$out" "unconfirmed, no crew" "a recommended-but-unconfirmed tier says exactly that"


printf '\ndead ends are decisions with a kind, and they travel with the orders:\n'
out="$("$ORCH" decision record F040-status --kind dead-end --text "cache the parsed header" 2>&1)"; rc=$?
chk_rc 1 "$rc" "a dead end without a reason is refused"
out="$("$ORCH" decision record F040-status --kind dead-end --text "cache the parsed header" --why "the header is re-read per row; caching moved the cost" --evidence perf 2>&1)"; rc=$?
chk_rc 0 "$rc" "a dead end with a reason records"
contains "$out" "dead end #3 recorded" "numbered with the decisions"
contains "$out" "told not to retry it" "and says what happens next"
out="$("$ORCH" decision record F040-status --kind guess --text "x" 2>&1)"; rc=$?
chk_rc 1 "$rc" "an unknown kind is refused"
out="$("$ORCH" decision list F040-status 2>&1)"
contains "$out" "#3  DEAD END  cache the parsed header" "list marks it"
contains "$out" "(attested: perf)" "with the run that showed it"
out="$("$ORCH" decision deadends F040-status 2>&1)"
contains "$out" "do NOT retry them" "deadends renders the paragraph"
contains "$out" "(#3) cache the parsed header — the header is re-read per row; caching moved the cost [attested run: perf]" "verbatim, with the reason and the evidence"
not_contains "$out" "reject rows" "and not the ordinary decisions"
out="$(ORCH_HOME="$ORCH_ROOT" bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_orders developer F040-status' 2>/dev/null)"
contains "$out" "Dead ends already on the ledger" "the developer's orders carry it"
contains "$out" "cache the parsed header" "verbatim"
out="$(ORCH_HOME="$ORCH_ROOT" bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_orders test-engineer F040-status' 2>/dev/null)"
not_contains "$out" "Dead ends" "the test-engineer's do not"

finish status
