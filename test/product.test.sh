#!/bin/bash
# product.test.sh - the product layer: personas, stories, the chain, the
# walkthrough, the night and the morning.
#
# What matters here:
#   - the chain is traced mechanically: persona -> story -> feature -> state;
#     a story naming no persona, a persona with no evidence line, and a
#     feature no story asked for are each named, and trace exits 1
#   - personas and stories are frozen by hash; a silent edit is PRODUCT_MOVED
#     and plan refuses until the human re-freezes with a reason
#   - plan writes one feature per story, the request from the story, the tier
#     from the story, `after:` as the feature graph; it is idempotent
#   - a feature built for a hypothesized persona is exploratory: the morning
#     says so and keep refuses it without the flag
#   - the walkthrough is a code-reviewer lens denied source, tests and every
#     feature artifact; its record is a gate at HEAD, and a story-backed
#     feature cannot land without it
#   - the morning leads with the walkthrough; keep lands, iterate re-freezes
#     the request, discard writes the reason against the persona and the
#     story can be planned again

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo product
export ORCH_LAUNCHER=print ORCH_NO_FLOCK=1 ORCH_TEST_CMD='exit 0'
printf 'the product layer\n\n'

# read_as <path> <role> [lens] -> rc of the artifact-scope hook
read_as() {
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1" \
    | ORCH_ROLE="$2" ORCH_LENS="${3:-}" "$ORCH_ROOT/hooks/artifact-scope.sh" 2>&1
}
write_as() {  # write_as <path> <role>
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | ORCH_ROLE="$2" "$ORCH_ROOT/hooks/write-scope.sh" 2>&1
}

printf 'the layer:\n'
out="$("$ORCH" product trace 2>&1)"; rc=$?
chk_rc 1 "$rc" "a product command refuses while the layer is off"
contains "$out" "orch init --profile product" "and names the profile that turns it on"
"$ORCH" init --profile product >/dev/null 2>&1
contains "$("$ORCH" layers 2>&1)" "floor crew upkeep product" "init --profile product turns everything on"
out="$("$ORCH" product trace 2>&1)"; rc=$?
chk_rc 1 "$rc" "with nothing under docs/product, trace refuses"
contains "$out" "docs/product/personas/<slug>.md" "and shows the layout"

printf '\nthe chain:\n'
mkdir -p docs/product/personas docs/product/stories
cat > docs/product/personas/maya.md <<'MD'
# Maya, the weekly exporter
evidence: observed
sources: support tickets 2026-Q2; interview 3

Runs the Monday report. Exports last week's numbers to a spreadsheet every
Monday and does not read release notes.
MD
cat > docs/product/personas/sam.md <<'MD'
# Sam, the ops lead
evidence: hypothesized

Would automate the export if it could be scheduled. Nobody has met Sam.
MD
cat > docs/product/stories/S001-export-week.md <<'MD'
# S001 Export the week as CSV
persona: maya
tier: standard
metric: exports_per_user up

As Maya, I want last week's numbers as a CSV in one click, so that Monday
takes ten minutes instead of an hour.

## Acceptance
- From the dashboard, one action produces a CSV of the previous Monday–Sunday
- The file opens in a spreadsheet with the columns named
MD
cat > docs/product/stories/S002-schedule-export.md <<'MD'
# S002 Schedule the weekly export
persona: sam
after: S001

As Sam, I want the weekly CSV to arrive by email on Monday morning.
MD
cat > docs/product/stories/S003-broken.md <<'MD'
# S003 Nobody asked
persona: nobody
MD
git add -A && git commit -q -m "personas and stories"
out="$("$ORCH" product trace 2>&1)"; rc=$?
chk_rc 1 "$rc" "trace exits 1 on a broken link"
contains "$out" "frozen: never" "nothing is frozen yet"
contains "$(printf '%s' "$out" | grep '^maya')" "observed" "maya is observed"
contains "$(printf '%s' "$out" | grep '^maya')" "S001" "and S001 is her story"
contains "$(printf '%s' "$out" | grep '^sam')" "hypothesized" "sam is a hypothesis"
contains "$(printf '%s' "$out" | grep '^S003')" "BROKEN — no such persona" "S003 names a persona that does not exist"
contains "$(printf '%s' "$out" | grep '^S001')" "unplanned" "S001 has no feature yet"
rm docs/product/stories/S003-broken.md; git add -A && git commit -q -m "drop S003"
"$ORCH" product trace >/dev/null 2>&1; chk $? "with the link fixed, trace exits 0"

