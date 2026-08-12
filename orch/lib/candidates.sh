#!/bin/bash
# candidates.sh - best-of-N with attested selection (rung 3).
#
# The largest coding-specific gain in the published record: SWE-bench Verified
# 20.6% -> 28.8% at Best@8 -> 32.0% at Best@16, with the verifier picking
# correctly ~86% of the time - meaning generation diversity, not verification,
# was the binding constraint [P18]. Note what the pattern is: multi-agent with
# no coordination, no handoffs, and no shared state. It fails cleanly, which is
# most of why it works.
#
# Two rules make it safe under invariant 1:
#   - every candidate lives in its own worktree and exactly one merges
#   - selection is mechanical and happens BEFORE any model judgement
#
# The second is the one people skip. A model asked to pick a winner will find a
# reason to prefer the candidate whose reasoning it can follow; a ranking over
# attested exit codes and diff sizes cannot.

[ -n "${ORCH_CANDIDATES_SOURCED:-}" ] && return 0
ORCH_CANDIDATES_SOURCED=1

# shellcheck source=evidence.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evidence.sh"
# escalate.sh for escalate_base_branch, the fallback when a candidate's base sha
# is missing from the ledger.
# shellcheck source=escalate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/escalate.sh"

: "${ORCH_BEST_OF_N:=3}"

# The approach directives. Diversity is the binding constraint, so these are
# genuinely different strategies, not the same instruction at three
# temperatures.
candidates_approach() {  # candidates_approach <index>
  case "$1" in
    1) printf 'minimal-diff|Make the smallest change that turns the gates green. Prefer touching one function over refactoring a module. Do not add abstractions.' ;;
    2) printf 'root-cause|Fix the underlying defect even if the diff is larger. Explain in the commit message what the real cause was and why the obvious local fix would have been a patch over it.' ;;
    3) printf 'defensive|Fix the defect and add the guard that prevents this whole class of bug - a precondition check, a type, or a test that would have caught it earlier.' ;;
    *) printf 'alternate-%s|Solve it in a way materially different from the minimal, root-cause, and defensive approaches. If you find yourself writing one of those, choose differently.' "$1" ;;
  esac
}

candidates_root()  { printf '%s/.orch/worktrees/%s' "${ORCH_REPO:-.}" "$1"; }
candidates_path()  { printf '%s/candidates.jsonl' "$(orch_feature_dir "$1")"; }
candidates_branch() { printf 'orch/%s/c%s' "$1" "$2"; }

# candidates_start <feature> [n]
candidates_start() {
  local feature="$1" n="${2:-$ORCH_BEST_OF_N}" i root wt br approach name directive
  orch_valid_feature "$feature" || die "candidates: invalid feature '$feature'"
  case "$n" in ''|*[!0-9]*) die "candidates: N must be a number" ;; esac
  [ "$n" -ge 2 ] || die "candidates: N must be at least 2 (got $n)"

  root="$(candidates_root "$feature")"
  mkdir -p "$root"
  i=1
  while [ "$i" -le "$n" ]; do
    wt="$root/c$i"
    br="$(candidates_branch "$feature" "$i")"
    if [ -e "$wt" ]; then
      warn "candidate $i already exists at $wt; leaving it alone"
    else
      git -C "$ORCH_REPO" worktree add -q -b "$br" "$wt" HEAD \
        || die "candidates: could not create worktree $wt"
    fi
    approach="$(candidates_approach "$i")"
    name="${approach%%|*}"; directive="${approach#*|}"
    mkdir -p "$wt/docs/features/$feature"
    cat > "$wt/docs/features/$feature/APPROACH.md" <<EOF
# Candidate c$i — $name

$directive

## Rules

- You are one of $n candidates. You will not see the others and they will not
  see you. Exactly one candidate merges; the rest are archived with their gate
  results.
- Work only inside this worktree. Writes to the main checkout are blocked by
  the platform, not by this instruction.
