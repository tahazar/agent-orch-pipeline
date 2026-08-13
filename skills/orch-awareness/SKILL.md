---
name: orch-awareness
description: Join a running orch pipeline session. Use when the user asks you to help with, inspect, or participate in an orch run; when you find a .orch/ directory or docs/features/ artifacts in the repo; or when you have been launched with ORCH_ROLE set.
---

# Joining an orch run

`orch` coordinates several Claude sessions through a shared task list. You may
be one of its agents, or a session someone opened alongside it. Work out which
before doing anything.

## First: are you a role, or a bystander?

```bash
echo "${ORCH_ROLE:-none}"
orch team status
```

**If `ORCH_ROLE` is set**, you are part of the crew. Your role definition is in
`.claude/agents/$ORCH_ROLE.md` and it is authoritative — read it before acting.
The boundaries in it are enforced by hooks that exit 2, so ignoring them
produces a blocked tool call rather than a warning.

**If it is not set**, you are a bystander. You can read everything and run
`orch` commands, but do not do the crew's work for them. A bystander that
implements the feature destroys the only boundary that makes the run
measurable, and the artifacts will disagree with the code afterwards.

## Where the state is

Never guess at run state from what an agent said. All of it is on disk:

```bash
orch watch                    # rung, signals, recent events
orch tier show <feature>      # tier, who recommended it, why
orch report <feature>         # cost, uptake, gate yield
orch findings list <feature>  # open review findings
cat docs/features/<feature>/requirements.md
```

`docs/features/<F>/ledger.jsonl` is the append-only event record. It is the
answer to "what actually happened", and it is more reliable than any summary.

## The rules that bind every session

**Nothing merges without a human.** `orch approve <feature> --gate human` is the
only way through, it binds to the current sha, and it is void if the branch
moves. Do not offer to work around it.

**A claim is not evidence.** The only way to make a test result count:

```bash
orch run --feature <F> --label tests -- <command>
```

Anything else is an assertion, and approvals citing it are rejected.

**A message is never load-bearing.** Every state transition is a task-list
mutation plus an artifact write. If you find yourself writing "remember that we
decided X" to another session, that belongs in a task or an artifact instead.

## If you are asked to help a stuck run

Diagnose before adding agents. More roles is not the answer to poor output.

```bash
orch health signals <feature>   # what the detector sees
orch escalate check <feature>   # act on it, if warranted
orch doctor                     # is the team actually coordinating?
```

`orch doctor` is the first thing to run when agents seem to be ignoring each
other. The usual cause is a mismatched `CLAUDE_CODE_TASK_LIST_ID` or a
permission-mode class difference — both of which produce silence rather than an
error.

If the run is genuinely stuck and no experiment would distinguish the
possibilities, that is rung 5 and it is correct to hand it back to the human
with the ledger slice rather than keep trying.
