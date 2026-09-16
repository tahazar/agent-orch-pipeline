#!/bin/bash
# security.test.sh - the security sensor, the references, the lens, the axioms.
#
# What matters here:
#   - the sensor reads SARIF from an attested scanner run at the same sha and
#     scopes results to the diff: a result on a changed line is new, one in
#     an untouched file or on an untouched line is pre-existing
#   - every new result maps to its CWE (semgrep "CWE-89: ..." tags and
#     CodeQL "external/cwe/cwe-079" tags both), the OWASP Top 10:2025
#     categories that carry that CWE, and whether it is in the CWE Top 25
#   - each new result is a finding raised by `security` once: blocking when
#     Top 25 or level error, major otherwise
#   - ORCH_T_SECURITY gates on new findings; ORCH_SECURITY_CLASSES gates on
#     a class with no reading at HEAD; the packet shows the readings
#   - the references answer: asvs by chapter, section, id, word; owasp by
#     CWE; cis by section or Prowler check; the checklist names all four
#   - the security lens joins the ensemble at strict, with its orders
#   - a scanner-silencing comment is an escape hatch

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
trap teardown_repo EXIT
setup_repo security
export ORCH_LAUNCHER=print ORCH_NO_FLOCK=1 ORCH_HOME="$ORCH_ROOT"
printf 'security\n\n'

printf 'the references:\n'
out="$("$ORCH" security checklist 2>&1)"; rc=$?
chk_rc 0 "$rc" "checklist prints"
contains "$out" "A01 Broken Access Control" "with the OWASP Top 10:2025 categories"
contains "$out" "A10 Exceptional Conditions" "all ten"
contains "$out" "V8 Authorization" "and the ASVS chapters that answer each"
contains "$out" "CWE-89" "and the CWE Top 25"
contains "$out" "2.1.4 Block Public Access" "and the recurring CIS AWS recommendations"
out="$("$ORCH" security asvs V1.2 2>&1)"
contains "$out" "V1.2.5 (L1) Verify that the application protects against OS command injection" "asvs by section, with the level"
[ "$(printf '%s' "$out" | grep -c .)" = "10" ]; chk $? "ten requirements in V1.2"
[ "$("$ORCH" security asvs V8 2>&1 | grep -c .)" = "13" ]; chk $? "thirteen in chapter V8"
contains "$("$ORCH" security asvs 8.2.1 2>&1)" "V8.2.1 (L1)" "one by id, with or without the V"
contains "$("$ORCH" security asvs 'command injection' 2>&1)" "V1.2.5" "or by word"
[ "$("$ORCH" security asvs 2>&1 | grep -c '^V')" = "17" ]; chk $? "seventeen chapters"
out="$("$ORCH" security owasp CWE-89 2>&1)"
contains "$out" "A05:2025  Injection" "CWE-89 is Injection"
contains "$out" "CWE-89 is in the CWE Top 25" "and Top 25"
out="$("$ORCH" security owasp CWE-532 2>&1)"
contains "$out" "A09:2025  Security Logging and Alerting Failures" "CWE-532 is a logging failure"
not_contains "$out" "Top 25" "and not Top 25"
contains "$("$ORCH" security owasp CWE-22 2>&1)" "A01:2025  Broken Access Control" "path traversal is access control in 2025"
out="$("$ORCH" security cis 2.1 2>&1)"
contains "$out" "2.1.4  Ensure that S3 is configured with 'Block Public Access' enabled  (Level 1)" "cis by section"
contains "$("$ORCH" security cis ec2_instance_imdsv2_enabled 2>&1)" "5.7" "cis by Prowler check"
[ "$("$ORCH" security cis 2>&1 | grep -c .)" = "5" ]; chk $? "five CIS sections"
[ "$("$ORCH" security top25 2>&1 | grep -c .)" = "25" ]; chk $? "twenty-five in the Top 25"

printf '\nthe sensor:\n'
# The base carries legacy.py; the feature adds db.py and infra, and touches one line of legacy.py.
mkdir -p src
printf '.orch/\n' > .gitignore
printf 'def old(x):\n    return eval(x)\n' > src/legacy.py
git add -A && git commit -q -m "legacy on main"
"$ORCH" feature start F002-search --request "search by name" --tier strict >/dev/null 2>&1
enter_feature F002-search
mkdir -p infra
cat > src/db.py <<'PY'
import sqlite3

def find(conn, name):
    return conn.execute("SELECT * FROM t WHERE name = '" + name + "'")

def log(request):
    print("token=" + request.headers["Authorization"])
