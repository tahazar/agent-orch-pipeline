#!/bin/bash
# launcher.test.sh - session lifecycle.
#
# Runs entirely against ORCH_LAUNCHER=print, which starts no processes. That is
# not a limitation of the suite, it is the property being tested: every
# launcher runs the same command, so asserting on the command is asserting on
# all three, and the suite stays free of a terminal, a claude binary and a
# network.
#
# What matters here:
#   - no crew is spawned before a human confirms a tier
#   - every session in a team gets the same task list and the same role file
#   - a launcher that starts nothing does not report that it started something
#   - the seam is complete for every implementation

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
setup_repo launcher
trap teardown_repo EXIT

export ORCH_LAUNCHER=print
printf 'launcher\n\n'

printf 'the seam is complete for every implementation:\n'
for impl in cmux bg print; do
  missing=''
  for op in spawn kill peek list notify probe; do
    grep -q "orch_lnch_$op()" "$ORCH_ROOT/lib/launcher/$impl.sh" || missing="$missing $op"
  done
  [ -z "$missing" ]; chk $? "$impl implements every operation${missing:+ (missing:$missing)}"
done

out="$(ORCH_LAUNCHER=nonesuch "$ORCH" team status 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "an unknown launcher is refused, not silently defaulted"

printf '\nno crew before a confirmed tier:\n'
"$ORCH" feature start F030-spawn --request "test fixture" >/dev/null 2>&1
enter_feature F030-spawn >/dev/null 2>&1 || true
out="$("$ORCH" team start --feature F030-spawn 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "a crew cannot be spawned before a tier is confirmed"
contains "$out" "no confirmed tier" "and the refusal says what is missing"
contains "$out" "orch tier confirm" "and how to fix it"

"$ORCH" tier confirm F030-spawn --tier quick >/dev/null 2>&1
out="$("$ORCH" team start --feature F030-spawn 2>&1)"
contains "$out" "tech-lead" "quick spawns a tech-lead"
contains "$out" "developer" "and a developer"
not_contains "$out" "code-reviewer" "but not a code-reviewer"
not_contains "$out" "test-engineer" "and not a test-engineer"

printf '\nthe crew grows with the rung:\n'
"$ORCH" feature start F031-strict --request "test fixture" --tier strict >/dev/null 2>&1
enter_feature F031-strict >/dev/null 2>&1 || true
out="$("$ORCH" team start --feature F031-strict 2>&1)"
contains "$out" "test-engineer" "strict adds the test-engineer"
contains "$out" "code-reviewer" "and the code-reviewer"

printf '\nthe review ensemble is spawned, not described:\n'
n_lens="$(printf '%s' "$out" | grep -c 'ORCH_LENS=')"
[ "$n_lens" = "4" ]; chk $? "four lenses at strict, four sessions — the three review lenses and security (got $n_lens)"
for l in correctness failure-modes reproduction security; do
  contains "$out" "code-reviewer-$l" "a session named for the $l lens"
  contains "$out" "lens \`$l\`" "whose orders name that lens"
done
n_opus="$(printf '%s' "$out" | grep -c -- '--model opus')"
[ "$n_opus" = "1" ]; chk $? "exactly one lens runs on opus (got $n_opus) — the model axis of the ensemble"
printf '%s' "$out" | grep -- '--model opus' | grep -q 'code-reviewer-correctness'
chk $? "and it is the correctness lens by default"
not_contains "$(printf '%s' "$out" | grep 'agent developer')" "--model" "the developer keeps its frontmatter model"
out="$(ORCH_OPUS_LENS= "$ORCH" team start --feature F031-strict 2>&1)"
not_contains "$out" "--model" "an empty ORCH_OPUS_LENS puts every lens on the role's own model"
out="$(ORCH_REVIEW_LENSES=correctness ORCH_STRICT_LENSES= "$ORCH" team start --feature F031-strict 2>&1)"
[ "$(printf '%s' "$out" | grep -c 'ORCH_LENS=')" = "1" ]; chk $? "the lens lists are overridable"