printf '\nplan writes features from stories:\n'
out="$("$ORCH" product plan 2>&1)"; rc=$?
chk_rc 0 "$rc" "plan runs"
contains "$out" "F001-export-week  S001  as maya (observed)" "S001 becomes F001-export-week, for maya"
contains "$out" "F002-schedule-export  S002  as sam (hypothesized)  EXPLORATORY" "S002 becomes F002, and it is exploratory"
req="$(cat "$(fdir F001-export-week)/request.md")"
contains "$req" "Export the week as CSV" "the request is the story"
contains "$req" "Story: S001 (persona: maya, evidence: observed)" "with the citation line"
[ "$("$ORCH" tier show F001-export-week | jq -r .running)" = standard ]; chk $? "at the story's tier, confirmed"
contains "$("$ORCH" waves 2>&1 | grep F002)" "waiting for F001-export-week" "after: S001 became the feature edge"
jq -e -s 'any(.[]; .event=="product.frozen")' docs/features/_orch/ledger.jsonl >/dev/null; chk $? "plan froze the personas and stories"
jq -e -s 'any(.[]; .event=="product.planned" and .story=="S001" and .exploratory==false)' "$(fdir F001-export-week)/ledger.jsonl" >/dev/null; chk $? "the feature's ledger says which story, and that it is not exploratory"
out="$("$ORCH" product plan 2>&1)"
contains "$out" "F001-export-week  S001  (exists)" "a second plan does not plan S001 twice"
[ -z "$(ls .orch/worktrees | grep F003)" ]; chk $? "and starts no third feature"

printf '\nfrozen:\n'
printf -- '- The columns are dated\n' >> docs/product/stories/S001-export-week.md
out="$("$ORCH" product check 2>&1)"; rc=$?
chk_rc 9 "$rc" "an edited story is PRODUCT_MOVED (exit 9)"
contains "$out" "stories/S001-export-week.md" "naming the file"
out="$("$ORCH" product plan 2>&1)"; rc=$?
chk_rc 1 "$rc" "plan refuses while it is moved"
"$ORCH" product freeze --why "sharpened after reading the export" >/dev/null 2>&1
"$ORCH" product check >/dev/null 2>&1; chk $? "re-frozen with a reason, check passes"
git add -A && git commit -q -m "sharpen S001"

printf '\nthe night:\n'
out="$("$ORCH" product night --budget 5 2>&1)"; rc=$?
chk_rc 0 "$rc" "night runs"
contains "$out" "1 crew(s) started" "one crew: F001 is ready, F002 waits for it"
contains "$("$ORCH" product trace 2>&1 | grep '^S001')" "running" "S001's feature is running"
contains "$("$ORCH" product trace 2>&1 | grep '^S002')" "blocked" "S002's is blocked"

