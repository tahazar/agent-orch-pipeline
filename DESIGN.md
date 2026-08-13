# Design

Why `orch` is shaped the way it is, and what evidence that shape rests on.

[`README.md`](README.md) is how to use it. This is the argument. Every `[Pn]`
resolves in [`docs/PROVENANCE.md`](docs/PROVENANCE.md), which records whether
each source was actually verified.

---

## The uncomfortable starting point

The published record does not say multi-agent orchestration works.

The strongest result against it, and the one this pipeline's ladder is built on,
is a matched-budget ablation [P20]: hold thinking tokens constant and a single
agent matched or beat multi-agent across five topologies — sequential,
subtask-parallel, parallel-roles, debate, ensemble — at every budget tested.
Multi-agent only overtook once the single agent's context was deliberately
corrupted.

That result is real. It is also **much narrower than it is usually quoted as
being**, and this repository got it wrong for a while:

| what [P20] is | what it is not |
|---|---|
| FRAMES and MuSiQue, text-only multi-hop QA | any coding or software-engineering task |
| Qwen3-30B, DeepSeek-R1-Distill-Llama-70B, Gemini 2.5 | any frontier agentic coding model |
| tools **explicitly out of scope**, per its authors | evidence about tool-using agents |

And there is evidence pointing the other way. Anthropic's own Research system —
a lead agent with 3–5 parallel subagents — outperformed single-agent Claude Opus
4 by **90.2%** on research tasks, at roughly 15× the tokens [P3]. That is not
matched-budget, which is exactly the confound [P20] criticises. But it is a
deployed, measured result on a **tool-using** task where multi-agent won
decisively.

Both can be true, and the reconciliation is not a ranking but a **task-shape
rule**:

> Orchestration pays when work decomposes into independently explorable parallel
> subtasks over a wide search space. It loses on a single dependent reasoning
> chain, where every extra agent is another place for context to be lost or an
> error to be laundered into consensus.

Multi-hop QA is a dependent chain. Research is a wide parallel search. Software
features are sometimes one and sometimes the other, which is the whole reason
this pipeline has a ladder instead of a fixed topology.

### What this means for the constants

**The shape of the control law is borrowed. None of its constants are.**

Every threshold in `lib/health.sh` is ours and unvalidated. The clearest example
is the one that was wrong: `ORCH_T_CONTEXT_PCT=70` was documented as "[P20]'s
literal condition" while measuring how *full* the context window is. [P20]'s
crossover is at α=0.7, meaning **70% of context tokens replaced with misleading
content**. Corruption, not occupancy. A window 70% full of correct information
is not that situation at all.

The threshold stayed at 70 and lost its citation. It is now justified only as a
leading indicator of imminent compaction — and compaction, which is directly
observable, is the signal that actually matters.

---

## Start cheap, escalate on evidence

Every feature starts at the cheapest configuration that could work, and grows
only when something measurable says it should.

```
quick ──▶ standard ──▶ strict ──▶ best-of-N ──▶ diagnose ──▶ human
└──── the developer picks ────┘   └──── signals force ────┘
```

Two entrances to one ladder. Rungs 0–2 are **tiers** a human chooses from the
shape of the work; rungs 3–5 are configurations only the evidence can request.
A chosen tier and a forced rung land in the same place, and `orch report` cannot
tell them apart except by the reason recorded with the event — deliberately, because
the ablation asks whether a configuration paid off, not whose idea it was.

A tier is a **floor, not a ceiling**. Asking for `quick` sets where you start;
it does not buy immunity from the signals.

### The six signals

Compaction, context pressure, step repetition, tool failure rate, test
oscillation, edit churn. Step repetition fires at three occurrences because it
is MAST's single most frequent failure mode at 15.7% [P9].

**None of them costs a model call.** A detector that needs LLM budget to decide
whether to spend LLM budget has already lost the argument. They are all `jq`
over two JSONL files written by hooks.

### Why rung 5 is what it is

You escalate to a human when **no falsifiable experiment can be constructed** —
not when a retry counter runs out. If an experiment exists, run it; a counter
expiring tells you only that time passed. This is also a better use of the human:
you arrive with the ledger slice and the reason the question is undecidable,
rather than with "it failed three times."