printf '\na reviewer spawned by hand gets a lens too:\n'
out="$("$ORCH" spawn code-reviewer --feature F031-strict --lens reproduction 2>&1)"
contains "$out" "ORCH_LENS=reproduction" "the lens asked for"
contains "$out" "code-reviewer-reproduction" "in the session name"
not_contains "$out" "--model" "and no model override, since it is not the opus lens"
out="$("$ORCH" spawn code-reviewer --feature F031-strict 2>&1)"
contains "$out" "ORCH_LENS=correctness" "with no --lens, the first lens"
contains "$out" "--model opus" "which is the opus lens"

printf '\nevery session in a team shares its coordination environment:\n'
out="$("$ORCH" team start --feature F031-strict 2>&1)"
n_tl="$(printf '%s' "$out" | grep -c 'CLAUDE_CODE_TASK_LIST_ID=')"
n_ag="$(printf '%s' "$out" | grep -c 'claude --agent')"
[ "$n_tl" = "$n_ag" ] && [ "$n_ag" -gt 1 ]
chk $? "all $n_ag sessions carry a task list id"
[ "$(printf '%s' "$out" | grep 'CLAUDE_CODE_TASK_LIST_ID=' | sort -u | grep -c .)" = "1" ]
chk $? "and it is the same one for all of them — a mixed team coordinates with nobody"
[ "$(printf '%s' "$out" | grep -c 'ORCH_FEATURE=F031-strict')" = "$n_ag" ]
chk $? "each knows which feature it is on"

printf '\nroles launch with their own permissions:\n'
out="$("$ORCH" team start 2>&1)"
contains "$out" "role-director.json" "the director gets the director settings"
contains "$out" "--permission-mode" "every session names a permission mode"
[ "$(printf '%s' "$out" | grep -o -- '--permission-mode [a-zA-Z]*' | sort -u | grep -c .)" = "1" ]
chk $? "and they all share one class — mismatched classes go quiet, not loud"

printf '\nthe run is one session, not two:\n'
not_contains "$out" "ORCH_FEATURE=" "starting the run pins no feature"
not_contains "$out" "ORCH_ROLE=auditor" "no standing auditor — idle context is what its independence is made of"
contains "$out" "orch audit" "and team start says where the auditor now comes from"

printf '\nthe auditor is spawned per gate, fresh:\n'
out="$("$ORCH" audit F031-strict --gate work 2>&1)"
contains "$out" "ORCH_ROLE=auditor" "orch audit spawns the auditor"
contains "$out" "ORCH_FEATURE=F031-strict" "pinned to the feature under review"
contains "$out" "ORCH_GATE=work" "and told which gate it is adjudicating"
contains "$out" "role-crew.json" "with the crew settings, not the director's"
contains "$out" "--effort xhigh" "at xhigh effort — the one place deep thinking is bought deliberately"
contains "$out" "orch kill auditor" "and the teardown is stated at spawn time"
out="$("$ORCH" audit F999-nope 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "auditing a feature that does not exist is refused"

printf '\neffort follows the tier:\n'
out="$("$ORCH" team start --feature F030-spawn 2>&1)"
contains "$out" "--effort low" "a quick-tier crew runs at low effort"
out="$("$ORCH" team start --feature F031-strict 2>&1)"
not_contains "$out" "--effort" "a strict-tier crew runs at the model default"

printf '\nrecycle rebuilds the env from the ledger:\n'
out="$("$ORCH" team recycle developer 2>&1)"
contains "$out" "ORCH_ROLE=developer" "the role comes back"
contains "$out" "fresh context, same role" "and says what recycling means"
out="$("$ORCH" team recycle nonesuch 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "recycling a session orch never started is refused"
contains "$out" "orch did not start it" "with the reason"

printf '\\na recycled reviewer is the same reviewer:\\n'
"$ORCH" team start --feature F031-strict >/dev/null 2>&1
out="$("$ORCH" team recycle code-reviewer-correctness 2>&1)"
contains "$out" "ORCH_LENS=correctness" "a recycled reviewer comes back as the same lens"
contains "$out" "--model opus" "on the same model — the yield report must keep describing the same reviewer"
out="$("$ORCH" team recycle code-reviewer-reproduction 2>&1)"
contains "$out" "ORCH_LENS=reproduction" "and a non-opus lens comes back as itself"
not_contains "$out" "--model" "without inheriting the opus override"

