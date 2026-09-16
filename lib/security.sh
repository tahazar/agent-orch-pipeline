#!/bin/bash
# security.sh - the security sensor, and the references the security lens
# reviews against.
#
# Four frameworks, as data under lib/security/ (each file says where it
# came from and how it was verified):
#
#   OWASP Top 10:2025          ten categories and the CWEs each maps [P50]
#   OWASP ASVS 5.0.0           345 verification requirements, V1–V17, L1–L3 [P51]
#   CWE Top 25 (2024)          the 25 most dangerous weaknesses [P52]
#   CIS AWS Foundations 4.0.1  64 recommendations for hardening an AWS
#                              account, as mapped by Prowler [P53]
#
# Three mechanisms, in the order orch trusts them:
#
#   the sensor   `orch sensor security F --class code|deps|iac --sarif FILE`
#                reads a scanner's SARIF (semgrep, CodeQL, bandit, gosec,
#                trivy, checkov, tfsec all write it), keeps the results the
#                diff touched, maps each to its CWE, its OWASP category, the
#                Top 25 and a CIS id where it can, and records a ledger
#                reading. Each new result is a finding raised by `security`:
#                blocking when it is Top 25 or the tool says error, major
#                otherwise. With ORCH_T_SECURITY set, more new results than
#                that is a gate failure; with ORCH_SECURITY_CLASSES set, a
#                class with no reading at HEAD is SENSOR_MISSING. The run
#                must be attested (`orch run --label security-<class>`) at the
#                same sha, like coverage.
#   the lens     `security` joins the review ensemble at strict. Its orders
#                start with `orch security checklist`, and every finding it
#                raises cites a CWE id or an ASVS requirement id. The scanner
#                finds what a pattern finds; the lens is for what a pattern
#                cannot see — missing authorization, a business-logic bypass,
#                a secret in the wrong place.
#   the axioms   `# nosec`, `# nosemgrep`, `checkov:skip`, `trivy:ignore` and
#                the rest are escape hatches like `.skip`: an increase in the
#                diff is a blocking finding (lib/axioms.sh).
#
# What this does not do: run a scanner. Which one, with which rules, is the
# repository's call; orch attests that it ran and reads what it wrote.

[ -n "${ORCH_SECURITY_SOURCED:-}" ] && return 0
ORCH_SECURITY_SOURCED=1

# shellcheck source=sensors.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sensors.sh"
# shellcheck source=findings.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"

ORCH_SECURITY_DATA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/security"
ORCH_SECURITY_CLASS_LIST="code deps iac"
: "${ORCH_T_SECURITY:=}"          # max new findings per class; empty = report only
: "${ORCH_SECURITY_CLASSES:=}"    # classes that must have a reading at HEAD; empty = none required
: "${ORCH_CWE_TOP25_FILE:=$ORCH_SECURITY_DATA/cwe-top25-2024.txt}"

_sec_data() { grep -v '^#' "$ORCH_SECURITY_DATA/$1" | grep .; }

# ---------------------------------------------------------------------------
# The references
# ---------------------------------------------------------------------------

security_top25() {  # "rank CWE-n name" per line
  grep -v '^#' "$ORCH_CWE_TOP25_FILE" | grep .
}
security_is_top25() { security_top25 | awk '{print $2}' | grep -qx "$1"; }

# security_owasp_of <CWE-n> -> the OWASP Top 10:2025 categories mapping it
security_owasp_of() {
  _sec_data owasp-top10-2025.tsv | awk -F'\t' -v c="$1" '{ n = split($3, a, " "); for (i = 1; i <= n; i++) if (a[i] == c) print $1 }'
}
security_owasp_name() { _sec_data owasp-top10-2025.tsv | awk -F'\t' -v c="$1" '$1 == c {print $2}'; }