---

## Independence is a mechanism, not a request

The ensemble result that justifies running more than one reviewer is narrow and
worth reading carefully. On a code-review benchmark, individual agentic tools
caught **20.1–32.1%** of defects; the union of four different ones reached
**41.5%** [P8].

Two things follow. First, more lenses genuinely find more. Second — the union of
the best available tools still misses most defects, so this is an argument for
diversity, not a claim that the reviewers are good.

The union result **only holds while the lenses are independent**. That makes
independence load-bearing, and load-bearing things are enforced:

- `code-reviewer` is denied `TaskList`, `TaskGet` and `TaskUpdate` outright, and
  `hooks/task-scope.sh` blocks them as a backstop. It sees the diff and its
  criteria. A reviewer that has read the author's reasoning is anchored to it,
  costs the same, and finds less.
- `test-engineer` cannot read the developer's tasks. A test written against the
  implementation passes by construction and checks nothing.

Sharing one task list is what buys file locking and `blocks`/`blockedBy`
auto-unblock. Reading all of it is a different thing, and for these two roles it
is the thing that destroys what they are for.

### Conflicts are settled by running something

When reviewers disagree, the `auditor` does not count votes. It constructs an
experiment and runs it.

The recorded figures for debate's failure modes [P12][P13] could not be verified
and are marked as such. But the direction is independently supported: [P20]
found debate among the topologies that failed to beat a single agent, and the
broader literature on sycophancy in multi-agent debate describes models
discarding correct reasoning to match a peer. Consensus is not evidence.

---

## Delivery, not just detection

Reviewer quality and critique uptake are **separable**, and uptake is the half
that gets ignored. In [P11], the protocol with the strictly better reviewer
(precision 0.861 vs 0.644) produced the *worse* outcome, because its solver
acted on verified-useful critique only **33.6%** of the time against the
other's **93.5%**.

Finding the defect and getting it fixed are different problems.

`lib/findings.sh` inlines finding text **verbatim** into the developer's next
turn for this reason. Relaying a filename through three hops is not delivery.
Two caveats the paper is careful about, and so is the code:

- Embedding guidance in the working context improves follow-through
  **partially**. It does not close the gap. This is the best lever available,
  not a solution.
- **Forcing explicit acknowledgment lowered accuracy.** Nothing in orch makes
  an agent restate a finding back at anyone.

Uptake is measured, crudely and on purpose: it measures engagement, not
correctness. Correctness is the re-review's job.

---

## Best-of-N: parallel without coordination

Rung 3 runs N developers on the same requirements in isolated worktrees. Note
what the pattern is — **no coordination, no handoffs, no shared state.** It
fails cleanly, which is most of why it works, and it is the shape the task-shape
rule predicts should win.

Two rules keep it honest:

1. Every candidate lives in its own worktree and exactly one merges.
2. **Selection is mechanical and happens before any model judgement.**
   Candidates failing a gate are discarded; survivors are ranked on attested
   numbers.

The second is the one people skip. A model asked to pick a winner will find a
reason to prefer the candidate whose reasoning it can follow. A ranking over
exit codes and diff sizes cannot.

All N are archived with their gate results, which is what later lets you ask
whether N=3 beat N=1.

The exact SWE-bench figures once cited here [P18] could not be traced to a
source and should not be quoted. The design rationale survives independently:
published work consistently finds Best@K improves substantially with rollouts
before plateauing, and identifies **sampling diversity** rather than
verification as the binding constraint. That is why `lib/candidates.sh` seeds
three genuinely different approach directives — minimal-diff, root-cause,
defensive — rather than three temperatures.

---

## Nothing rests on a prompt

Claude Code's own gate-strength ranking puts a hook returning exit 2 above an
in-prompt instruction [P1][P5]. It is easy to wire a full set of hooks that only
ever exit 0 — setting colours, ringing bells — and believe a boundary is
enforced. A hook that cannot say no is decoration.

Every invariant in a role definition ends with `[enforced-by: X]`, and
`test/agent-lint.sh` fails the build if X is not a mechanism that exists, is
wired, and has a branch for that role.

