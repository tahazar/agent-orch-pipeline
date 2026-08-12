#!/bin/bash
# findings.test.sh - build-order step 8: reviewer ensemble and critique uptake.
#
# Acceptance (spec §14.8): two lenses produce a union larger than either alone
# on a seeded-defect fixture; per-reviewer unique-find rate is computed; a
# planted ignored finding lowers the uptake rate.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo findings
printf 'reviewer ensemble + critique uptake\n\n'

export ORCH_FEATURE=F009-review
"$ORCH" feature start F009-review >/dev/null 2>&1

# A seeded-defect fixture. Two defects that different lenses see: a wrong
# result (correctness) and an unguarded division (failure-modes). Neither lens
# is expected to find both, which is the entire argument for an ensemble.
cat > src/calc.py <<'EOF'
def add(a, b):
    return a - b


def mean(xs):
    return sum(xs) / len(xs)
EOF
git add -A && git commit -q -m "seed two defects"

add() {  # add <lens> <severity> <line> <claim> <consequence>
  "$ORCH" findings add F009-review --raised-by "$1" --severity "$2" \
    --file src/calc.py --line "$3" --claim "$4" --consequence "$5"
}

printf 'the union:\n'
c1="$(add correctness blocking 2 "add() subtracts" "every caller of add() gets the wrong number")"
c2="$(add correctness minor 5 "mean() has no docstring" "harder to use correctly")"
f1="$(add failure-modes blocking 6 "mean() divides by len(xs) with no empty check" "ZeroDivisionError on an empty list, at runtime, in production")"
f2="$(add failure-modes minor 5 "mean() has no docstring" "harder to use correctly")"

n_c="$("$ORCH" findings list F009-review | jq -s '[.[] | select(.raised_by=="correctness")] | length')"
n_f="$("$ORCH" findings list F009-review | jq -s '[.[] | select(.raised_by=="failure-modes")] | length')"
n_u="$("$ORCH" findings list F009-review | jq -s 'length')"
[ "$n_u" -gt "$n_c" ] && [ "$n_u" -gt "$n_f" ]
chk $? "the union ($n_u) is larger than either lens alone ($n_c, $n_f)"

# The overlapping finding is what separates "two reviewers" from "two lenses".
dupes="$("$ORCH" findings list F009-review | jq -s '[group_by(.claim)[] | select(length>1)] | length')"
[ "$dupes" = "1" ]; chk $? "the lenses overlap on one finding and diverge on the rest"

printf '\nfindings are structured, not prose:\n'
"$ORCH" findings list F009-review | jq -e -s 'all(.[]; has("id") and has("raised_by") and has("raised_at_sha") and has("severity") and has("file") and has("line") and has("claim") and has("consequence") and has("status"))' >/dev/null
chk $? "every finding carries the full row from §10"

out="$("$ORCH" findings add F009-review --raised-by correctness --severity major \
        --file src/calc.py --line 1 --claim "this feels wrong" 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "a finding with no stated consequence is rejected as an opinion"

printf '\ndelivery is verbatim, not a file path:\n'
out="$("$ORCH" findings deliver F009-review)"
contains "$out" "add() subtracts" "the claim text itself reaches the builder"
contains "$out" "every caller of add() gets the wrong number" "so does the consequence"
not_contains "$out" "findings.jsonl" "the builder is not handed a filename to go and read"

printf '\nuptake:\n'
# Fix one finding, dispute one, ignore the rest — the three outcomes §10 measures.
cat > src/calc.py <<'EOF'
def add(a, b):
    return a + b


def mean(xs):
    return sum(xs) / len(xs)
EOF
git add -A && git commit -q -m "fix the subtraction"
"$ORCH" findings dispute F009-review "$f2" --reason "duplicate of $c2, same line" >/dev/null 2>&1

out="$("$ORCH" findings verify F009-review 2>&1)"
contains "$out" "$c1  addressed" "a finding whose region changed is addressed"
contains "$out" "$f1  ignored" "a finding whose region never changed is ignored"

u="$("$ORCH" findings uptake F009-review)"
engaged="$(printf '%s' "$u" | jq -r '.engaged')"
ignored="$(printf '%s' "$u" | jq -r '.ignored')"
rate="$(printf '%s' "$u" | jq -r '.critique_uptake_rate')"
[ "$engaged" = "2" ] && [ "$ignored" = "2" ] && [ "$rate" = "50" ]
chk $? "uptake is 50% — 2 engaged (1 fixed, 1 disputed), 2 ignored (got $engaged/$ignored/$rate%)"
[ "$(printf '%s' "$u" | jq -r '.baseline_pct')" = "33.6" ]
chk $? "the 33.6% baseline from [P11] is reported alongside it"

printf '\na planted ignored finding moves the number:\n'
add correctness minor 5 "unused import" "noise" >/dev/null
"$ORCH" findings verify F009-review >/dev/null 2>&1
new_rate="$("$ORCH" findings uptake F009-review | jq -r '.critique_uptake_rate')"
[ "$new_rate" -lt "$rate" ]
chk $? "planting one more ignored finding lowered uptake from $rate% to $new_rate%"

printf '\ndisputing requires a reason:\n'
out="$("$ORCH" findings dispute F009-review "$c2" 2>&1)"; rc=$?
[ "$rc" != "0" ]; chk $? "disputing without a reason is refused"
contains "$out" "ignoring with extra steps" "and the refusal says what it actually is"

printf '\nper-reviewer unique-find rate:\n'
y="$("$ORCH" findings yield F009-review)"
printf '%s' "$y" | jq -e 'length == 2' >/dev/null
chk $? "both lenses are scored"
printf '%s' "$y" | jq -e 'all(.[]; has("unique") and has("unique_surviving") and has("unique_find_rate"))' >/dev/null
chk $? "each carries raised, unique, surviving and a rate"
# The shared docstring finding is not unique to either lens, so it must not be
# counted for either — that is the whole point of measuring uniqueness.
uc="$(printf '%s' "$y" | jq -r '.[] | select(.reviewer=="correctness") | .unique')"
[ "$uc" -lt "$(printf '%s' "$y" | jq -r '.[] | select(.reviewer=="correctness") | .raised')" ]
chk $? "a finding both lenses raised counts as unique to neither"

finish findings
