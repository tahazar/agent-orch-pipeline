#!/bin/bash
# perf.test.sh - the performance sensor.
#
# What matters here:
#   - the parser reads "name value" lines, Go benchmarks, hyperfine and
#     pytest-benchmark JSON
#   - the base is checked out clean beside the feature and the same command
#     runs on both, interleaved, N times; each run is attested; medians
#   - the reading is per benchmark: base, head, percent, the base's spread;
#     a new benchmark at HEAD is listed, not compared; higher-is-better
#     names flip the sign
#   - ORCH_T_PERF makes a regression over it, outside the spread, a perf
#     finding and a gate failure; a budget is an absolute, blocking ceiling
#   - the packet shows it; a dirty tree is refused

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo perf
export ORCH_LAUNCHER=print ORCH_NO_FLOCK=1 ORCH_HOME="$ORCH_ROOT"
. "$ORCH_ROOT/lib/perf.sh"
printf 'the performance sensor\n\n'

printf 'the parser:\n'
out="$(printf 'parse_1mb 12.5 ms\nserialize: 20\nthroughput_ops = 900\nnot a number here\n' | perf_parse)"
[ "$out" = "$(printf 'parse_1mb 12.5\nserialize 20\nthroughput_ops 900')" ]; chk $? "name value lines, with : or = between"
out="$(printf 'goos: linux\nBenchmarkParse-8   \t 1000000 \t 1234 ns/op\nBenchmarkEncode-8  500000   2500.5 ns/op   96 B/op\nPASS\n' | perf_parse)"
[ "$out" = "$(printf 'BenchmarkParse 1234\nBenchmarkEncode 2500.5')" ]; chk $? "Go benchmarks, the -N suffix dropped"
out="$(printf '{"results":[{"command":"./parse big.csv","mean":0.412,"stddev":0.01}]}' | perf_parse)"
[ "$out" = "./parse big.csv 0.412" ]; chk $? "hyperfine JSON"
out="$(printf '{"benchmarks":[{"name":"test_parse","stats":{"mean":0.0021}}]}' | perf_parse)"
[ "$out" = "test_parse 0.0021" ]; chk $? "pytest-benchmark JSON"
out="$(printf 'a 3\na 1\na 2\nb 10\nb 30\n' | perf_median)"
[ "$out" = "$(printf 'a 2 1 3\nb 20 10 30')" ]; chk $? "medians with min and max"

printf '\nthe reading:\n'
cat > bench.sh <<'SH'
#!/bin/sh
printf 'parse 10\nserialize 20\nrows_per_s 1000\n'
SH
chmod +x bench.sh; git add -A && git commit -q -m "bench on main"
"$ORCH" feature start F001-faster --request "faster" --tier standard >/dev/null 2>&1
enter_feature F001-faster
cat > bench.sh <<'SH'
#!/bin/sh
printf 'parse 13\nserialize 19\nrows_per_s 900\nnew_thing 5\n'
SH
git add -A && git commit -q -m "slower parse, faster serialize, lower throughput"
sha="$(git rev-parse HEAD)"
printf 'x\n' > scratch.txt
out="$("$ORCH" sensor perf F001-faster -- ./bench.sh 2>&1)"; rc=$?
chk_rc 1 "$rc" "a dirty tree is refused"
rm scratch.txt
out="$("$ORCH" sensor perf F001-faster -- sh -c 'exit 3' 2>&1)"; rc=$?
chk_rc 1 "$rc" "a failing benchmark is refused"
contains "$out" "failed on the base" "and says which side"
out="$("$ORCH" sensor perf F001-faster --runs 3 -- ./bench.sh 2>&1)"; rc=$?
chk_rc 0 "$rc" "the reading runs"
contains "$out" "perf: worst 30.0% (parse) over 3 interleaved runs" "the worst regression is named"
contains "$out" "parse  10 -> 13  +30.0%  spread 0.0%" "parse is 30% worse"
contains "$out" "serialize  20 -> 19  -5.0%" "serialize is 5% better"
contains "$out" "rows_per_s  1000 -> 900  +10.0%" "a throughput name is higher-is-better: fewer rows per second is worse"
[ "$(jq -s '[.[] | select(.label=="perf-base" and .exit_code==0)] | length' docs/features/F001-faster/evidence.jsonl)" = "3" ]; chk $? "three attested base runs"
[ "$(jq -s '[.[] | select(.label=="perf" and .exit_code==0)] | length' docs/features/F001-faster/evidence.jsonl)" = "3" ]; chk $? "and three at HEAD"
[ ! -d "$MAIN/.orch/worktrees/F001-faster/perf-base" ]; chk $? "the base worktree is gone afterwards"
row="$(jq -c -s '[.[] | select(.event=="sensor.perf")] | last' docs/features/F001-faster/ledger.jsonl)"
[ "$(printf '%s' "$row" | jq -r '.at_sha')" = "$sha" ]; chk $? "the reading is on the ledger at HEAD"
[ "$(printf '%s' "$row" | jq -r '.new | join(",")')" = "new_thing" ]; chk $? "a benchmark with no base is listed as new, not compared"
[ "$("$ORCH" findings deliver F001-faster 2>&1 | grep -c 'raised by perf')" = "0" ]; chk $? "without a threshold, no finding"

