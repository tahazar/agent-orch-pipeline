#!/bin/bash
# agent-lint.sh - the role definitions, checked mechanically.
#
# Two rules.
#
# 1. EVERY invariant sentence in a role definition must map to a `tools` /
#    `disallowedTools` entry or a hook. A lint that checks only some of them
#    misses the drift, and that is the failure mode worth guarding: a prompt
#    promising a boundary that nothing enforces reads exactly like one that is
#    enforced, right up until it matters.
#
#    The mapping is made checkable rather than inferred: an invariant line ends
#    in `[enforced-by: X]`, and X must name a real mechanism.
#
# 2. Prompt budget. Role definitions are appended to every request the role
#    makes, so they are paid for per turn, not once. A role carrying a playbook
#    for a tier it is never spawned in is pure overhead on every call it makes.
#    Ceilings: workers under 4k tokens, coordinators under 8k.

. "$(cd -P "$(dirname "$0")" && pwd)/lib.sh"
printf 'role definitions\n\n'

AGENTS="$ORCH_ROOT/agents"
ROLES="director tech-lead test-engineer developer code-reviewer auditor"
COORDINATORS="director auditor"
WORKERS="tech-lead test-engineer developer code-reviewer"

# Tokens are estimated at 4 bytes each. The ceiling is an order-of-magnitude
# guard, not a precise budget, and being wrong by 20% here
# changes no decision.
tokens_of() { printf '%s' "$(( $(wc -c < "$1") / 4 ))"; }

fm() {  # fm <file> <key>  - one frontmatter value
  awk -v k="$2" '
    NR==1 && $0=="---" {inside=1; next}
    inside && $0=="---" {exit}
    inside && index($0, k ":")==1 {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}
  ' "$1"
}

printf 'presence:\n'
for r in $ROLES; do
  [ -s "$AGENTS/$r.md" ]; chk $? "agents/$r.md exists"
done
n="$(ls "$AGENTS"/*.md 2>/dev/null | grep -c .)"
[ "$n" = "6" ]; chk $? "there are exactly six roles (got $n) — more roles is not the answer to poor output"

printf '\nfrontmatter:\n'
for r in $ROLES; do
  [ "$(fm "$AGENTS/$r.md" name)" = "$r" ]; chk $? "$r declares its own name"
  [ -n "$(fm "$AGENTS/$r.md" description)" ]; chk $? "$r has a description"
  [ -n "$(fm "$AGENTS/$r.md" tools)" ]; chk $? "$r declares an explicit tools allowlist"
done

printf '\ncapability is enforced by frontmatter, not by prose:\n'
# Invariant 2: extra agents contribute information, never actions.
for t in Edit Write NotebookEdit; do
  case "$(fm "$AGENTS/code-reviewer.md" disallowedTools)" in
    *"$t"*) ok "code-reviewer cannot $t" ;;
    *) bad "code-reviewer's disallowedTools does not include $t — invariant 2 is prose only" ;;
  esac
done
case "$(fm "$AGENTS/code-reviewer.md" tools)" in
  *Edit*|*Write*) bad "code-reviewer's tools allowlist includes a write tool" ;;
  *) ok "code-reviewer's allowlist contains no write tool either" ;;
esac

# Invariant 3: reviewers get fresh context and never the developer's trace. The
# mechanical half is that a code-reviewer cannot go and fetch it.
case "$(fm "$AGENTS/code-reviewer.md" disallowedTools)" in
  *SendMessage*) ok "code-reviewer cannot message the developer for its trace" ;;
  *) bad "code-reviewer can SendMessage — nothing stops it asking for the developer's trace" ;;
esac

# The two roles that must be isolated in a worktree.
for r in developer test-engineer; do
  [ "$(fm "$AGENTS/$r.md" isolation)" = "worktree" ]
  chk $? "$r declares isolation: worktree"
done
for r in director code-reviewer; do
  [ -z "$(fm "$AGENTS/$r.md" isolation)" ]
  chk $? "$r is not needlessly isolated"
done

[ "$(fm "$AGENTS/developer.md" model)" = "sonnet" ]; chk $? "developer runs on sonnet, per §5"
for r in director tech-lead test-engineer auditor; do
  [ "$(fm "$AGENTS/$r.md" model)" = "opus" ]; chk $? "$r runs on opus, per §5"
done