# security_asvs [V1 | V1.2 | 1.2.5 | word] -> matching requirements
security_asvs() {
  local q="${1:-}"
  case "$q" in
    '')            _sec_data asvs-5.0.0.tsv | awk -F'\t' '{print $3}' | uniq ;;
    V[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*)
                   _sec_data asvs-5.0.0.tsv | awk -F'\t' -v q="V${q#V}" '$1 == q {print $1 " (L" $2 ") " $5}' ;;
    V[0-9]*.[0-9]*) _sec_data asvs-5.0.0.tsv | awk -F'\t' -v q="$q " 'index($4, q) == 1 {print $1 " (L" $2 ") " $5}' ;;
    V[0-9]*)       _sec_data asvs-5.0.0.tsv | awk -F'\t' -v q="$q " 'index($3, q) == 1 {print $1 " (L" $2 ") " $5}' ;;
    *)             _sec_data asvs-5.0.0.tsv | grep -i -- "$q" | awk -F'\t' '{print $1 " (L" $2 ") " $5}' ;;
  esac
}

# security_cis [section-prefix | check-name] -> CIS AWS recommendations
security_cis() {
  local q="${1:-}"
  if [ -z "$q" ]; then _sec_data cis-aws-4.0.1.tsv | awk -F'\t' '{print $2}' | uniq; return 0; fi
  _sec_data cis-aws-4.0.1.tsv | awk -F'\t' -v q="$q" '
    index($1, q) == 1 || index($6, q) > 0 { printf "%s  %s  (%s)  checks: %s\n", $1, $4, $5, $6 }'
}
security_cis_of_check() {  # security_cis_of_check <prowler check or rule id> -> CIS id
  _sec_data cis-aws-4.0.1.tsv | awk -F'\t' -v q="$1" '{ n = split($6, a, ","); for (i = 1; i <= n; i++) if (a[i] == q) { print $1; exit } }'
}

# The checklist the lens reads first. OWASP Top 10:2025 sets the categories,
# ASVS names what to verify in each, the Top 25 says what to weight, CIS
# says what to check when the diff touches infrastructure.
security_checklist() {
  cat <<'EOM'
SECURITY LENS — what to review against, in this order.

The scanner (orch sensor security) has already raised what a pattern finds.
You are for what a pattern cannot see. Every finding cites a CWE id or an
ASVS requirement id in its claim, e.g. "[CWE-862][ASVS 8.2.1] the export
endpoint checks that the caller is logged in, not that the report is theirs".

OWASP Top 10:2025 — ask each of these of the diff (ASVS chapters in brackets):
  A01 Broken Access Control        Who may call this, and where is that checked? Object ids from the
                                   client used without an ownership check? New route, new POST/PUT/DELETE,
                                   new CORS origin? [V8 Authorization, V4 API, V3.5 Origin Separation]
  A02 Security Misconfiguration    A default left on, a debug flag, a header removed, XML parsers with
                                   external entities, a permissive CORS or CSP? [V13 Configuration, V3.4 Headers]
  A03 Software Supply Chain        A new dependency, a version pin loosened, a lockfile changed, a
                                   script fetched at build or install time, an unpinned action? [V15.2]
  A04 Cryptographic Failures       Secrets, tokens, passwords: how stored, how compared, which
                                   algorithm, which randomness, TLS off anywhere? [V11 Cryptography,
                                   V12 Secure Communication, V6.2 Password Security, V14 Data Protection]
  A05 Injection                    Any string built from input and handed to SQL, a shell, a template,
                                   HTML, LDAP, a path, a log line? [V1.2 Injection Prevention, V1.3 Sanitization]
  A06 Insecure Design              A flow that trusts the client's claim (price, role, step), missing
                                   rate limit on an expensive or sensitive action, a race on a check-
                                   then-act? [V2 Validation and Business Logic, V15.4 Concurrency]
  A07 Authentication Failures      Login, reset, MFA, session creation, remember-me: enumeration,
                                   brute force, weak recovery, credentials in config? [V6 Authentication,
                                   V7 Session Management, V9/V10 tokens and OAuth]
  A08 Software or Data Integrity   Deserializing untrusted data, unsigned updates or plugins, CI that
                                   runs what a PR says? [V1.5 Safe Deserialization, V15.2]
  A09 Logging and Alerting         Security events logged? Logs free of secrets and of input that
                                   forges entries? [V16 Security Logging and Error Handling]
  A10 Exceptional Conditions       Errors that leak internals, a caught exception that fails open, a
                                   missing parameter handled as a default? [V16.5 Error Handling, V15.3]

CWE Top 25 (2024) — a finding in one of these is blocking, not major:
EOM
  security_top25 | awk '{ printf "  %2s  %-8s %s\n", $1, $2, substr($0, index($0, $3)) }'
  cat <<'EOM'

CIS AWS Foundations Benchmark 4.0.1 — when the diff touches infrastructure
(Terraform, CloudFormation, CDK, IAM policies, bucket policies, security
groups). Sections: 1 IAM, 2 Storage (S3, RDS, EFS), 3 Logging, 4 Monitoring,
5 Networking. `orch security cis 2.1` lists a section; the recurring ones:
  1.16  no IAM policy grants full *:* administrative privileges
  2.1.1 S3 bucket policies deny HTTP;   2.1.4 Block Public Access on
  2.2.1 RDS encryption at rest;         2.2.3 RDS not publicly accessible
  3.1   CloudTrail in all regions;      3.7 VPC flow logs
  5.3   no security group allows 0.0.0.0/0 to admin ports;  5.7 IMDSv2 only

Look up a requirement:  orch security asvs V8.2   orch security owasp CWE-89   orch security cis 5.3
EOM
}