That lint has a known gap, documented in the file rather than papered over: it
does not check that a hook governs the right *kind* of operation. It cost this
repository a `code-reviewer` invariant claiming `hooks/write-scope.sh` kept it
from reading the developer's trace — which is not something a `PreToolUse` hook
on `Edit|Write` ever gets the chance to do.

### Evidence is execution

`orch run` is the only writer of `evidence.jsonl`. An approval citing a command
with no entry is rejected `EVIDENCE_UNATTESTED`; one citing a non-zero exit
while claiming success is rejected `EVIDENCE_CONTRADICTED`.

Neither consumes a repair cycle. Rejecting a false claim and failing an honest
attempt are different events, and conflating them punishes the wrong thing.

---

## Two seams

Both exist because the thing behind them moves.

**`lib/substrate/`** — coordination. Agent teams are experimental, the messaging
socket is an internal, the task-list layout is undocumented. When one changes,
one directory changes. `test/substrate.test.sh` fails the build if anything
above it calls `claude agents`, touches `~/.claude/tasks`, or reads the
messaging socket.

**`lib/launcher/`** — session lifecycle. How you start a session is a property
of the terminal you live in, not of the pipeline: cmux, a bare shell and a CI
runner want different answers.

### A message is never load-bearing

Every state transition is a task-list mutation plus an artifact write.
`SendMessage` only notifies.

That discipline is what makes an ephemeral, lossy transport safe to build on. It
is also what removes the need for dead-letter machinery: if no message carries
state, a dropped message costs a delay rather than the run.

---

## What the first production run taught

The predecessor system ran one full session before this design closed: eight
features, ~13M self-estimated tokens, 301k words of coordination artifacts for
8,405 lines of shipped code. The review machinery earned its keep — its
review caught a data-loss bug invisible to 1,383 green tests — but the cost
structure was measurably wrong, and five mechanisms here exist because of it.

| measured | mechanism |
|---|---|
| 28% of tokens went to roles that shipped nothing, incl. an auditor mostly idle between gates at 1.32M | the auditor is ephemeral: `orch audit` spawns it per gate, fresh, and it dies with its verdict |
| 301k words of hand-authored state; the worst anomaly class (tree-drift, ×3) was status files going stale in one copy of the tree | status is rendered from the ledger, never authored; decisions are ledger events |
| every agent re-read the whole artifact tree every turn | `hooks/artifact-scope.sh` — the blind roles read `requirements.md` and `request.md`, nothing else |
| an opus test-writer burned 2.45M tokens; the sonnet reviewer's findings held up | producers run sonnet; opus is reserved for roles that decide; `quick` runs at low effort |
| one feature took five review cycles, each re-reading the whole feature | `orch review scope` — a re-review gets the open findings and the diff since the last verdict |
| the longest-lived session ended at ~1.1M tokens of accumulated context | `orch team recycle` — respawn on compaction; agents are stateless relative to the ledger |

`orch report` now prints coordination share and artifact words per diff line on
every feature, with the run's numbers — 28%, 36 w/line — as the baselines to
beat. If those two metrics do not fall materially, this table is wrong and
should be revisited.

## What would falsify this

The design commits to being measurable, which means committing to outcomes that
would sink parts of it:

- **Rung 4 never produces a distinguishing experiment.** Delete rung 4.
- **A reviewer lens shows ~0% unique finds over 10+ features.** Delete the lens.
- **A gate never blocks anything across many features.** It is ceremony; delete
  it.
- **`escalation_precision` comes out low.** The detector is trigger-happy and
  the thresholds are wrong — most likely `ORCH_T_CONTEXT_PCT`, which is the
  least defensible number in the system.
- **`orch lab ablation` shows solo matching the crew on outcome per dollar.**
  Then this pipeline's premise is wrong for this codebase, and the honest move
  is to say so in the README.

`orch lab` exists to make those answerable. Nobody has published the coding
equivalent of [P20], so until someone runs it, every threshold here is a guess
with a mechanism attached.

**If a tier, a lens, or a gate shows no unique yield after 20 features, delete
it and say so.**