printf '\nthe walkthrough is a user, not a reviewer:\n'
out="$("$ORCH" walkthrough orders F001-export-week 2>&1)"
contains "$out" "You are maya" "the orders make the session the persona"
contains "$out" "Runs the Monday report" "with the persona file"
contains "$out" "Export the week as CSV" "and the story"
contains "$out" "--raised-by walkthrough" "findings are raised as the walkthrough"
contains "$out" "orch walkthrough record F001-export-week" "and the record is the gate"
"$ORCH" walkthrough start F001-export-week >/dev/null 2>&1; chk $? "start spawns it (print launcher)"
jq -e -s 'any(.[]; .event=="agent.printed" and .role=="code-reviewer" and .lens=="walkthrough")' "$(fdir F001-export-week)/ledger.jsonl" >/dev/null
chk $? "as a code-reviewer with the walkthrough lens"
enter_feature F001-export-week
mkdir -p docs/features/F001-export-week; printf 'R1 one click\n' > docs/features/F001-export-week/requirements.md
out="$(read_as "$ORCH_REPO/src/calc.py" code-reviewer walkthrough)"; rc=$?
chk_rc 2 "$rc" "the walkthrough may not read source"
out="$(read_as "$ORCH_REPO/test/test_calc.py" code-reviewer walkthrough)"; rc=$?
chk_rc 2 "$rc" "nor tests"
out="$(read_as "$ORCH_REPO/docs/features/F001-export-week/requirements.md" code-reviewer walkthrough)"; rc=$?
chk_rc 2 "$rc" "nor the feature's artifacts"
contains "$out" "a person using the product" "and is told why"
out="$(read_as "$ORCH_REPO/docs/product/personas/maya.md" code-reviewer walkthrough)"; rc=$?
chk_rc 0 "$rc" "it may read the persona"
out="$(read_as "$ORCH_REPO/README.md" code-reviewer walkthrough)"; rc=$?
chk_rc 0 "$rc" "and the repo's README"
out="$(read_as "$ORCH_REPO/src/calc.py" code-reviewer correctness)"; rc=$?
chk_rc 0 "$rc" "an ordinary lens still reads source"
out="$(write_as "$MAIN/docs/product/personas/maya.md" developer)"; rc=$?
chk_rc 2 "$rc" "no role writes a persona"
contains "$out" "the human's" "they are the human's"
out="$(write_as "$MAIN/docs/product/stories/S001-export-week.md" tech-lead)"; rc=$?
chk_rc 2 "$rc" "not even the tech-lead"

printf '\nthe gate:\n'
printf 'def export_week():\n    return "a,b\\n1,2\\n"\n' >> src/calc.py
git add -A && git commit -q -m "export"
"$ORCH" run --feature F001-export-week --label tests -- sh -c 'exit 0' >/dev/null 2>&1
leave_feature
out="$("$ORCH" product keep F001-export-week 2>&1)"; rc=$?
chk_rc 1 "$rc" "keep refuses before the persona has tried it"
contains "$out" "has not reached the goal" "saying so"
contains "$out" "orch walkthrough start F001-export-week" "and how to run it"
out="$("$ORCH" walkthrough record F001-export-week --outcome blocked --steps 9 --note "could not find export" 2>&1)"
contains "$out" "BLOCKED after 9 step(s)" "a blocked walkthrough is recorded"
out="$("$ORCH" product keep F001-export-week 2>&1)"; rc=$?
chk_rc 1 "$rc" "and does not open the gate"
out="$("$ORCH" walkthrough record F001-export-week --outcome nearly --steps 4 2>&1)"; rc=$?
chk_rc 1 "$rc" "an outcome that is not done or blocked is refused"
out="$("$ORCH" walkthrough record F001-export-week --outcome done --steps four 2>&1)"; rc=$?
chk_rc 1 "$rc" "steps must be a number"
out="$("$ORCH" walkthrough record F001-export-week --outcome done --steps 4 --minutes 3 --note "the button says Download" 2>&1)"; rc=$?
chk_rc 0 "$rc" "a finished walkthrough records"
contains "$out" "gate \`walkthrough\` met" "and meets the gate"
contains "$("$ORCH" walkthrough status F001-export-week 2>&1)" "maya reached the goal in 4 step(s), 3 min at HEAD" "status reads it back"
"$ORCH" findings add F001-export-week --raised-by walkthrough --severity minor --file "dashboard" --line 0 \
  --claim "as maya, the export is called Download and I looked for Export" --consequence "a minute lost every Monday" >/dev/null 2>&1
out="$("$ORCH" packet F001-export-week 2>&1)"
contains "$out" "0. the walkthrough — story S001, as maya" "the packet leads with the walkthrough"
[ "$(printf '%s' "$out" | grep -n '0. the walkthrough' | cut -d: -f1)" -lt "$(printf '%s' "$out" | grep -n '1. what was asked' | cut -d: -f1)" ]
chk $? "before what was asked"
contains "$out" "as maya, the export is called Download" "with the persona's findings"