- Every gate claim must be attested:
  \`orch run --feature $feature --label <gate> -- <command>\`
- Selection is mechanical and runs before any model reads your work. Arguing
  for your approach in a comment has no effect on it.
EOF
    # The sha every candidate branched from. Recorded because `collect` has to
    # measure each diff against it: HEAD~1..HEAD would only see the last commit,
    # which would rank a candidate that made three commits as smaller than one
    # that made a single larger one. Ranking on the wrong number is worse than
    # not ranking at all, because it looks mechanical.
    ORCH_LEDGER_FEATURE="$feature" ledger_append candidate.started \
      candidate "c$i" approach "$name" branch "$br" worktree "$wt" \
      base_sha "$(git -C "$ORCH_REPO" rev-parse HEAD 2>/dev/null)"
    printf 'c%s  %-14s %s\n' "$i" "$name" "$wt"
    i=$((i + 1))
  done
  ORCH_LEDGER_FEATURE="$feature" ledger_append bestofn.started n:raw "$n"
}

candidates_list() {  # candidates_list <feature>  -> "c1 c2 c3"
  local root; root="$(candidates_root "$1")"
  [ -d "$root" ] || return 0
  ls "$root" 2>/dev/null | sed -n 's/^\(c[0-9][0-9]*\)$/\1/p' | sort -V
}

# A numeric metric a candidate attested, or empty. The value is the last line
# of the recorded stdout, so the command has to actually print it - there is no
# path here for a model to assert a number it did not compute.
_cand_metric() {  # _cand_metric <worktree> <feature> <label>
  local v
  v="$(ORCH_REPO="$1" evidence_latest "$2" "$3" 2>/dev/null \
        | jq -r 'select(.exit_code==0) | .stdout_tail // ""' 2>/dev/null \
        | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)"
  printf '%s' "$v"
}

# candidates_collect <feature> [gates...]
#
# Reads each candidate's own evidence.jsonl - candidates cannot write to the
# main checkout, so their attestations live in their worktrees and the
# conductor gathers them.
candidates_collect() {
  local feature="$1"; shift
  local gates="${*:-build tests}"
  local c wt row passed total g rc diff_lines tests_passed lint out='' br base

  for c in $(candidates_list "$feature"); do
    wt="$(candidates_root "$feature")/$c"
    br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    passed=0; total=0
    for g in $gates; do
      total=$((total + 1))
      rc="$(ORCH_REPO="$wt" evidence_latest "$feature" "$g" 2>/dev/null | jq -r '.exit_code // "none"')"
      [ "$rc" = "0" ] && passed=$((passed + 1))
    done
    # Measure the whole candidate, not its last commit — see candidate.started.
    base="$(ledger_read "$feature" | jq -s -r --arg c "$c" '
      [.[] | select(type=="object" and .event=="candidate.started" and .candidate==$c) | .base_sha // empty] | last // ""' 2>/dev/null)"
    [ -n "$base" ] || base="$(git -C "$wt" merge-base HEAD "$(escalate_base_branch)" 2>/dev/null)"
    # docs/features is excluded: orch writes APPROACH.md into every candidate's
    # worktree, so a candidate that commits it carries ~15 lines that say
    # nothing about its solution. More importantly, diff size is a ranking axis
    # — a candidate should not be penalised for writing down its reasoning, nor
    # rewarded for not committing a file orch put there.
    if [ -n "$base" ]; then
      diff_lines="$(git -C "$wt" diff --numstat "$base..HEAD" -- . ':(exclude)docs/features' 2>/dev/null \
                    | awk '{a+=$1; d+=$2} END {print (a+d)+0}')"
    else
      warn "candidates: no base sha for $c; its diff size is unranked"
      diff_lines=0
    fi
    [ -n "$diff_lines" ] || diff_lines=0
    tests_passed="$(_cand_metric "$wt" "$feature" tests-passed-count)"
    lint="$(_cand_metric "$wt" "$feature" lint-count)"
    row="$(orch_json candidate "$c" branch "${br:-}" worktree "$wt" \
      approach "$(candidates_approach "${c#c}" | cut -d'|' -f1)" \
      gates_passed:raw "$passed" gates_total:raw "$total" \
      diff_lines:raw "$diff_lines" \
      tests_passed:raw "${tests_passed:-null}" \
      lint_violations:raw "${lint:-null}" \
      collected_at "$(now_iso)")"
    out="${out}${row}
"
    ORCH_LEDGER_FEATURE="$feature" ledger_append candidate.collected \
      candidate "$c" gates_passed:raw "$passed" gates_total:raw "$total" diff_lines:raw "$diff_lines"
  done
  [ -n "$out" ] || { warn "no candidates found for $feature"; return 1; }
  printf '%s' "$out" | grep -v '^$' | orch_atomic_write "$(candidates_path "$feature")"
  cat "$(candidates_path "$feature")"
}

# candidates_select <feature>
#
# Hard filter first: any candidate that failed a gate is out, regardless of how
# good the rest of it looks. Then rank the survivors on attested numbers only.
# Ties at the top are the ONLY place a model gets a say, and even then the
# fallback is the smaller diff rather than another opinion.
candidates_select() {
  local feature="$1" f ranked top n_tied winner reason
  f="$(candidates_path "$feature")"
  [ -r "$f" ] || die "candidates: run \`orch candidates collect $feature\` first"

  ranked="$(jq -s -c '
    [.[] | select(type=="object")]
    | map(. + {eligible: (.gates_total > 0 and .gates_passed == .gates_total)})
    | (map(select(.eligible))
       | sort_by([ (if .tests_passed == null then 0 else -.tests_passed end),
                   (.lint_violations // 0),
                   .diff_lines ])) as $ok
    | {eligible: $ok, rejected: map(select(.eligible | not))}' "$f" 2>/dev/null)"

  if [ "$(printf '%s' "$ranked" | jq '.eligible | length')" = "0" ]; then
    printf 'No candidate passed every gate. Rejected:\n' >&2
    printf '%s' "$ranked" | jq -r '.rejected[] | "  \(.candidate)  \(.gates_passed)/\(.gates_total) gates, \(.diff_lines) lines"' >&2
    ORCH_LEDGER_FEATURE="$feature" ledger_append bestofn.no_winner
    return 1
  fi

  top="$(printf '%s' "$ranked" | jq -c '.eligible[0]')"
  n_tied="$(printf '%s' "$ranked" | jq --argjson t "$top" '
    [.eligible[] | select(.tests_passed == $t.tests_passed
                          and (.lint_violations // 0) == ($t.lint_violations // 0)
                          and .diff_lines == $t.diff_lines)] | length')"
  winner="$(printf '%s' "$top" | jq -r '.candidate')"

  if [ "${n_tied:-1}" -gt 1 ]; then
    reason="tied on every attested axis with $((n_tied - 1)) other candidate(s); took the smallest diff"
  else
    reason="best on attested ranking (gates $(printf '%s' "$top" | jq -r '.gates_passed')/$(printf '%s' "$top" | jq -r '.gates_total'), $(printf '%s' "$top" | jq -r '.diff_lines') diff lines)"
  fi

  ORCH_LEDGER_FEATURE="$feature" ledger_append bestofn.selected \
    winner "$winner" reason "$reason" \
    eligible:raw "$(printf '%s' "$ranked" | jq '.eligible | length')" \
    archived:raw "$(printf '%s' "$ranked" | jq '.eligible + .rejected | length')" \
    ranking:raw "$(printf '%s' "$ranked" | jq -c '[.eligible[] | {candidate, gates_passed, diff_lines, tests_passed, lint_violations}]')"

  printf '%s\n' "$winner"
  {
    printf 'selected %s — %s\n' "$winner" "$reason"
    printf 'all candidates archived to the ledger:\n'
    printf '%s' "$ranked" | jq -r '
      (.eligible[]  | "  \(.candidate)  ELIGIBLE  gates \(.gates_passed)/\(.gates_total)  \(.diff_lines) lines  [\(.approach)]"),
      (.rejected[] | "  \(.candidate)  rejected  gates \(.gates_passed)/\(.gates_total)  \(.diff_lines) lines  [\(.approach)]")'
    printf 'If the top two tie on every axis, the reviewer ensemble breaks it; if they still tie, the smaller diff wins.\n'
  } >&2
}

# candidates_clean <feature> [--keep <cN>]
candidates_clean() {
  local feature="$1" keep="${2:-}" c root wt
  root="$(candidates_root "$feature")"
  for c in $(candidates_list "$feature"); do
    [ "$c" = "$keep" ] && continue
    wt="$root/$c"
    git -C "$ORCH_REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    ORCH_LEDGER_FEATURE="$feature" ledger_append candidate.discarded candidate "$c"
    printf 'removed %s\n' "$wt"
  done
  rmdir "$root" 2>/dev/null || true
}