PY
printf 'def old(x):\n    return eval(x)  # legacy\n' > src/legacy.py
printf 'resource "aws_s3_bucket" "b" {\n  acl = "public-read"\n}\n' > infra/main.tf
git add -A && git commit -q -m "search"
sha="$(git rev-parse HEAD)"
mkdir -p .orch/sec
cat > .orch/sec/code.sarif <<SARIF
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"semgrep","rules":[
  {"id":"python.sqli","shortDescription":{"text":"SQL built from input"},"properties":{"tags":["CWE-89: Improper Neutralization of Special Elements used in an SQL Command","OWASP-A05:2025 - Injection"]}},
  {"id":"python.log-secret","shortDescription":{"text":"secret in log"},"properties":{"cwe":["CWE-532: Insertion of Sensitive Information into Log File"]}},
  {"id":"python.eval","shortDescription":{"text":"eval of input"},"properties":{"tags":["CWE-95: Eval Injection"]}}
]}},"results":[
  {"ruleId":"python.sqli","level":"error","message":{"text":"SQL built from input"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/db.py"},"region":{"startLine":4}}}]},
  {"ruleId":"python.log-secret","level":"warning","message":{"text":"secret in log"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/db.py"},"region":{"startLine":7}}}]},
  {"ruleId":"python.eval","level":"warning","message":{"text":"eval of input"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"$ORCH_REPO/src/legacy.py"},"region":{"startLine":1}}}]}
]},{"tool":{"driver":{"name":"CodeQL","rules":[{"id":"py/reflective-xss","properties":{"tags":["security","external/cwe/cwe-079"]}}]}},"results":[
  {"ruleId":"py/reflective-xss","level":"warning","message":{"text":"reflected XSS"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/other.py"},"region":{"startLine":3}}}]}
]}]}
SARIF
out="$("$ORCH" sensor security F002-search --class code --sarif .orch/sec/code.sarif 2>&1)"; rc=$?
chk_rc 1 "$rc" "no attested scanner run: refused"
contains "$out" "orch run --feature F002-search --label security-code" "and told how"
out="$("$ORCH" sensor security F002-search --class sast --sarif .orch/sec/code.sarif 2>&1)"; rc=$?
chk_rc 1 "$rc" "a class that is not code, deps, or iac is refused"
"$ORCH" run --feature F002-search --label security-code -- sh -c 'exit 1' >/dev/null 2>&1
out="$("$ORCH" sensor security F002-search --class code --sarif .orch/sec/code.sarif 2>&1)"; rc=$?
chk_rc 0 "$rc" "with an attested run (whatever its exit code), the reading is taken"
contains "$out" "security-code: 2 new finding(s) in the diff, 1 CWE Top 25, 2 pre-existing (semgrep)" "two new, one of them Top 25; the untouched line and the untouched file are pre-existing"
contains "$out" "2 security finding(s) open" "two findings raised"
f="$("$ORCH" findings deliver F002-search 2>&1)"
contains "$f" "[blocking]" "the SQL injection is blocking"
contains "$f" "python.sqli: SQL built from input [CWE-89 A05:2025 CWE Top 25]" "with its CWE, its category, and Top 25 in the claim"
contains "$f" "[major]" "the log leak is major"
contains "$f" "python.log-secret: secret in log [CWE-532 A09:2025]" "with its CWE and category"
contains "$f" "raised by security" "raised by security"
jq -e -s 'any(.[]; .event=="sensor.security" and .class=="code" and .new==2 and .pre_existing==2 and .top25==1)' docs/features/F002-search/ledger.jsonl >/dev/null
chk $? "the reading is on the ledger"
"$ORCH" sensor security F002-search --class code --sarif .orch/sec/code.sarif >/dev/null 2>&1
[ "$("$ORCH" findings deliver F002-search 2>&1 | grep -c 'raised by security')" = "2" ]; chk $? "a second reading raises nothing twice"
out="$("$ORCH" sensor show F002-search 2>&1)"
contains "$out" '"class":"code","at_sha":"'"$sha"'","new":2' "show lists the class reading"
contains "$out" '"class":"deps","reading":null' "and the classes with none"

printf '\niac, mapped to CIS:\n'
cat > .orch/sec/iac.sarif <<'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"prowler","rules":[{"id":"s3_bucket_level_public_access_block","shortDescription":{"text":"S3 public access block"}}]}},"results":[
  {"ruleId":"s3_bucket_level_public_access_block","level":"error","message":{"text":"bucket b allows public access"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"infra/main.tf"},"region":{"startLine":2}}}]}
]}]}
SARIF
"$ORCH" run --feature F002-search --label security-iac -- sh -c 'exit 1' >/dev/null 2>&1
out="$("$ORCH" sensor security F002-search --class iac --sarif .orch/sec/iac.sarif 2>&1)"; rc=$?
chk_rc 0 "$rc" "an iac reading"
contains "$out" "security-iac: 1 new finding(s)" "one new"
contains "$("$ORCH" findings deliver F002-search 2>&1)" "bucket b allows public access [CIS 2.1.4]" "carrying the CIS AWS recommendation its Prowler check maps to"