printf '\nthe morning:\n'
out="$("$ORCH" product morning 2>&1)"; rc=$?
chk_rc 0 "$rc" "morning renders"
contains "$out" "F001-export-week  S001  as maya (observed)   running" "F001, its story, its persona, its state"
contains "$out" "walkthrough: maya reached the goal in 4 step(s), 3 min at HEAD" "the walkthrough first"
contains "$out" "tests: exit 0" "then the tests"
contains "$out" "open findings: 1" "and the open findings"
contains "$out" "F002-schedule-export  S002  as sam (hypothesized)   blocked   EXPLORATORY" "F002 is blocked and exploratory"
contains "$out" "waiting for F001-export-week" "and says what it waits for"
contains "$out" "orch product keep F001-export-week" "with the verbs"

printf '\nthe metrics loop, before the landing:\n'
cat > docs/product/metrics.md <<'MD'
# Metrics
- exports_per_user: up — exports per weekly active user
- error_rate: down guardrail — 5xx per 1k requests
- p95_ms: down guardrail holdout — dashboard p95
- not a metric line
MD
git add -A && git commit -q -m "metrics"
out="$("$ORCH" product metrics 2>&1)"; rc=$?
chk_rc 0 "$rc" "metrics renders with no readings"
contains "$out" "exports_per_user     up   no reading" "a metric with no reading says so"
contains "$out" "p95_ms               down guardrail HOLDOUT" "the holdout is marked for the human"
contains "$out" "none kept yet" "no hypothesis to judge yet"
"$ORCH" run --feature _orch --label metrics -- sh -c 'printf "exports_per_user 12\nerror_rate 3\np95_ms 400\nbad line here\n"' >/dev/null 2>&1
contains "$("$ORCH" product metrics 2>&1)" "exports_per_user     up   12 at" "an attested reading is read"
out="$(read_as "$MAIN/docs/product/metrics.md" code-reviewer walkthrough)"; rc=$?
chk_rc 2 "$rc" "the walkthrough may not read the metric definitions"
cat > docs/product/stories/S004-faster-dashboard.md <<'MD'
# S004 A faster dashboard
persona: maya
metric: p95_ms down
MD
git add -A && git commit -q -m "S004"
out="$("$ORCH" product plan --story S004 2>&1)"
contains "$out" "targets p95_ms, a holdout metric; skipped" "a story may not target the holdout metric"
rm docs/product/stories/S004-faster-dashboard.md; git add -A && git commit -q -m "drop S004"
"$ORCH" product freeze --why "S004 withdrawn" >/dev/null 2>&1
sleep 1

printf '\nkeep lands it:\n'
out="$("$ORCH" product keep F001-export-week 2>&1)"; rc=$?
chk_rc 0 "$rc" "keep lands F001"
contains "$out" "kept F001-export-week" "and says so"
contains "$(git log --format=%s main)" "F001-export-week" "the base carries it"
[ ! -d .orch/worktrees/F001-export-week/main ]; chk $? "its worktree is closed"
jq -e -s 'any(.[]; .event=="product.kept") and any(.[]; .event=="merge.landed")' docs/features/F001-export-week/ledger.jsonl >/dev/null
chk $? "kept and landed are on its ledger, in the checkout"
contains "$("$ORCH" product trace 2>&1 | grep '^S001')" "landed" "S001 is landed"
git add -A >/dev/null 2>&1; git commit -q -m "F001 artifacts" >/dev/null 2>&1
out="$("$ORCH" product night 2>&1)"
contains "$out" "1 crew(s) started" "the next night starts F002, whose dependency has landed"
contains "$("$ORCH" product trace 2>&1 | grep '^S002')" "running" "S002 is running"

