# Agent Orchestrator Pipeline

A serial multi-agent development workflow for [Claude Code](https://claude.com/claude-code),
running locally on macOS as tmux panes.

It builds a design document out **one feature at a time**. Six agents - an
orchestrator, an adversarial reviewer, a per-feature lead, and three workers -
coordinate by shelling out to a `pipeline` CLI that wraps tmux. Every
inter-agent message ends in a machine-parseable `[SIGNAL:...]` tag.

Unlike a subagent pattern where work disappears into a black-box loop, every
agent runs in its own pane. You can watch all of it, jump in at any point with
`pipeline tell`, and read a complete audit trail afterwards.

## Why serial

Exactly one feature team is alive at a time, and it is killed when its feature
merges.

- **Serializing features eliminates git conflicts and interface races.** Two
  teams editing one tree concurrently was the single largest source of lost work
  in the system this replaces.
- **Killing teams eliminates context bleed.** A fresh lead cannot carry stale
  assumptions from the previous feature.

Features may run in parallel only in an explicitly *proven* independent pair,
each in its own git worktree. When in doubt, the orchestrator does not group.

## The agents

| Agent | Model | Role |
|---|---|---|
| `orch` | opus | Snapshots the request, decomposes the design, spawns one lead at a time, gates with principal, squash-merges to the base branch, opens the final PR |
| `principal` | opus | Adversarial gate reviewer. Reviews the decomposition, each plan and tier, spot-checks completed work by reading the diff line by line, reviews contract changes, and does a final whole-system review against the original request. Idle between gates |
| `lead` | opus | Per-feature team lead. Writes the plan, picks the tier, drives the playbook, spawns and kills workers |
| `tdd-tester` | opus | Writes failing tests from the requirements |
| `tdd-reviewer` | sonnet | Audits the tests, then reviews the implementation |
| `tdd-impl` | sonnet | Makes failing tests pass. Never modifies tests or contracts |

You are a gated decision-maker, not a driver: kickoff, decomposition approval,
per-feature plan approval, and deadlock arbitration. Everything else is
autonomous.

## Workflow tiers

The lead picks one per feature and records it in `plan.md` with a justification.
Principal reviews the choice for honesty; you can override it at the approval
gate.

| Tier | Typical work | Workers |
|---|---|---|
| `direct` | doc / config / rename / one-liner | none |
| `lite` | bug fix, small change | impl + reviewer |
| `full-tdd` | real feature with logic | tester + reviewer + impl |

---

## Prerequisites

| Tool | Why | macOS |
|---|---|---|
| tmux >= 3.2 | the pane fabric; `-e` env injection needs 3.2 | `brew install tmux` |
| `claude` | the agents | [claude.com/claude-code](https://claude.com/claude-code) |
| `jq` | registry and state files | `brew install jq` |
| `gh` | opens the final PR in normal mode | `brew install gh` |

`gh` is optional if you only run test mode.

## Install

```bash
git clone <this repo> && cd agent-orch-pipeline
./install.sh
```

This checks the prerequisites, builds the role prompts, renders the per-role
settings, symlinks `pipeline` into `~/.local/bin`, and symlinks the
`pipeline-awareness` skill into `~/.claude/skills`.

If `~/.local/bin` is not on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Seed a workspace

```bash
cd ~/code/my-project
git checkout -b feature/my-thing        # NOT main - see below
mkdir -p docs/specs
$EDITOR docs/specs/my-design.md
```

Two rules:

- **Check out a working branch first.** Whatever branch you are on at kickoff
  becomes the integration branch. If it is `main` or `master`, orch stops and
  asks you to switch - it will not pick a branch name for you.
- **Never stage your design under `docs/features/`.** That whole tree is
  orch-owned. Put designs in `docs/specs/`.

Optional: `docs/steering/code-conventions.md` is read by every agent and is
**binding** where it conflicts with `CLAUDE.md` or `AGENTS.md`.

## Run a session

```bash
pipeline start --session mything --agents "orch,principal"
pipeline attach --session mything          # optional: watch it
```

### Normal mode - ends with a PR

```bash
pipeline tell orch "Build docs/specs/my-design.md. [SIGNAL:KICKOFF]"
```

### Test mode - no PR, never touches main

```bash
pipeline tell orch "Build docs/specs/my-design.md. Use test mode. [SIGNAL:KICKOFF]"
```

The mode is written into `session.md` at kickoff and read from there on every
restart, so a resumed session cannot silently revert to normal.

---

## Driving a session

Your one file for "where is everything":

```bash
cat docs/features/current/status.md
```

Everything else:

```bash
pipeline status                    # who is alive, and whether they are wedged
pipeline logs --follow             # live message audit trail
pipeline report                    # timeline, protocol violations, delivery problems
pipeline tell orch "status"        # ask orch directly
```

### Pane colours

| Colour | Meaning |
|---|---|
| blue | working |
| yellow | waiting on **you** (you also get a macOS notification) |
| green | idle / done |

### Answering a gate

```bash
pipeline tell orch "Decomposition looks right, go ahead. [SIGNAL:DEV_APPROVE_DECOMPOSITION]"
pipeline tell orch "Approved. [SIGNAL:DEV_APPROVE_PLAN feature=F002-parser]"
```

### Overriding a tier

```bash
pipeline tell orch "F002 is not lite - the merge logic needs real tests. Use full-tdd. [SIGNAL:DEV_APPROVE_PLAN feature=F002-parser]"
```

### Resuming after a dead pane

Agents are stateless relative to artifacts, so nothing is lost:

```bash
pipeline spawn lead:opus:lead-F002-parser
pipeline tell lead-F002-parser "Respawned. Read docs/features/current/F002-parser/status.md and resume from the recorded phase; do not redo completed work. [SIGNAL:FEATURE_RESUME feature=F002-parser]"
```

### Stopping

```bash
pipeline tell orch "Stop here, leave everything on disk. [SIGNAL:HOLD]"
pipeline kill orch && pipeline kill principal
```

---

## Worked example

A two-feature design (one `direct`, one `lite`) in test mode:

```
you        -> orch        Build docs/specs/toy-design.md. Use test mode. [SIGNAL:KICKOFF]
orch                      captures base=work/toy, freezes request.md, decomposes into
                          F001-config-file and F002-off-by-one
orch       -> principal   [SIGNAL:DECOMPOSITION_READY]                        GATE 1a
principal  -> orch        [SIGNAL:APPROVED]                                   (bare = decomposition)
orch       -> you         asks for approval
you        -> orch        [SIGNAL:DEV_APPROVE_DECOMPOSITION]

orch                      branch feature/F001-config-file, spawns lead-F001-config-file
orch       -> lead        [SIGNAL:FEATURE_START feature=F001-config-file]
lead       -> orch        [SIGNAL:PLAN_READY feature=F001-config-file]        tier: direct
orch       -> principal   [SIGNAL:PLAN_REVIEW_READY feature=F001-config-file] GATE 1b
principal  -> orch        [SIGNAL:APPROVED feature=F001-config-file]
you        -> orch        [SIGNAL:DEV_APPROVE_PLAN feature=F001-config-file]
orch       -> lead        [SIGNAL:PLAN_APPROVED feature=F001-config-file]
lead                      does the work itself (direct tier: no workers)
lead       -> orch        [SIGNAL:FEATURE_COMPLETE feature=F001-config-file]
orch       -> principal   [SIGNAL:WORK_REVIEW_READY feature=F001-config-file] GATE 2
principal                 writes work-review.md with the evidence header
principal  -> orch        [SIGNAL:WORK_APPROVED feature=F001-config-file]
orch                      validates the header, squash-merges the reviewed SHA onto work/toy
orch       -> lead        [SIGNAL:KILL_WORKERS feature=F001-config-file]

...                       F002-off-by-one repeats, at tier lite with impl + reviewer

orch       -> principal   [SIGNAL:FINAL_REVIEW_READY]                         FINAL GATE
principal  -> orch        [SIGNAL:FINAL_APPROVED]
orch       -> you         test mode: no PR; work is on work/toy, here is the follow-up
```

`test/smoke.sh` runs exactly this, end to end, against a throwaway repo.

---

## Troubleshooting

### A signal was sent but nothing happened

Signals are tool actions. An agent writing "I'll tell the lead
[SIGNAL:REVIEW_PASS]" in its reply has sent **nothing**. The confirmation line
`Message sent to <alias> (msg=N)` is the proof - `pipeline tell` prints it only
after verifying the text actually landed in the target pane.

If a verdict never arrived but the sender looks done, the artifact is the
fallback: `work-review.md`, `review.md`, and `plan-review.md` all carry their
verdict on disk *before* the signal goes out. Read it, then tell orch what it
says.

```bash
pipeline logs | tail -20
pipeline report                # dropped signals, dead letters, violations
```

### A pane is blocked on a permission dialog

`pipeline tell` refuses to type into a pane showing a dialog - the keystrokes
would be consumed answering it, and the message would vanish. You will see:

```
pipeline: pane for lead-F002 is showing a dialog; message NOT sent (dead-lettered).
```

Attach, clear the prompt, and resend. If it keeps happening, a command is
missing from that role's allowlist in `settings/templates/role-<role>.json.in` -
add it and re-run `./build-prompts.sh`.

### A pane is alive but the agent is dead

`pipeline status` reports both, because they are different things:

```
ALIAS      ROLE   MODEL  EFFORT  PANE  PANE-STATE  AGENT-STATE
orch       orch   opus   -       %0    alive       WEDGED
```

`WEDGED` means the pane is up but no Claude session is registered under that
alias. Kill and respawn it; the artifacts carry the state.

### Commits are landing in the wrong tree

A symptom of a missing worktree prefix in a parallel group: commits appear on
the shared checkout and the feature branch looks empty. Panes start in the
shared checkout, so agents must prefix every code command with
`cd <worktree> && ...`. Coordination files always stay at the shared checkout's
`docs/features/current/`.

### Messages were dead-lettered

```bash
cat /tmp/pipeline-<session>/dead-letter.log
```

Unknown alias, dead pane, blocked pane, or text that never landed. Fix the cause
and resend - nothing is silently dropped.

### A merge was refused

```
EVIDENCE_INVALID F002-parser reason=stale-sha
```

Principal approved a commit that is no longer the branch tip - the branch moved
after the review, so the approval covers work that is not what would be merged.
Orch re-requests the gate. This does **not** consume a spot-check cycle.

---

## How it is built

```
pipeline                    the CLI (bash, tmux + jq only)
context/                    prompt sources, single-sourced across roles
  workflow.md               shared by all six roles
  workflow-coordination.md  orch, principal, lead ONLY
  playbook-{direct,lite,tdd}.md
  identity/<role>.md        identity + INVARIANTS
  <role>-role.md            phase-by-phase protocol
prompts/                    assembled by build-prompts.sh (committed)
settings/templates/         per-role permissions + hooks (rendered at install)
hooks/                      pane colours, developer notifications
skills/pipeline-awareness/  lets any Claude session join a running session
test/                       harness test, prompt lint, end-to-end smoke test
```

Edit files in `context/`, never in `prompts/` - then:

```bash
./build-prompts.sh
```

### Invariants are enforced, not just requested

Each role's prompt states its invariants, and its settings file enforces the
ones that can be: principal and the reviewer are denied `Edit` outright; impl is
denied writes to test paths and contracts; the tester is denied writes to
implementation code; only orch may push or run `gh`. `test/prompt-lint.sh` fails
if a prompt's stated invariant and its mechanical deny ever drift apart.

### Tests

```bash
bash test/pipeline-cli.test.sh   # CLI against real tmux panes
bash test/prompt-lint.sh         # protocol text conformance, no LLM needed
bash test/smoke.sh               # full two-feature TEST MODE session
```

`smoke.sh` runs a complete session with deterministic stub agents in real tmux
panes, driven over the real `send-keys` path, and injects the failure modes the
design exists to prevent: a dropped verdict recovered from its artifact, a stale
evidence SHA refused, an unauthenticated signal ignored, a replayed message
deduplicated, an illegal state transition rejected, a message refused into a
modal pane, and a crash between merge and state write resumed without
double-merging.

It proves the protocol and the CLI. It does not prove an LLM follows the
prompts - that is what a live run on your own machine is for.

### Also worth knowing

- **Per-role MCP and effort.** Edit `role_default_effort` / `role_default_mcp`
  at the top of `pipeline`, or pass `--effort` / `--mcp-config` to
  `pipeline spawn`. Principal defaults to `xhigh`.
- **`pipeline watch`** flags a stalled session and notifies you, so a blocking
  gate cannot wait silently forever.
- **`SendMessage`/`ListAgents`.** Claude Code has native cross-session
  messaging. This system deliberately does not use it: `pipeline tell` must be a
  shell command *you* can also run, must emit a delivery confirmation, and must
  write an audit log. To check whether native messaging can reach across your
  local sessions, run `ListAgents` from a second Claude session while a pipeline
  session is up.