printf '\na launcher that starts nothing does not claim it did:\n'
LEDGER="${MAIN:-$ORCH_REPO}/docs/features/_orch/ledger.jsonl"
jq -e -s 'any(.[]; .event=="agent.printed")' "$LEDGER" >/dev/null
chk $? "print records agent.printed"
jq -e -s 'all(.[]; .event != "agent.spawned")' "$LEDGER" >/dev/null
chk $? "and never agent.spawned — a phantom session would be billed to the feature"

printf '\nunknown roles are refused:\n'
out="$("$ORCH" spawn nonesuch 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "spawning a role with no definition is refused"
contains "$out" "does not exist" "and says the definition is missing"

printf '\nnaming:\n'
out="$("$ORCH" spawn developer --suffix c2 2>&1)"
contains "$out" "-n developer-c2" "a suffix distinguishes best-of-N candidates"
out="$("$ORCH" spawn developer 2>&1)"
contains "$out" "-n developer " "and a bare role keeps the plain name"

printf '\nevery session wakes with marching orders:\n'
# The first real run found the gap: a spawned session with no opening message
# sits at an empty prompt, and the human ends up doing every role's job by
# hand. The orders are part of the claude command itself.
out="$("$ORCH" spawn tech-lead --feature F030-spawn 2>&1)"
contains "$out" "Begin now" "the tech-lead wakes on duty, not at an empty prompt"
contains "$out" "docs/features/F030-spawn/request.md" "pointed at the frozen request"
contains "$out" "orch tier recommend F030-spawn" "and told how its proposal comes back"

out="$("$ORCH" audit F031-strict --gate red 2>&1)"
contains "$out" 'for F031-strict, gate' "the auditor is told which gate it exists for"
contains "$out" "this gate only" "and that it exists for nothing else"

out="$("$ORCH" team start --feature F030-spawn 2>&1)"
contains "$out" "orch run --feature F030-spawn" "the developer wakes knowing how evidence is made"

out="$("$ORCH" team start 2>&1)"
contains "$out" "stand by" "with no run request on record, the director stands by for features"

printf '\nkickoff — one command, and the director drives:\n'
out="$("$ORCH" kickoff 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "kickoff without a request is refused"
out="$("$ORCH" kickoff --request "Build a CSV importer with three views" 2>&1)"
[ -r "${MAIN:-$ORCH_REPO}/docs/features/_orch/request.md" ]
chk $? "the run request is frozen at docs/features/_orch/request.md"
contains "$out" "Decompose it into a graph of features" "the director wakes with decompose-and-drive orders"
contains "$out" "orch tier confirm" "and the human is told exactly which gates are theirs"
contains "$out" "orch approve" "including the merge"
grep -q "Build a CSV importer" "${MAIN:-$ORCH_REPO}/docs/features/_orch/request.md"
chk $? "and the frozen request is the one that was given"
jq -e -s 'any(.[]; .event=="kickoff")' "${MAIN:-$ORCH_REPO}/docs/features/_orch/ledger.jsonl" >/dev/null
chk $? "kickoff is a ledger event"

# Orders carry human text; an apostrophe must not detonate the command line.
out="$("$ORCH" kickoff --request "don't pad the rows; reject them" 2>&1)"; rc=$?
chk_rc 0 "$rc" "a request with an apostrophe survives shell quoting"


printf '\nthe cmux probe asks only what the shim answers:\n'
# The remote Python shim has no `version` command and writes its complaint
# to stdout; the probe must not read that as a version.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/cmux" <<'SH'
#!/bin/bash
case "${1:-}" in
  ping) echo PONG ;;
  version) echo "ERROR: Unknown command 'version'"; exit 0 ;;
  *) echo "ERROR: Unknown command '$1'"; exit 0 ;;
esac
SH
chmod +x "$WORK/fakebin/cmux"
out="$(PATH="$WORK/fakebin:$PATH" ORCH_LAUNCHER=cmux ORCH_HOME="$ORCH_ROOT" bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_probe' 2>/dev/null)"
[ "$(printf '%s' "$out" | jq -r .reachable)" = "true" ]; chk $? "ping answers: reachable"
not_contains "$out" "Unknown command" "and no shim error is reported as a version"
[ "$(printf '%s' "$out" | jq -r '.version // ""')" = "" ]; chk $? "version is empty rather than wrong"