# ---------------------------------------------------------------------------
# The sensor
# ---------------------------------------------------------------------------

# "<file> <line>" for every line the diff added or changed, any file type —
# an IaC file is not source by ORCH_SOURCE_EXT and is exactly what class iac
# is about.
_security_diff_lines() {  # _security_diff_lines <base> <head>
  git -C "$(_sensor_repo)" diff -U0 "$1" "$2" -- . ':(exclude)docs/features' 2>/dev/null \
  | awk '
      /^\+\+\+ / { f = $2; sub(/^b\//, "", f); next }
      /^@@ / { split($3, p, ","); s = p[1]; sub(/^\+/, "", s)
               n = (p[2] == "" ? 1 : p[2])
               for (i = 0; i < n; i++) print f, s + i }'
}

# Every result in a SARIF file, one JSON object per line: rule, level,
# message, file, line, and the CWE ids found anywhere in the rule's or the
# result's metadata (semgrep's "CWE-89: ..." tags, CodeQL's
# external/cwe/cwe-089, trivy's help text). Paths made repo-relative.
security_sarif_results() {  # security_sarif_results <file>
  local repo; repo="$(_sensor_repo)"
  jq -c --arg repo "$repo/" '
    .runs[]? as $run
    | (($run.tool.driver.rules // []) + ([$run.tool.extensions[]?.rules[]?])) as $rules
    | ($run.tool.driver.name // "?") as $tool
    | $run.results[]?
    | (.ruleId // .rule.id // "?") as $rid
    | ([$rules[] | select(.id == $rid)] | first // {}) as $rule
    | (($rule | tostring) + " " + ((.properties // {}) | tostring)) as $meta
    | { tool: $tool, rule: $rid,
        level: (.level // $rule.defaultConfiguration.level // "warning"),
        message: ((.message.text // $rule.shortDescription.text // "") | .[0:200]),
        file: ((.locations[0].physicalLocation.artifactLocation.uri // "") | ltrimstr("file://") | ltrimstr($repo) | ltrimstr("./")),
        line: (.locations[0].physicalLocation.region.startLine // 0),
        cwe: ([$meta | scan("(?i)cwe[-/]0*([0-9]+)") | "CWE-" + .[0]] | unique) }' "$1" 2>/dev/null
}

# sensor_security <feature> --class code|deps|iac --sarif FILE [--sha S] [--base B]
sensor_security() {
  local feature="$1"; shift
  local class='' sarif='' sha='' base='' repo d rows r cwe top25 owasp cis sev claim cons file line n_new n_pre n_top n_raised=0 tool
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class) class="$2"; shift 2 ;;
      --sarif) sarif="$2"; shift 2 ;;
      --sha)   sha="$2"; shift 2 ;;
      --base)  base="$2"; shift 2 ;;
      *) die "sensor security: unexpected argument '$1'" ;;
    esac
  done
  case " $ORCH_SECURITY_CLASS_LIST " in *" $class "*) ;; *) die "sensor security: --class must be one of: $ORCH_SECURITY_CLASS_LIST (code: SAST; deps: dependency and container CVEs; iac: infrastructure and cloud configuration)" ;; esac
  repo="$(_sensor_repo)"
  [ -n "$sha" ] || sha="$(orch_head_sha)"
  [ -n "$base" ] || base="$(_sensor_base "$sha")"
  [ -n "$sarif" ] || die "sensor security: --sarif FILE is required (every supported scanner writes SARIF)"
  case "$sarif" in /*) ;; *) sarif="$repo/$sarif" ;; esac
  [ -r "$sarif" ] || die "sensor security: no SARIF report at $sarif"
  r="$(evidence_latest "$feature" "security-$class")"
  [ -n "$r" ] || die "sensor security: no attested \`security-$class\` run for $feature — run the scanner through orch:
  orch run --feature $feature --label security-$class -- <scanner writing $sarif>"
  [ "$(printf '%s' "$r" | jq -r '.git_sha // ""')" = "$sha" ] \
    || die "sensor security: the attested security-$class run is not at $sha — run it again"

  d="$(mktemp "${TMPDIR:-/tmp}/orch-sec.XXXXXX")"
  _security_diff_lines "$base" "$sha" | sort -u > "$d"
  git -C "$repo" diff --name-only "$base" "$sha" -- . ':(exclude)docs/features' 2>/dev/null | sort -u > "$d.files"
  # In the diff: the file changed, and the line is one the diff touched
  # (or the result has no line, which is a whole-file or dependency finding).
  rows="$(security_sarif_results "$sarif" | while IFS= read -r r; do
      file="$(printf '%s' "$r" | jq -r .file)"; line="$(printf '%s' "$r" | jq -r .line)"
      if ! grep -qxF -- "$file" "$d.files"; then scope=pre_existing
      elif [ "${line:-0}" -gt 0 ] && ! grep -qxF -- "$file $line" "$d"; then scope=pre_existing
      else scope=new; fi
      top25=false; owasp='[]'; cis=''
      for cwe in $(printf '%s' "$r" | jq -r '.cwe[]'); do
        security_is_top25 "$cwe" && top25=true
        owasp="$(printf '%s' "$owasp" | jq -c --argjson o "$(security_owasp_of "$cwe" | jq -R . | jq -s -c .)" '. + $o | unique')"
      done
      [ "$class" = iac ] && cis="$(security_cis_of_check "$(printf '%s' "$r" | jq -r .rule)")"
      printf '%s\n' "$r" | jq -c --arg s "$scope" --argjson t "$top25" --argjson o "$owasp" --arg c "${cis:-}" '. + {scope: $s, top25: $t, owasp: $o, cis: $c}'
    done | jq -s -c '.')"
  rm -f "$d" "$d.files"
  n_new="$(printf '%s' "$rows" | jq '[.[] | select(.scope=="new")] | length')"
  n_pre="$(printf '%s' "$rows" | jq '[.[] | select(.scope=="pre_existing")] | length')"
  n_top="$(printf '%s' "$rows" | jq '[.[] | select(.scope=="new" and .top25)] | length')"
  tool="$(printf '%s' "$rows" | jq -r '.[0].tool // "?"')"

  # Each new result is a finding, once.
  printf '%s' "$rows" | jq -c '.[] | select(.scope=="new")' | while IFS= read -r r; do
    file="$(printf '%s' "$r" | jq -r .file)"; line="$(printf '%s' "$r" | jq -r .line)"
    claim="$(printf '%s' "$r" | jq -r '"\(.rule): \(.message) [" + ((.cwe + .owasp + (if .top25 then ["CWE Top 25"] else [] end) + (if .cis != "" then ["CIS " + .cis] else [] end)) | join(" ")) + "]"')"
    if [ "$(printf '%s' "$r" | jq -r '.top25')" = true ] || [ "$(printf '%s' "$r" | jq -r .level)" = error ]; then sev=blocking; else sev=major; fi
    cons="the scanner ($(printf '%s' "$r" | jq -r .tool)) flags this in code the diff introduced; a pattern that fires is a weakness until the dispute says why it is not"
    findings_current "$feature" | jq -e --arg f "$file" --arg c "$claim" 'select(.raised_by=="security" and .file==$f and .claim==$c)' >/dev/null 2>&1 && continue
    findings_add "$feature" security "$sev" "$file" "$line" "$claim" "$cons" >/dev/null
  done
  n_raised="$(findings_current "$feature" | jq -s '[.[] | select(.raised_by=="security" and .status=="open")] | length' 2>/dev/null || printf 0)"

  ORCH_LEDGER_FEATURE="$feature" ledger_append sensor.security \
    at_sha "$sha" base "$base" class "$class" tool "$tool" new:raw "$n_new" pre_existing:raw "$n_pre" top25:raw "$n_top" \
    results:raw "$(printf '%s' "$rows" | jq -c '[.[] | select(.scope=="new") | {rule, level, file, line, cwe, owasp, top25, cis}]')"
  jq -n -c --arg sha "$sha" --arg class "$class" --arg tool "$tool" --argjson new "$n_new" --argjson pre_existing "$n_pre" \
    --argjson top25 "$n_top" --argjson open "${n_raised:-0}" '$ARGS.named'
}

security_latest() {  # security_latest <feature> <class> -> the last reading of that class, or nothing
  ledger_read "$1" | jq -c -s --arg c "$2" '[.[] | select(type=="object" and .event=="sensor.security" and .class==$c)] | if length==0 then empty else .[-1] end' 2>/dev/null
}

# security_gate <feature> <sha> -> 0, or 8 with the reason on stderr.
security_gate() {
  local feature="$1" sha="$2" c r n
  for c in $ORCH_SECURITY_CLASSES; do
    r="$(security_latest "$feature" "$c")"
    if [ -z "$r" ] || [ "$(printf '%s' "$r" | jq -r '.at_sha // ""')" != "$sha" ]; then
      printf 'SENSOR_MISSING: no security-%s reading at %s (ORCH_SECURITY_CLASSES names it).\n  orch run --feature %s --label security-%s -- <scanner>; orch sensor security %s --class %s --sarif <file>\n' \
        "$c" "$(printf '%s' "$sha" | cut -c1-12)" "$feature" "$c" "$feature" "$c" >&2
      return 8
    fi
  done
  [ -n "$ORCH_T_SECURITY" ] || return 0
  for c in $ORCH_SECURITY_CLASS_LIST; do
    r="$(security_latest "$feature" "$c")"; [ -n "$r" ] || continue
    [ "$(printf '%s' "$r" | jq -r '.at_sha // ""')" = "$sha" ] || continue
    n="$(printf '%s' "$r" | jq -r '.new // 0')"
    if [ "$n" -gt "$ORCH_T_SECURITY" ]; then
      printf 'SECURITY_FINDINGS: %s new %s finding(s) in the diff at %s (threshold ORCH_T_SECURITY=%s), %s of them CWE Top 25:\n%s\n' \
        "$n" "$c" "$(printf '%s' "$sha" | cut -c1-12)" "$ORCH_T_SECURITY" "$(printf '%s' "$r" | jq -r '.top25 // 0')" \
        "$(printf '%s' "$r" | jq -r '.results[] | "  \(.file):\(.line)  \(.rule)  \(.cwe | join(" "))\(if .top25 then "  TOP25" else "" end)"')" >&2
      return 8
    fi
  done
  return 0
}

security_render() {  # security_render <feature> <head> — the lines for the packet and the report
  local feature="$1" head="$2" c r
  for c in $ORCH_SECURITY_CLASS_LIST; do
    r="$(security_latest "$feature" "$c")"
    if [ -z "$r" ]; then
      case " $ORCH_SECURITY_CLASSES " in *" $c "*) printf '  security-%s: NO READING (required)\n' "$c" ;; esac
      continue
    fi
    printf '  security-%s: %s new in the diff (%s CWE Top 25), %s pre-existing, %s, at %s%s\n' "$c" \
      "$(printf '%s' "$r" | jq -r .new)" "$(printf '%s' "$r" | jq -r .top25)" "$(printf '%s' "$r" | jq -r .pre_existing)" \
      "$(printf '%s' "$r" | jq -r .tool)" "$(printf '%s' "$r" | jq -r '.at_sha[0:12]')" \
      "$([ "$(printf '%s' "$r" | jq -r .at_sha)" = "$head" ] || printf '  (NOT at HEAD)')"
    printf '%s' "$r" | jq -r '.results[] | "      \(.file):\(.line)  \(.rule)  " + ([.cwe[], .owasp[], (if .top25 then "TOP25" else empty end), (if .cis != "" then "CIS " + .cis else empty end)] | join(" "))'
  done
}