printf '\nthe gate and the packet:\n'
out="$(ORCH_T_SECURITY=0 bash -c '. "$ORCH_HOME/lib/security.sh"; security_gate F002-search '"$sha"'' 2>&1)"; rc=$?
chk_rc 8 "$rc" "with ORCH_T_SECURITY=0, new findings hold the gate (exit 8)"
contains "$out" "SECURITY_FINDINGS: 2 new code finding(s)" "naming the class and the count"
contains "$out" "src/db.py:4  python.sqli  CWE-89  TOP25" "and each finding"
out="$(ORCH_T_SECURITY=5 bash -c '. "$ORCH_HOME/lib/security.sh"; security_gate F002-search '"$sha"'' 2>&1)"; rc=$?
chk_rc 0 "$rc" "under the threshold, it passes"
out="$(ORCH_SECURITY_CLASSES="code deps" bash -c '. "$ORCH_HOME/lib/security.sh"; security_gate F002-search '"$sha"'' 2>&1)"; rc=$?
chk_rc 8 "$rc" "a required class with no reading is SENSOR_MISSING"
contains "$out" "SENSOR_MISSING: no security-deps reading" "naming it"
out="$(ORCH_SECURITY_CLASSES="code iac" bash -c '. "$ORCH_HOME/lib/security.sh"; security_gate F002-search '"$sha"'' 2>&1)"; rc=$?
chk_rc 0 "$rc" "both required classes read: passes"
out="$("$ORCH" packet F002-search 2>&1)"
contains "$out" "security-code: 2 new in the diff (1 CWE Top 25), 2 pre-existing, semgrep" "the packet shows the code reading"
contains "$out" "security-iac: 1 new in the diff" "and the iac reading"
contains "$out" "infra/main.tf:2  s3_bucket_level_public_access_block  CIS 2.1.4" "with the CIS id"
out="$(ORCH_SECURITY_CLASSES="deps" "$ORCH" packet F002-search 2>&1)"
contains "$out" "security-deps: NO READING (required)" "and a required class with none"

printf '\nthe lens:\n'
. "$ORCH_ROOT/lib/tier.sh"
contains "$(tier_lenses 2)" "security" "the security lens joins at rung 2"
not_contains "$(tier_lenses 1)" "security" "not at rung 1"
[ "$(ORCH_STRICT_LENSES='' bash -c '. "$ORCH_HOME/lib/tier.sh"; tier_lenses 2')" = "correctness failure-modes reproduction" ]; chk $? "ORCH_STRICT_LENSES empty turns it off"
"$ORCH" team start --feature F002-search >/dev/null 2>&1
jq -e -s 'any(.[]; .event=="agent.printed" and .role=="code-reviewer" and .lens=="security")' docs/features/F002-search/ledger.jsonl >/dev/null
chk $? "team start at strict spawns the security reviewer"
out="$(ORCH_LENS=security bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_orders code-reviewer F002-search')"
contains "$out" "orch security checklist" "its orders start with the checklist"
contains "$out" "cites a CWE id or an ASVS requirement id" "and the citation rule"
contains "$out" "what a pattern cannot see" "and what it is for"
out="$(ORCH_LENS=correctness bash -c '. "$ORCH_HOME/lib/launcher/base.sh"; launcher_orders code-reviewer F002-search')"
not_contains "$out" "checklist" "the other lenses keep their orders"

printf '\nthe axioms:\n'
. "$ORCH_ROOT/lib/axioms.sh"
printf 'def find(conn, name):  # nosemgrep\n    return conn.execute("SELECT * FROM t WHERE name = %s", (name,))\n' > src/db.py
printf 'resource "aws_s3_bucket" "b" {\n  #checkov:skip=CKV_AWS_20\n  acl = "public-read"\n}\n' > infra/main.tf
git add -A && git commit -q -m "silence"
out="$(axioms_scan "$sha" HEAD)"
printf '%s' "$out" | jq -e 'any(.[]; .pattern=="nosemgrep" and .file=="src/db.py")' >/dev/null; chk $? "a nosemgrep comment is an escape hatch"
printf '%s' "$out" | jq -e 'any(.[]; .pattern=="(checkov|bridgecrew):skip" and .file=="infra/main.tf")' >/dev/null; chk $? "so is checkov:skip"
[ "$(printf '%s' "$out" | jq length)" = "2" ]; chk $? "two increases, nothing else"

teardown_repo
finish security