printf '\ncmux: the workspace is created by name alone, and the command is typed:\n'
# A fake cmux that records every call. It answers what the remote shim
# answers: new-workspace with a positional name only (the flag form makes a
# workspace titled with the whole argv, as the real shim did), workspace
# list, tree, new-split, send, send-key.
mkdir -p "$WORK/shim" && : > "$WORK/shim/log" && : > "$WORK/shim/ws"
cat > "$WORK/shim/cmux" <<'SH'
#!/bin/bash
log="$(dirname "$0")/log"; ws="$(dirname "$0")/ws"
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  ping) echo PONG ;;
  new-workspace) shift; printf '%s\t%s\n' "aaaaaaaa-0000-0000-0000-$(printf '%012d' "$(wc -l < "$ws")")" "$*" >> "$ws" ;;
  workspace) awk -F'\t' '{print $1 " " $2}' "$ws" ;;
  tree) echo "  surface surface:1 bbbbbbbb-0000-0000-0000-000000000001" ;;
  new-split) echo "surface:2 cccccccc-0000-0000-0000-000000000002" ;;
  send|send-key|notify) : ;;
  *) echo "ERROR: Unknown command '$1'"; exit 0 ;;
esac
SH
chmod +x "$WORK/shim/cmux"
out="$(PATH="$WORK/shim:$PATH" ORCH_LAUNCHER=cmux ORCH_HOME="$ORCH_ROOT" ORCH_REPO="$ORCH_REPO" ORCH_PROMPT="begin" \
  bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_spawn director director "$ORCH_REPO" ORCH_ROLE=director ORCH_HOME=/x' 2>&1)"; rc=$?
chk_rc 0 "$rc" "the director spawns through the shim"
ws_names="$(cut -f2 "$WORK/shim/ws")"
contains "$ws_names" "orch:run" "the workspace is titled orch:run"
not_contains "$ws_names" "--command" "and never with the argv as its name"
not_contains "$(cat "$WORK/shim/log")" "--command" "new-workspace is never given --command"
not_contains "$(cat "$WORK/shim/log")" "--cwd" "nor --cwd"
sent="$(grep '^send --surface' "$WORK/shim/log")"
contains "$sent" "cd '$ORCH_REPO' && ORCH_ROLE='director' ORCH_HOME='/x' claude --agent director" "the command is typed into the pane with its cwd and environment"
contains "$(cat "$WORK/shim/log")" "send-key --surface bbbbbbbb-0000-0000-0000-000000000001 enter" "and Enter is pressed"
grep -q "^director	" "$ORCH_REPO/.orch/cmux-panes"; chk $? "the pane is on the map"
: > "$WORK/shim/ws"; : > "$WORK/shim/log"; rm -f "$ORCH_REPO/.orch/cmux-panes"
cat > "$WORK/shim/cmux" <<'SH'
#!/bin/bash
case "${1:-}" in ping) echo PONG ;; workspace) : ;; *) : ;; esac
SH
chmod +x "$WORK/shim/cmux"
out="$(PATH="$WORK/shim:$PATH" ORCH_LAUNCHER=cmux "$ORCH" team start 2>&1)"; rc=$?
chk_rc 1 "$rc" "when the workspace never appears, team start fails"
contains "$out" "the director did not launch" "and says the director did not launch"
not_contains "$out" "The run is up" "never claiming the run is up"