printf '\nthe metrics loop, after the landing:\n'
sleep 1
"$ORCH" run --feature _orch --label metrics -- sh -c 'printf "exports_per_user 13.4\nerror_rate 3.5\np95_ms 390\n"' >/dev/null 2>&1
out="$("$ORCH" product metrics 2>&1)"; rc=$?
chk_rc 0 "$rc" "metrics renders"
contains "$out" "F001-export-week           S001  confirmed exports_per_user up: 12 -> 13.4 (+11.7%)" "S001's hypothesis is confirmed by the readings either side of the landing"
contains "$out" "error_rate           guardrail (down)  3 -> 3.5  +16.7%  BREACH" "the error-rate guardrail breached"
contains "$out" "p95_ms               guardrail (down)  400 -> 390  -2.5%" "the latency guardrail held"
contains "$out" "maya: 1 confirmed hypothesis(es), none refuted — propose  evidence: measured" "a confirmed hypothesis proposes measured evidence for the persona"
f="$("$ORCH" findings deliver _orch 2>&1)"
contains "$f" "guardrail error_rate moved the wrong way: 3 -> 3.5 (+16.7%)" "the breach is a finding on the run"
contains "$f" "last landing before it: F001-export-week" "named after the feature that landed before it"
contains "$f" "[blocking]" "blocking"
"$ORCH" product metrics >/dev/null 2>&1
[ "$("$ORCH" findings deliver _orch 2>&1 | grep -c 'raised by metrics')" = "1" ]; chk $? "raised once"
contains "$("$ORCH" product morning 2>&1)" "metric: confirmed exports_per_user up: 12 -> 13.4 (+11.7%)" "the morning shows the verdict on the landed feature"
contains "$("$ORCH" product trace 2>&1)" "frozen: as of" "metrics.md is frozen with the rest"

printf '\nexploratory, iterate, discard:\n'
out="$("$ORCH" product keep F002-schedule-export 2>&1)"; rc=$?
chk_rc 1 "$rc" "keep refuses an exploratory feature"
contains "$out" "sam) is hypothesized" "naming the persona and its status"
contains "$out" "--exploratory" "and the flag that overrides"
out="$("$ORCH" product iterate F002-schedule-export 2>&1)"; rc=$?
chk_rc 1 "$rc" "iterate needs a note"
out="$("$ORCH" product iterate F002-schedule-export --note "weekly by default; no cron syntax" 2>&1)"; rc=$?
chk_rc 0 "$rc" "iterate with a note"
contains "$(cat "$(fdir F002-schedule-export)/request.md")" "weekly by default; no cron syntax" "the note is in the request"
jq -e -s 'any(.[]; .event=="statement.frozen" and .why=="morning iterate")' "$(fdir F002-schedule-export)/ledger.jsonl" >/dev/null
chk $? "and the statement is re-frozen with the reason"
ORCH_FEATURE=F002-schedule-export "$ORCH" statement check F002-schedule-export >/dev/null 2>&1; chk $? "so the statement holds"
out="$("$ORCH" product discard F002-schedule-export 2>&1)"; rc=$?
chk_rc 1 "$rc" "discard needs a reason"
out="$("$ORCH" product discard F002-schedule-export --why "sam does not schedule; sam exports by hand" 2>&1)"; rc=$?
chk_rc 0 "$rc" "discard with a reason"
contains "$out" "noted against persona sam" "is noted against the persona"
[ ! -d .orch/worktrees/F002-schedule-export/main ]; chk $? "its worktree is closed"
jq -e -s 'any(.[]; .event=="product.learned" and .persona=="sam" and .story=="S002")' docs/features/_orch/ledger.jsonl >/dev/null
chk $? "and the run ledger carries what was learned"
out="$("$ORCH" product personas 2>&1)"
contains "$out" "sam — Sam, the ops lead   [hypothesized]" "personas lists sam"
contains "$out" "learned (" "with what the morning taught it"
contains "$out" "sam does not schedule" "verbatim"
contains "$("$ORCH" product trace 2>&1 | grep '^S002')" "unplanned" "a discarded story is unplanned again"
out="$("$ORCH" product plan 2>&1)"
contains "$out" "F003-schedule-export  S002" "and the next plan builds it again, as F003"

printf '\norphans:\n'
"$ORCH" feature start F010-orphan --request "a thing nobody asked for" >/dev/null 2>&1
out="$("$ORCH" product trace 2>&1)"; rc=$?
chk_rc 1 "$rc" "a feature no story asked for fails the trace"
contains "$out" "features no story asked for" "under its own heading"
contains "$out" "F010-orphan" "by name"
printf '\nStory: S001\n' >> "$(fdir F010-orphan)/request.md"
"$ORCH" product trace >/dev/null 2>&1; chk $? "a Story: line in the request links it"

teardown_repo
finish product