printf '\nthe gate:\n'
out="$(ORCH_T_PERF=10 "$ORCH" sensor perf F001-faster --runs 1 -- ./bench.sh 2>&1)"; rc=$?
chk_rc 0 "$rc" "with ORCH_T_PERF=10 the reading still runs"
f="$("$ORCH" findings deliver F001-faster 2>&1)"
contains "$f" "parse: 30.0% worse than the base (10 -> 13; the base's own spread was 0.0%)" "parse is a finding"
contains "$f" "[blocking]" "blocking, at more than twice the threshold"
not_contains "$f" "rows_per_s" "a 10% change is not over a 10% threshold"
ORCH_T_PERF=10 "$ORCH" sensor perf F001-faster --runs 1 -- ./bench.sh >/dev/null 2>&1
[ "$("$ORCH" findings deliver F001-faster 2>&1 | grep -c 'raised by perf')" = "1" ]; chk $? "raised once"
out="$(ORCH_T_PERF=10 bash -c '. "$ORCH_HOME/lib/perf.sh"; perf_gate F001-faster '"$sha"'' 2>&1)"; rc=$?
chk_rc 8 "$rc" "the gate holds (exit 8)"
contains "$out" "PERF_REGRESSION: over ORCH_T_PERF=10%" "naming the threshold"
contains "$out" "parse  +30.0%" "and the benchmark"
out="$(ORCH_T_PERF=40 bash -c '. "$ORCH_HOME/lib/perf.sh"; perf_gate F001-faster '"$sha"'' 2>&1)"; rc=$?
chk_rc 0 "$rc" "under the threshold it passes"
out="$(ORCH_T_PERF=10 bash -c '. "$ORCH_HOME/lib/perf.sh"; perf_gate F001-faster 0000000' 2>&1)"; rc=$?
chk_rc 8 "$rc" "a reading at another sha is no reading"
contains "$out" "SENSOR_MISSING" "SENSOR_MISSING"

printf '\nnoise:\n'
# The base is noisy (10, 14, 12 in turn); HEAD is steady at 13. The script
# lives outside both trees, so both sides run the same file.
cat > "$WORK/noisy.sh" <<SH
#!/bin/sh
if [ "\$(pwd -P)" = "$ORCH_REPO" ]; then printf 'parse 13\n'; exit 0; fi
n=\$(cat "$WORK/cnt" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$WORK/cnt"
case \$((n % 3)) in 1) v=10 ;; 2) v=14 ;; 0) v=12 ;; esac
printf 'parse %s\n' "\$v"
SH
out="$(ORCH_T_PERF=5 "$ORCH" sensor perf F001-faster --runs 3 -- sh "$WORK/noisy.sh" 2>&1)"; rc=$?
chk_rc 0 "$rc" "a noisy base is read"
contains "$out" "parse  12 -> 13  +8.3%  spread 33.3%" "the base's spread is recorded beside the regression"
out="$(ORCH_T_PERF=5 bash -c '. "$ORCH_HOME/lib/perf.sh"; perf_gate F001-faster '"$sha"'' 2>&1)"; rc=$?
chk_rc 0 "$rc" "a regression inside the base's own spread does not hold the gate"

printf '\nbudgets and the packet:\n'
mkdir -p "$MAIN/.claude"; printf '{"budgets": {"parse": 12}}\n' > "$MAIN/.claude/orch-perf.json"
out="$("$ORCH" sensor perf F001-faster --runs 1 -- sh -c 'printf "parse 13\n"' 2>&1)"; rc=$?
contains "$out" "OVER BUDGET 12" "over budget is shown"
contains "$("$ORCH" findings deliver F001-faster 2>&1)" "parse: 13 is over its budget of 12" "and is a finding"
out="$(bash -c '. "$ORCH_HOME/lib/perf.sh"; perf_gate F001-faster '"$sha"'' 2>&1)"; rc=$?
chk_rc 8 "$rc" "a budget holds the gate without any threshold set"
contains "$out" "PERF_BUDGET" "as PERF_BUDGET"
out="$("$ORCH" packet F001-faster 2>&1)"
contains "$out" "perf: worst" "the packet shows the reading"
contains "$out" "OVER BUDGET 12" "with the budget"
out="$("$ORCH" sensor show F001-faster 2>&1)"
contains "$out" '"sensor":"sensor.perf"' "show lists it"

teardown_repo
finish perf