printf '\ncmux: the strict shim — errors on stdout, its own command names, no uuids:\n'
# What the remote Linux shim actually does: `workspace` and `tree` are
# unknown commands reported as "ERROR: ..." on stdout with exit 0; the
# listings are list-workspaces and list-surfaces; unknown flags are errors;
# ids are short refs; and new-workspace given the flag form makes a
# workspace titled with the whole argv.
mkdir -p "$WORK/strict" && : > "$WORK/strict/log" && : > "$WORK/strict/ws" && : > "$WORK/strict/surf"
cat > "$WORK/strict/cmux" <<'SH'
#!/bin/bash
d="$(dirname "$0")"; printf '%s\n' "$*" >> "$d/log"
err() { echo "ERROR: $1"; exit 0; }
case "$*" in *--id-format*|*" --all"*) err "Unknown option" ;; esac
case "${1:-}" in
  ping) echo PONG ;;
  new-workspace) shift; n=$(($(wc -l < "$d/ws") + 1)); u="$(printf 'AAAAAAA%1d-0000-4000-8000-000000000000' "$n")"; printf '%s\t%s\n' "$u" "$*" >> "$d/ws"; printf '%s\tBBBBBBB%1d-0000-4000-8000-000000000001\n' "$u" "$n" >> "$d/surf" ;;
  list-workspaces) awk -F'\t' 'NR==1 {m="* "} NR>1 {m="  "} {print m NR-1 ": " $1 (NR==1 ? " ◆ " : " ") $2}' "$d/ws" ;;
  list-surfaces) if [ "${2:-}" = --workspace ]; then awk -F'\t' -v w="$3" '$1 == w {print "  " (c++) ": " $2}' "$d/surf"; else awk -F'\t' '{print "  " (c++) ": " $2}' "$d/surf"; fi ;;
  new-split) w="$4"; n=$(($(grep -c "^$w	" "$d/surf") + 1)); u="$(printf 'CCCCCCC%1d-0000-4000-8000-%012d' "$n" "$n")"; printf '%s\t%s\n' "$w" "$u" >> "$d/surf"; echo "$u" ;;
  close-workspace) grep -v "^$3	" "$d/ws" > "$d/ws.t"; mv "$d/ws.t" "$d/ws"; grep -v "^$3	" "$d/surf" > "$d/surf.t"; mv "$d/surf.t" "$d/surf" ;;
  close-surface) grep -v "	$3\$" "$d/surf" > "$d/surf.t"; mv "$d/surf.t" "$d/surf" ;;
  list-workspaces-raw) cat "$d/ws" ;;
  send) : ;;                                   # the trap: OK, and typed into the focused pane
  send-key) err "Unknown key '$*'" ;;
  send-surface|send-key-surface) case "${2:-}" in [0-9]|[0-9][0-9]) : ;; *) err "Surface not found" ;; esac ;;
  notify) : ;;
  *) err "Unknown command '$1'. Use 'help' for available commands." ;;
