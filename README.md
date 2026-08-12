# Agent Orchestrator Pipeline

A serial multi-agent development workflow for [Claude Code](https://claude.com/claude-code),
running locally on macOS as tmux panes.

It builds a design document out **one feature at a time**. Six agents - a
`conductor`, an adversarial `arbiter`, a per-feature `foreman`, and a three-agent
crew of `prover`, `inspector`, and `builder` - coordinate by shelling out to a
`pipeline` CLI that wraps tmux. Every inter-agent message ends in a
machine-parseable `[SIGNAL:...]` tag.

Unlike a subagent pattern where work disappears into a black-box loop, every
agent runs in its own pane. You can watch all of it, jump in at any point with
`pipeline tell`, and read a complete audit trail afterwards.

> **There are two systems in this repository.** `pipeline` is v1, described
> below, and it still runs. **[`orch` is v2](#orch-v2)**, and it is where the
> work is going: same protocol, none of the transport. New work should start
> there. See [Migration](#migration) for how they coexist and what has to be
> true before v1 is archived.

---

# orch v2

v1's thesis was right and its transport was a liability. Serial writes,
fresh-context reviewers, artifact-driven state, separated test authorship — all
of that survives unchanged. What does not survive is 1,252 lines of bash typing
keystrokes into tmux panes, with no locking, a message-id race that silently
discarded real messages, and a verification path that dead-lettered messages it
had actually delivered.

Claude Code now ships the coordination layer. v2 deletes the transport and
keeps the protocol, and spends the freed budget on the part nobody does:
**measuring whether orchestrating helped at all.**

That question is not rhetorical. The published record says orchestration
usually loses. Single-agent matched or beat multi-agent at *every* thinking-token
budget tested across five topologies and four models, overtaking only at ~70%
deliberate context corruption [P20]. Agents can be *"100x more expensive while
only being 1% better"* [P22]. No architecture consistently wins [P21]. Four of
eight notable 2025 orchestration tools are dead [P14].

So `orch` starts every feature with one agent and no orchestration, and
escalates only when a mechanical signal says the solo context has degraded —
the exact condition under which the evidence says multi-agent starts winning.

## Quick start

```bash
export CLAUDE_CODE_TASK_LIST_ID=orch-$(basename "$PWD")   # every session, same value
export PATH="$PWD/orch/bin:$PATH"
orch doctor                        # check the operational constraints first

orch feature start F001-parser     # rung 0: one agent, gates still apply
orch run --feature F001-parser --label tests -- npm test
orch approve F001-parser --gate human
```

`orch init` prints the environment every session in a team must share, and why.

## The four mechanisms

**1 · Adaptive escalation.** Every feature starts at rung 0. `orch escalate
check` reads six mechanical signals — compaction, context pressure above 70%,
step repetition, tool failure rate, test oscillation, edit churn — and moves up
the ladder only if they fire. None of them costs a model call: a detector that
needs LLM budget to decide whether to spend LLM budget has already lost the
argument.

| rung | configuration | entry |
|---|---|---|
| 0 · solo | one session, attested gates | default |
| 1 · solo + review | reviewer ensemble on the diff | one signal, or a diff over 3 files |
| 2 · split | test author separate from implementer | a blocking finding, or two signals |
| 3 · best-of-N | N builders in worktrees, mechanical selection | a failed repair cycle, or oscillation |
| 4 · diagnose | K competing hypotheses, execution selects | a second failure on the same finding |
| 5 · human | escalate with the ledger slice | no distinguishing experiment exists |

Rung 5's trigger is the one worth arguing about: you escalate to a human when
**no falsifiable experiment can be constructed**, not when a try counter runs
out. That is the correct stopping condition, and a better use of the human.

**2 · Best-of-N with attested selection** (rung 3). N candidates, each in its
own worktree, each seeded with a genuinely different approach — minimal diff,
root cause, defensive — because diversity, not verification, was the binding
constraint in the one result with a large coding-specific gain [P18]. Selection
is mechanical and runs *before* any model judgement: candidates failing a gate
are discarded, survivors ranked by attested numbers. Exactly one merges; all N
are archived with their gate results, which is what later lets you ask whether
N=3 beat N=1.

**3 · Heterogeneous reviewer ensemble** (rung 1+). Two or three reviewers, each
a distinct (model, lens) pair, each with fresh context and only the diff.
Individual review tools caught 20–32% of defects; the union of four different
ones reached 41.5% [P8]. Conflicts are never voted on — they go to the arbiter,
who settles them by running something.

**4 · Anti-anchoring diagnosis** (rung 4). K read-only agents, each handed a
different starting hypothesis, each required to return a falsifiable prediction
*and the command that tests it*. `orch run` executes all K. One holds → it
directs the repair. None or two hold → escalate to a human. The parallelism
generates hypotheses; execution, never consensus, selects among them.

## What is actually enforced

Nothing in `orch` relies on a prompt asking nicely.

| Boundary | Mechanism |
|---|---|
| no merge without approval for the current sha | `hooks/gate-guard.sh`, exit 2 |
| no stage completes on an unattested claim | `hooks/task-guard.sh`, exit 2 |
| the conductor cannot write source | `hooks/write-scope.sh`, exit 2 |
| the builder cannot edit the tests it must satisfy | `hooks/write-scope.sh`, exit 2 |
| reviewers cannot act, only report | `disallowedTools` in the agent definition |
| candidates cannot escape their worktree | `isolation: worktree`, platform-enforced |
| every evidence claim is a real exit code | `orch run` is the only writer of `evidence.jsonl` |

`orch/test/agent-lint.sh` fails the build if any invariant sentence in a role
definition does not name a mechanism that exists and is wired. v1 checked some
of this and missed the arbiter's drift entirely — which is the failure mode: a
prompt that promises a boundary nothing enforces reads exactly like one that is
enforced, right up until it matters.

## Attested execution

```bash
orch run --feature F002-parser --label tests -- npm test
```

Runs it, streams output unchanged, and records
`{ts, agent, label, cmd, exit_code, duration_s, stdout_sha256, stdout_tail, git_sha, worktree}`.

An approval citing a command with no entry is rejected `EVIDENCE_UNATTESTED`.
One citing a non-zero exit while claiming success is rejected
`EVIDENCE_CONTRADICTED`. Neither consumes a repair cycle — rejecting a false
claim is not the same event as failing an honest attempt.

This replaces v1's self-reported evidence header, which was the best mechanism
v1 had and was still an agent's claim about its own diligence.

## The ledger, and the ablation

v1 had no instrumentation. Its token accounting was agents typing `~13k (est.)`
at each other, and `cost-report.md` was LLM-authored guesswork. That convention
is deleted.

`orch report` reads `ledger.jsonl` and the session transcripts and prints, per
feature and per rung: cost, wall clock, `critique_uptake_rate` against the
33.6% baseline [P11], per-reviewer unique-find rate, gate yield,
`escalation_precision`, and best-of-N selection margins. Where it has no data
it says so rather than printing a zero.

`orch baseline <feature>` runs a single-agent attempt at the same
`requirements.md` in a throwaway worktree, taking `total_cost_usd` straight
from `claude -p --output-format json`. It merges nothing. Running it on *every*
feature regardless of rung is what makes `escalation_precision` computable:
of the features that escalated, what fraction would the solo path have gotten
wrong?

**Nobody has published that number.** `orch report --ablation` produces it.
The table goes in this README whether or not it flatters the design — *"rung 4
never once produced a distinguishing experiment"* is a result, and it tells you
to delete rung 4.

## Layout

```
orch/
  bin/orch                  the CLI: human entry point + attested execution
  lib/
    substrate/base.sh       the seam: roster/post/claim/release/gate/probe
    substrate/messaging.sh  shared task list + SendMessage        (default)
    substrate/teams.sh      agent-teams adapter                   (stub)
    common.sh ledger.sh evidence.sh health.sh escalate.sh
    findings.sh candidates.sh diagnose.sh report.sh doctor.sh
  agents/                   six role definitions, ~3.3k tokens total
  hooks/                    gate-guard, task-guard, write-scope, audit-message,
                            health-probe
  settings.json             hook wiring    settings/  per-role permissions
  test/                     run-all.sh — 320 assertions, no session required
```

State lives in exactly three places: **the shared task list** (coordination,
first-party file locking), **`SendMessage`** (notification, ephemeral by
design), and **`docs/features/**`** (artifacts, unchanged from v1).

**A message is never load-bearing.** Every state transition is a task-list
mutation plus an artifact write; messages only notify. That discipline is what
makes an ephemeral, lossy transport safe — and it is precisely what v1's
dead-letter machinery existed to compensate for.

Nothing above `lib/substrate/` calls `claude agents`, invokes `SendMessage`, or
touches `~/.claude/tasks`. `orch/test/substrate.test.sh` fails the build if
anything reaches around the seam.

## Where the spec and the CLI disagree

Verified against `claude 2.1.228` rather than taken from documentation, per the
specification's own standing instruction. Two things it asserts are not true of
the installed CLI:

1. **The declarative hook `if` field does not exist.** §6.2 calls for
   `"if": "Bash(git merge*)"` to pre-filter without spawning a process. The
   settings validator says hooks map event names to matcher arrays carrying
   string matchers, and there is no if-condition in the binary. `orch` narrows
   by `matcher` and matches the command inside the hook. Same correctness, one
   short-lived process per Bash call.

2. **The roster does not report permission mode.** §1 requires every session in
   a team to share a permission-mode class — mismatched classes cause messages
   to be held and then dropped after `dialogExpiry`, which is silence, not an
   error. But `claude agents --json` returns only pid/cwd/kind/startedAt/
   sessionId/name, and the session registry does not carry the mode either.
   `orch doctor` recovers the class from the process arguments and reports
   `unknown` rather than guessing when it cannot.

Two further deviations are ours, not the CLI's:

3. **Selection ranks gates passed, not individual tests passed.** §7 ranks by
   "tests passed desc". No portable per-test count exists across the toolchains
   `orch` has to run under, and inventing one would violate invariant 7. If you
   can produce a count, attest it as `orch run --label tests-passed-count` and
   selection uses it; otherwise it falls back to gates passed, then diff size.

4. **Role write-scoping is a hook, not a permission rule.** §5 calls for the
   conductor to be denied `Edit`/`Write` outside `docs/features/**`. In Claude
   Code deny beats allow, so "deny everything, allow one prefix" denies
   everything. A denylist of the rest is fragile in the wrong direction — the
   path you forgot is the one that gets written. `hooks/write-scope.sh` states
   the rule positively, and hooks outrank permission rules anyway [P1][P5].

`docs/PROVENANCE.md` records all of this, and is candid about which of its own
entries are first-hand and which are not.

## Tests

```bash
bash orch/test/run-all.sh
```

320 assertions across eight suites. No Claude session, no API key, no network,
no tmux. Each suite builds a throwaway git repo and its own task-list root, so
nothing touches `~/.claude` and nothing is left behind.

The suite asserts the properties the design exists to provide, including the
failure modes: a merge blocked without approval and unblocked with it; the same
approval voided once the branch tip moves; a claim citing a command that never
ran, rejected; a held-then-expired message logged as expired rather than as
delivered; six concurrent writers allocating task ids with no lost write; a
candidate's commit not moving the main checkout; two simultaneously-held
diagnostic predictions escalating instead of getting a tiebreak.

## Migration

Both systems run during the transition. Shared and unchanged: the
`docs/features/**` artifact contract, `docs/PROVENANCE.md`, and the git strategy
— branch per feature, squash-merge the reviewed sha, revert rather than rewrite.

Cut over when `orch` has run 20+ features and `orch report` shows it at parity
or better on outcome per dollar. Then archive `pipeline` here with a note on
what it taught. Until then v1 stays runnable, and its live bugs — the `lite`-tier
permission contradiction, the fail-open `--settings` path, the `msg-seq` race,
and the swallowed merge status — are still worth fixing.

And the discipline that makes this worth showing at all: **if a rung, a lens, or
a gate shows no unique yield after 20 features, delete it and say so here.** The
published record is full of orchestration tools that never measured whether they
helped. Four of them are already dead [P14].

## Provenance and licence

Every `[Pn]` tag above resolves in **[`docs/PROVENANCE.md`](docs/PROVENANCE.md)**,
which is explicit about which of its entries are first-hand and which are not.
[P35] — the Claude Code substrate this whole system stands on — was verified
empirically against `claude 2.1.228`, and the file lists the commands to re-run.
Most of the rest is currently marked `CITATION MISSING`: the specification these
mechanisms were built from names a companion provenance document that is not in
this repository, and recording a figure without its source is the most this file
can honestly do until that is restored. Read the status note at the top before
citing anything from it.

Licensed under [Apache-2.0](LICENSE).

---

# pipeline (v1)

## Why serial

Exactly one feature team is alive at a time, and it is killed when its feature
merges.

- **Serializing features eliminates git conflicts and interface races.** Two
  teams editing one tree concurrently is the single largest source of lost work
  in a multi-agent run.
- **Killing teams eliminates context bleed.** A fresh foreman cannot carry stale
  assumptions from the previous feature.

Features may run in parallel only in an explicitly *proven* independent pair,
each in its own git worktree. When in doubt, the orchestrator does not group.

## The agents

| Agent | Model | Role |
|---|---|---|
| `conductor` | opus | Snapshots the request, decomposes the design, spawns one foreman at a time, gates with arbiter, squash-merges to the base branch, opens the final PR |
| `arbiter` | opus | Adversarial gate reviewer at every stage. Reviews the decomposition, each plan and tier, spot-checks completed work by reading the diff line by line, reviews contract changes, and does a final whole-system review against the original request. Idle between gates |
| `foreman` | opus | Runs one feature's team. Writes the plan, picks the tier, drives the playbook, spawns and kills workers |
| `prover` | opus | Writes failing tests from the requirements |
| `inspector` | sonnet | Audits the tests, then reviews the implementation |
| `builder` | sonnet | Makes failing tests pass. Never modifies tests or contracts |

You are a gated decision-maker, not a driver: kickoff, decomposition approval,
per-feature plan approval, and deadlock arbitration. Everything else is
autonomous.

## Workflow tiers

The foreman picks one per feature and records it in `plan.md` with a justification.
Arbiter reviews the choice for honesty; you can override it at the approval
gate.

| Tier | Typical work | Workers |
|---|---|---|
| `direct` | doc / config / rename / one-liner | none |
| `lite` | bug fix, small change | builder + inspector |
| `full-tdd` | real feature with logic | prover + inspector + builder |

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
  becomes the integration branch. If it is `main` or `master`, conductor stops and
  asks you to switch - it will not pick a branch name for you.
- **Never stage your design under `docs/features/`.** That whole tree is
  conductor-owned. Put designs in `docs/specs/`.

Optional: `docs/steering/code-conventions.md` is read by every agent and is
**binding** where it conflicts with `CLAUDE.md` or `AGENTS.md`.

## Run a session

```bash
pipeline start --session mything --agents "conductor,arbiter"
pipeline attach --session mything          # optional: watch it
```

### Normal mode - ends with a PR

```bash
pipeline tell conductor "Build docs/specs/my-design.md. [SIGNAL:KICKOFF]"
```

### Test mode - no PR, never touches main

```bash
pipeline tell conductor "Build docs/specs/my-design.md. [SIGNAL:KICKOFF mode=test]"
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
pipeline peek conductor            # read an agent's screen as plain text
pipeline doctor                    # diagnose the install: claude path, flags, role files
pipeline tell conductor "status"   # ask the conductor directly
```

### Pane state

Each pane's **border** is labelled with the agent's alias and its state, and
tinted to match:

| Border | Meaning |
|---|---|
| blue | working |
| amber | waiting on **you** (you also get a notification) |
| green | idle / done |

State is deliberately shown *around* the pane, not behind it: Claude Code picks
its foreground colours assuming a dark background, so filling the pane with a
colour destroys the contrast it was designed for.

`PIPELINE_PANE_STYLE` chooses: `border` (default), `bg` (fill the pane
background instead), or `none`. Under cmux, `none` is reasonable — its own tab
ring already tells you when an agent wants you.

### Scrolling and clicking

`pipeline start` sets `mouse on` and a 50,000-line scrollback **on its own
session only**, never on your global tmux config. So in the attached session the
scroll wheel and click-to-focus work, and there is real history to scroll back
through (tmux's default is 2,000 lines).

The one habit that changes: while tmux owns the mouse, **hold Option to select
text natively** on macOS. To turn it off for a long copy/paste:

```bash
pipeline mouse off      # and `pipeline mouse on` to put it back
```

`PIPELINE_MOUSE=off` starts sessions that way. Ordinary cmux panes — where you
run `pipeline tell`, `status`, `logs` — are unaffected; native scroll and click
already work there.

### Running under cmux

[cmux](https://github.com/manaflow-ai/cmux) is a terminal, not a multiplexer,
so it composes with this rather than competing: launch from a cmux pane and the
pipeline's tmux session is created detached, independent of the window you
started it in.

- **Notifications reach the sidebar.** When a gate needs you, the notify hook
  emits an OSC 9 sequence, so the pane rings and its tab lights up. Agents run
  inside tmux panes and tmux drops unrecognised OSC, so `pipeline start` sets
  `allow-passthrough on` for its session and the hook wraps the sequence for
  tmux. If the `cmux` CLI is on `PATH`, the hook calls `cmux notify` as well.
- **Watching.** `pipeline attach` opens tmux inside a cmux pane. That works, but
  two prefix keys stack - give one cmux tab to the attach and drive from
  another. Or skip attaching entirely: `pipeline status`, `logs --follow`,
  `report`, and `status.md` cover everything, since all agent state is on disk.
- **Don't point `cmux claude-teams` at the same checkout.** Both it and the
  conductor expect to own agent lifecycle and git state.
- cmux's sidebar shows the branch per pane, which pairs well with the serial
  model: the branch you see is the feature currently being built.

### Driving it from a phone or tablet

The tmux session is detached and persistent, so it survives closing the Mac's
terminal and is there whenever you reconnect — SSH in from an iOS terminal and
everything below works unchanged.

**Prefer reading over attaching.** All agent state is on disk, so the
friction-free loop needs no tmux UI, no mouse, and no wide screen:

```bash
cat docs/features/current/status.md   # where is everything
pipeline status                        # who is alive
pipeline peek conductor                # read an agent's screen as plain text
pipeline peek builder-F002 --lines 80
pipeline logs --follow
```

Answering a gate is a single command:

```bash
pipeline tell conductor "Approved. [SIGNAL:DEV_APPROVE_PLAN feature=F002-parser]"
```

If you do attach, six tiled panes are unreadable on a phone — use `prefix + z`
to zoom one pane full-screen. `mouse on` (the default) is what makes two-finger
scroll reach tmux's history; without it, scrolling does nothing, because tmux is
on the alternate screen and the terminal app's own scrollback is empty.

### Answering a gate

```bash
pipeline tell conductor "Decomposition looks right, go ahead. [SIGNAL:DEV_APPROVE_DECOMPOSITION]"
pipeline tell conductor "Approved. [SIGNAL:DEV_APPROVE_PLAN feature=F002-parser]"
```

### Overriding a tier

```bash
pipeline tell conductor "F002 is not lite - the merge logic needs real tests. [SIGNAL:DEV_APPROVE_PLAN feature=F002-parser tier=full-tdd]"
```

### Resuming after a dead pane

Agents are stateless relative to artifacts, so nothing is lost:

```bash
pipeline spawn foreman:opus:foreman-F002-parser
pipeline tell foreman-F002-parser "Respawned. Read docs/features/current/F002-parser/status.md and resume from the recorded phase; do not redo completed work. [SIGNAL:FEATURE_RESUME feature=F002-parser]"
```

### Stopping

```bash
pipeline tell conductor "Stop here, leave everything on disk. [SIGNAL:HOLD]"
pipeline kill conductor && pipeline kill arbiter
```

---

## Worked example

A two-feature design (one `direct`, one `lite`) in test mode:

```
you        -> conductor   Build docs/specs/toy-design.md. [SIGNAL:KICKOFF mode=test]
conductor                 captures base=work/toy, freezes request.md, decomposes
                          into F001-config-file and F002-off-by-one
conductor  -> arbiter     [SIGNAL:DECOMPOSITION_READY]                    GATE 1a
arbiter    -> conductor   [SIGNAL:APPROVED]                     (bare = decomposition)
conductor  -> you         asks for approval
you        -> conductor   [SIGNAL:DEV_APPROVE_DECOMPOSITION]

conductor                 branches feature/F001-config-file, spawns the foreman
conductor  -> foreman     [SIGNAL:FEATURE_START feature=F001-config-file]
foreman    -> conductor   [SIGNAL:PLAN_READY feature=F001-config-file]  tier: direct
conductor  -> arbiter     [SIGNAL:PLAN_REVIEW_READY feature=F001-config-file]  GATE 1b
arbiter    -> conductor   [SIGNAL:APPROVED feature=F001-config-file]
you        -> conductor   [SIGNAL:DEV_APPROVE_PLAN feature=F001-config-file]
conductor  -> foreman     [SIGNAL:PLAN_APPROVED feature=F001-config-file]
foreman                   does the work itself - the direct tier spawns no crew
foreman    -> conductor   [SIGNAL:FEATURE_COMPLETE feature=F001-config-file]
conductor  -> arbiter     [SIGNAL:WORK_REVIEW_READY feature=F001-config-file]  GATE 2
arbiter                   writes work-review.md with the evidence header
arbiter    -> conductor   [SIGNAL:WORK_APPROVED feature=F001-config-file]
conductor                 validates the header, squash-merges the reviewed SHA
conductor  -> foreman     [SIGNAL:KILL_WORKERS feature=F001-config-file]

...                       F002-off-by-one repeats at tier lite, where the foreman
                          spawns builder + inspector as builder-F002-off-by-one
                          and inspector-F002-off-by-one

conductor  -> arbiter     [SIGNAL:FINAL_REVIEW_READY]                  FINAL GATE
arbiter    -> conductor   [SIGNAL:FINAL_APPROVED]
conductor  -> you         test mode: no PR; work is on work/toy, here is the
                          manual follow-up
```

`test/smoke.sh` runs exactly this, end to end, against a throwaway repo.

---

## Troubleshooting

### A signal was sent but nothing happened

Signals are tool actions. An agent writing "I'll tell the foreman
[SIGNAL:REVIEW_PASS]" in its reply has sent **nothing**. The confirmation line
`Message sent to <alias> (msg=N)` is the proof - `pipeline tell` prints it only
after verifying the text actually landed in the target pane.

If a verdict never arrived but the sender looks done, the artifact is the
fallback: `work-review.md`, `review.md`, and `plan-review.md` all carry their
verdict on disk *before* the signal goes out. Read it, then tell conductor what it
says.

```bash
pipeline logs | tail -20
pipeline report                # dropped signals, dead letters, violations
```

### `pipeline: command not found` in another terminal

`install.sh` symlinks `pipeline` into `~/.local/bin`, but a *different* terminal
only sees it if that directory is on that shell's `PATH`. Persist it where an
interactive zsh will read it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh
```

`~/.zprofile` is read by login shells only, so a terminal that opens a
non-login shell will miss it — `~/.zshrc` covers both. Check with:

```bash
grep -n 'local/bin' ~/.zshrc ~/.zprofile ~/.zshenv 2>/dev/null
```

Your running session is unaffected: agent panes get the CLI's directory on
their `PATH` explicitly, so agents can always shell out to `pipeline`
regardless of where the session was launched from. `pipeline doctor` reports
both, under "agent panes".

### An agent exits immediately / "no server running"

```
pipeline: conductor exited immediately (status 3) - it never started.
Its pane said:
  error: unknown option '--name'
Run `pipeline doctor` to see the exact command and environment.
```

The agent's `claude` command failed before it started. The pane's own output is
quoted back at you, and the half-created session is cleaned up so you can just
fix it and re-run. `pipeline doctor` prints the resolved `claude` path, which
optional flags your build supports, and the exact command a pane runs — paste
that command into a shell to reproduce it by hand.

If you saw the older, blanker version of this failure:

```
Spawned conductor (conductor, opus)
no server running on /private/tmp/tmux-501/default
```

that was the same thing before the diagnosis existed: the first agent died, its
death took the session and the tmux server with it, and the second spawn then
reported a server that had already gone. Upgrade and re-run.

### A pane is blocked on a permission dialog

`pipeline tell` refuses to type into a pane showing a dialog - the keystrokes
would be consumed answering it, and the message would vanish. You will see:

```
pipeline: pane for foreman-F002 is showing a dialog; message NOT sent (dead-lettered).
```

Attach, clear the prompt, and resend. If it keeps happening, a command is
missing from that role's allowlist in `settings/templates/role-<role>.json.in` -
add it and re-run `./build-prompts.sh`.

### A pane is alive but the agent is dead

`pipeline status` reports both, because they are different things:

```
ALIAS      ROLE   MODEL  EFFORT  PANE  PANE-STATE  AGENT-STATE
conductor       conductor   opus   -       %0    alive       WEDGED
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

Arbiter approved a commit that is no longer the branch tip - the branch moved
after the review, so the approval covers work that is not what would be merged.
The conductor re-requests the gate. This does **not** consume a spot-check cycle.

---

## How it is built

```
pipeline                    the CLI (bash, tmux + jq only)
context/                    prompt sources, single-sourced across roles
  workflow.md               shared by all six roles
  workflow-coordination.md  conductor, arbiter, foreman ONLY
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
ones that can be: arbiter and the inspector are denied `Edit` outright; builder is
denied writes to test paths and contracts; the prover is denied writes to
implementation code; only conductor may push or run `gh`. `test/prompt-lint.sh` fails
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
  `pipeline spawn`. Arbiter defaults to `xhigh`.
- **`pipeline watch`** flags a stalled session and notifies you, so a blocking
  gate cannot wait silently forever.
- **`SendMessage`/`ListAgents`.** v1 deliberately does not use Claude Code's
  native cross-session messaging. The stated reasons were that `pipeline tell`
  must be a shell command *you* can also run, must emit a delivery confirmation,
  and must write an audit log.

  **That reasoning was sound when it was written, and the platform has since
  moved.** All three are now satisfiable, and [v2](#orch-v2) takes them:

  - *A command you can also run.* Native messaging still gives no way for an
    arbitrary terminal to post into a session's socket — correctly, since the
    socket is 0600 and ownership-verified. But mimicking `send-keys` was never
    the requirement; steering the pipeline was. `orch approve <feature> --gate
    <name>` writes to the shared, file-locked task list from any terminal. That
    is strictly better than typing into a pane: it survives a dead session and
    it is greppable afterwards.
  - *Delivery is confirmed.* The `SendMessage` tool result reports held /
    refused / expired outcomes to the sender.
  - *A durable, greppable audit log.* `SendMessage` is a tool, so it is
    hookable. `orch/hooks/audit-message.sh` appends every message **and its
    outcome** to the ledger — which is more than v1's `messages.log` recorded,
    and it is exactly the distinction v1's dead-letter path got wrong.