printf '\nevery invariant maps to a mechanism:\n'
for r in $ROLES; do
  grep -q '^## INVARIANTS' "$AGENTS/$r.md"; chk $? "$r declares an INVARIANTS block"

  # Each bullet inside the block must carry an [enforced-by: X] tag.
  block="$(awk '/^## INVARIANTS/{f=1;next} /^## /{f=0} f' "$AGENTS/$r.md")"
  n_bullets="$(printf '%s' "$block" | grep -c '^- ')"
  n_tagged="$(printf '%s' "$block" | grep -c 'enforced-by:')"
  [ "$n_bullets" -gt 0 ] && [ "$n_bullets" = "$n_tagged" ]
  chk $? "$r: all $n_bullets invariants name their mechanism ($n_tagged tagged)"

  # And the named mechanism must exist: a hook file, a frontmatter tool list,
  # or `isolation`. A prose-only invariant fails here.
  for m in $(printf '%s' "$block" | sed -n 's/.*\[enforced-by:[[:space:]]*\([^]]*\)\].*/\1/p'); do
    case "$m" in
      hooks/*)
        [ -x "$ORCH_ROOT/$m" ]; chk $? "$r: $m exists and is executable"
        # And it must actually be wired, or it enforces nothing.
        grep -q "$(basename "$m")" "$ORCH_ROOT/settings.json"
        chk $? "$r: $m is wired in settings.json"
        # A hook that branches on ORCH_ROLE must have a branch for THIS role.
        # Without one it runs, exits 0 and reports nothing, which is
        # indistinguishable from an enforced boundary until it matters.
        #
        # Hooks that never read ORCH_ROLE are exempt because they are universal
        # by design: nobody merges without approval, so gate-guard.sh has no
        # per-role branch to have.
        #
        # What this still does not check: that the hook governs the right KIND
        # of operation. A read-scoping invariant naming a write-scoping hook
        # passes everything here, because both mention the role and both are
        # wired. That gap is real — it cost this repo a code-reviewer invariant
        # claiming hooks/write-scope.sh kept it from reading the developer's
        # trace, which is not something a PreToolUse hook on Edit|Write ever
        # gets the chance to do.
        if grep -q 'ORCH_ROLE' "$ORCH_ROOT/$m"; then
          grep -q "$r" "$ORCH_ROOT/$m"
          chk $? "$r: $m is role-scoped and has a branch for it"
        else
          ok "$r: $m applies to every role"
        fi
        ;;
      isolation)
        [ "$(fm "$AGENTS/$r.md" isolation)" = "worktree" ]
        chk $? "$r: isolation is declared in the frontmatter"
        ;;
      disallowedTools)
        [ -n "$(fm "$AGENTS/$r.md" disallowedTools)" ]
        chk $? "$r: disallowedTools is declared in the frontmatter"
        ;;
      *)
        # Anything else must be a tool the role actually has.
        case "$(fm "$AGENTS/$r.md" tools)" in
          *"$m"*) ok "$r: $m is in its tools allowlist" ;;
          *) bad "$r: invariant claims '$m' enforces it, but that is neither a hook, isolation, nor a tool this role has" ;;
        esac
        ;;
    esac
  done
done

printf '\nno role promises a boundary in prose alone:\n'
# A role that says "never merge" must be a role that cannot merge. The gate
# hook covers everyone, so what we check is that nobody claims a merge right.
for r in $ROLES; do
  [ "$r" = "director" ] && continue
  if grep -qi 'you may merge\|you can merge\|merge the branch yourself' "$AGENTS/$r.md"; then
    bad "$r claims a merge right it does not have"
  else
    ok "$r claims no merge right"
  fi
done

printf '\nprompt budget — every role definition is paid for on every turn it takes:\n'
total=0
for r in $WORKERS; do
  t="$(tokens_of "$AGENTS/$r.md")"; total=$((total + t))
  [ "$t" -lt 4000 ]; chk $? "$r is ${t} tokens (worker ceiling 4000)"
done
for r in $COORDINATORS; do
  t="$(tokens_of "$AGENTS/$r.md")"; total=$((total + t))
  [ "$t" -lt 8000 ]; chk $? "$r is ${t} tokens (coordinator ceiling 8000)"
done
[ "$total" -lt 12000 ]
chk $? "all six roles total ${total} tokens (ceiling 12000)"

printf '\nno role carries protocol it cannot act on:\n'
# The developer is never spawned at rung 0 or 1, so a developer prompt that
# explains the whole ladder is paying for context it cannot use. Each worker
# should mention at most the rungs it participates in.
for r in test-engineer code-reviewer; do
  if grep -q 'orch candidates\|orch diagnose\|orch escalate' "$AGENTS/$r.md"; then
    bad "$r carries coordination commands it never runs"
  else
    ok "$r carries no coordination commands"
  fi
done
grep -q 'orch escalate' "$AGENTS/director.md"; chk $? "the director does own the ladder"

finish agent-lint