esac
SH
chmod +x "$WORK/strict/cmux"
rm -f "$ORCH_REPO/.orch/cmux-panes"
run_strict() { PATH="$WORK/strict:$PATH" ORCH_LAUNCHER=cmux ORCH_HOME="$ORCH_ROOT" ORCH_REPO="$ORCH_REPO" ORCH_PROMPT="begin" bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; '"$1"; }
out="$(run_strict 'launcher_spawn director director "$ORCH_REPO" ORCH_ROLE=director' 2>&1)"; rc=$?
chk_rc 0 "$rc" "the director spawns through the strict shim"
[ "$(cut -f2 "$WORK/strict/ws")" = "orch:run" ]; chk $? "one workspace, titled exactly orch:run — the mis-titled one from the flag form was closed again"
contains "$(cat "$WORK/strict/log")" "close-workspace --workspace AAAAAAA1-0000-4000-8000-000000000000" "the stray workspace was closed"
not_contains "$(cat "$WORK/strict/log")" "send --surface" "send --surface is never used on the shim — it types into the focused pane"
contains "$(cat "$WORK/strict/log")" "send-key-surface BBBBBBB1-0000-4000-8000-000000000001 enter" "the uuid was tried as a target first"
contains "$(grep '^send-surface' "$WORK/strict/log")" "send-surface 0 cd '$ORCH_REPO' && ORCH_ROLE='director' claude --agent director" "and the command went through send-surface with the index the shim accepted"
contains "$(cat "$WORK/strict/log")" "send-key-surface 0 enter" "and Enter through send-key-surface"
out="$(run_strict 'launcher_spawn developer developer "$ORCH_REPO" ORCH_ROLE=developer ORCH_FEATURE=F001-x' 2>&1)"; rc=$?
chk_rc 0 "$rc" "a crew member spawns into its own feature workspace"
contains "$(cut -f2 "$WORK/strict/ws" | tr '\n' ' ')" "orch:F001-x" "titled orch:F001-x"
out="$(run_strict 'launcher_spawn test-engineer test-engineer "$ORCH_REPO" ORCH_ROLE=test-engineer ORCH_FEATURE=F001-x' 2>&1)"; rc=$?
chk_rc 0 "$rc" "a second crew member splits into it"
contains "$(cat "$WORK/strict/log")" "new-split right --workspace AAAAAAA2-0000-4000-8000-000000000000" "through new-split, without the flags the shim rejects"
contains "$(grep '^send-surface' "$WORK/strict/log" | tail -1)" "send-surface 1 cd " "and its command goes to the new surface, by its index"
out="$(run_strict 'launcher_list' 2>&1)"
[ "$(printf '%s' "$out" | sort | tr '\n' ' ')" = "developer director test-engineer " ]; chk $? "all three are listed alive (got: $(printf '%s' "$out" | tr '\n' ' '))"
out="$(run_strict 'launcher_kill test-engineer' 2>&1)"; rc=$?
chk_rc 0 "$rc" "kill closes a crew member's surface"
contains "$(cat "$WORK/strict/log")" "close-surface --surface CCCCCCC2-0000-4000-8000-000000000002 --workspace AAAAAAA2-0000-4000-8000-000000000000" "by close-surface, leaving the workspace"
out="$(run_strict 'launcher_kill developer' 2>&1)"; rc=$?
chk_rc 0 "$rc" "killing the last member closes the workspace"
contains "$(cat "$WORK/strict/log")" "close-workspace --workspace AAAAAAA2-0000-4000-8000-000000000000" "by close-workspace"
out="$(run_strict 'launcher_list' 2>&1)"
[ "$out" = "director" ]; chk $? "only the director remains (got: $out)"
out="$(run_strict 'launcher_probe')"
not_contains "$out" "ERROR" "the probe carries no shim error text"
[ "$(printf '%s' "$out" | jq -r .listing)" = "true" ]; chk $? "the probe reports that the listing answers"
[ "$(printf '%s' "$out" | jq -r .titles)" = "1" ]; chk $? "and how many workspaces it parsed"
[ "$(printf '%s' "$out" | jq -r .native)" = "false" ]; chk $? "and that this cmux is the shim"
# A shim that targets nothing: no form accepts any id. Nothing may be typed.
mkdir -p "$WORK/notarget" && : > "$WORK/notarget/log"
sed -e 's/case "${2:-}" in \[0-9\]|\[0-9\]\[0-9\]) : ;; \*) err "Surface not found" ;; esac/err "Surface not found"/' "$WORK/strict/cmux" > "$WORK/notarget/cmux"
sed -i 's|d="$(dirname "$0")"; printf|d="$(dirname "$0")"; ws="$d/ws"; surf="$d/surf"; printf|' "$WORK/notarget/cmux"
chmod +x "$WORK/notarget/cmux"; cp "$WORK/strict/ws" "$WORK/notarget/ws" 2>/dev/null; cp "$WORK/strict/surf" "$WORK/notarget/surf" 2>/dev/null
rm -f "$ORCH_REPO/.orch/cmux-panes"
out="$(PATH="$WORK/notarget:$PATH" ORCH_LAUNCHER=cmux ORCH_HOME="$ORCH_ROOT" ORCH_REPO="$ORCH_REPO" ORCH_PROMPT="begin" bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_spawn developer developer "$ORCH_REPO" ORCH_ROLE=developer ORCH_FEATURE=F002-y' 2>&1)"; rc=$?
chk_rc 1 "$rc" "a shim that accepts no target id: the spawn refuses"
contains "$out" "Nothing was typed anywhere" "and says nothing was typed"
not_contains "$(grep -E '^send(-surface)? ' "$WORK/notarget/log")" "claude" "and indeed no command was sent by any form"
printf '#!/bin/bash\ncase "${1:-}" in ping) echo PONG ;; *) echo "ERROR: Unknown command"; exit 0 ;; esac\n' > "$WORK/strict/cmux2"; chmod +x "$WORK/strict/cmux2"
mkdir -p "$WORK/pingonly" && cp "$WORK/strict/cmux2" "$WORK/pingonly/cmux"
out="$(PATH="$WORK/pingonly:$PATH" ORCH_LAUNCHER=cmux ORCH_NO_COLOR=1 "$ORCH" doctor 2>&1 | grep -A1 '^launcher' | tail -1; PATH="$WORK/pingonly:$PATH" ORCH_LAUNCHER=cmux ORCH_NO_COLOR=1 "$ORCH" doctor 2>&1 | grep 'cmux')"
contains "$out" "answers ping, but no workspace listing form answers" "doctor: ping alone is not green"
rm -f "$ORCH_REPO/.orch/cmux-panes"

finish launcher
