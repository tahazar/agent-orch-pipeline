# Provenance

Every design decision in this repository that rests on an outside result cites
it here by tag. The code references these tags in comments.

## How to read this file

Each entry carries a status:

| status | means |
|---|---|
| **verified** | the source was located and the figure checked against it |
| **partial** | the source was located; some figures matched, others could not be found in it |
| **unverified** | no source located. The figure is recorded so the code acting on it can be traced, and nothing more |

An **unverified** entry is not evidence. It is a marker saying which number a
piece of this system was built on, so that when someone checks it and finds it
wrong, every place it leaked into the design can be found.

**The most important thing in this file is the scope note on [P20].** It is the
result the entire escalation ladder is built on, and it does not say what this
repository once claimed it said.

---

## Scope: what the evidence actually covers

Almost every result below is from **multi-hop question answering or
mathematical reasoning**, on models that are not frontier coding agents. This
pipeline does software engineering with tools. The gap is not a technicality:

- [P20]'s authors write that they "focus on text-only multi-hop reasoning; MAS
  advantages with tools/vision or safety constraints are out of scope."
- [P11] is Omni-MATH.
- [P12] and [P13] are reasoning and error-detection tasks.

So the honest summary is: **the shape of the control law is borrowed; none of
its constants are.** Every threshold in `lib/health.sh` and `lib/escalate.sh`
is ours, and unvalidated. `orch lab` exists to replace them with measurements.

There is also evidence pointing the other way that this file previously omitted.
Anthropic's own Research system — a lead agent with 3–5 parallel subagents —
[outperformed single-agent Claude Opus 4 by 90.2%][anthropic-research] on
research tasks, at roughly 15× the tokens. That is not matched-budget, which is
precisely the confound [P20] criticises, but it is a real deployed result on a
tool-using task where multi-agent won decisively. A summary of the literature
that cites only [P20] is selective.

The defensible reading of both together is a **task-shape rule, not a ranking**:
orchestration pays when work decomposes into independently explorable parallel
subtasks over a wide search space, and loses on a single dependent reasoning
chain. That is why `orch` starts cheap, escalates on evidence, and reaches for
best-of-N — genuinely parallel, no shared state — before it reaches for
anything that requires agents to agree.

[anthropic-research]: https://www.anthropic.com/engineering/built-multi-agent-research-system

---

## [P36] The FLT formalization repository — **verified**, first-hand

> Anthropic. *Fermat's Last Theorem in Lean 4.*
> [github.com/anthropics/fermats-last-theorem](https://github.com/anthropics/fermats-last-theorem),
> `README.md` and `formalization.yaml`, read 2026-09-15.

Read directly. Figures taken from it: 29,511 theorems; 1,450 definition
modules; 60,475 modules built; 1,052,234 declarations accepted by the
independent kernel `nanoda` 0.4.13; the default build target fails unless
`fermat_last_theorem` depends on exactly `propext`, `Classical.choice` and
`Quot.sound`; no module contains `axiom`, `sorry`, `native_decide`, `unsafe`,
`extern`, `implemented_by`, `partial def` or `#eval`; `leanprover/comparator`
v4.33.0 confirmed the statement identical to a Mathlib-only challenge file.
Statements live in `Theorems/`, proofs in `P2M/Sol/`. Quoted verbatim in
`docs/VERIFICATION.md`: "with Lean as the arbiter, and are written to be
checked rather than read", and the trust-model sentence and its caveat.

*Acts on:* every gap in `docs/VERIFICATION.md`; specifically the enumerated
escape-hatch list (gap 3) and statement identity (gaps 1 and 2).

---

## [P37] Prove2Me — **verified**, first-hand

> Peng, T. et al. *Prove2Me: An Open Collaborative Platform for Scaling Math
> Formalization.* arXiv:2608.28433 (paper **not** read — arxiv is blocked from
> this environment). The agent workspace was read instead:
> [github.com/prove2me/prove2me_workspace](https://github.com/prove2me/prove2me_workspace),
> `SKILL.md` and `references/{prove,mission_solver,mission_auditor,mission_captain,contribute}.md`,
> 2026-09-15.

Read directly from the workspace, not the paper. The three core rules (the
`solution` theorem must match the target's `formal_statement` exactly; never
import your own target; sorry-free); the verdict set `ACCEPTED`,
`SKETCH_ACCEPTED`, `CE`, `WA`, `SORRY`, `FAILED`, `ERROR`; parent theorems
auto-resolving once every imported child is proved; the solver's instruction
to read logged dead-ends and never retry a captain-rejected path; the
auditor's read-back written from "only the Lean code ... never the informal
statement", with "omitting a hypothesis is the worst failure mode"; the
captain rule that "linking is attestation" and faithfulness is "the single
most important thing".

That the platform coordinated the FLT run, and that early runs without it
"collapsed because agents accumulated too much local context, lost track of
proved results, and duplicated work", is from secondary coverage of [P38] and
is **unverified** at the source.

*Acts on:* gaps 5, 6 and 7 in `docs/VERIFICATION.md`.

---

## [P38] Anthropic, *Formalizing Fermat's Last Theorem* — **unverified**

> [anthropic.com/research/formalizing-fermats-last-theorem](https://www.anthropic.com/research/formalizing-fermats-last-theorem)
> and the accompanying PDF. Both blocked by this environment's egress policy;
> Nature's coverage and Buzzard's post were blocked too.

Everything attributed to the post — 11 days, ~6 billion output tokens, "largely
autonomously", human input limited to priority, the DAG / statement-proof
separation / natural-language index as the three coordination mechanisms — is
taken from search-engine summaries of it and of its coverage. The figures that
overlap [P36] agree with [P36]; the rest should be checked against the post
before being quoted further.

---

## [P39] Anthropic engineering, harness design — **partial**

> *Effective harnesses for long-running agents* (Nov 2025) and *Harness design
> for long-running application development* (Mar 2026), anthropic.com. Blocked;
> summarised from secondary coverage.

Carried: an initializer/coding-agent split with a feature list carrying
pass/fail status and a rule to verify end-to-end before marking done; a
planner/generator/evaluator split on the stated ground that "self-evaluation
by the same agent that generated the output is unreliable"; and that the
harness was **simplified** on a newer model with no loss of quality.

*Acts on:* "What not to copy" in `docs/VERIFICATION.md`.

---

## [P42] TDD inside the agent loop — **partial**

> Böckeler, B. *TDD inside the agent loop — theater or actual value?*
> martinfowler.com, Exploring Gen AI, 10 Aug 2026. Blocked from this
> environment; figures and quotations are from search-engine extracts and
> from a GitHub issue that cites the article. An earlier revision of this
> file attributed the finding to VILA-Lab's *Dive into Claude Code*, which
> only indexes it.

Recorded: "there was no clearly discernable difference based on TDD workflow
versus no TDD workflow"; tokens with TDD 8.50× for small tasks, 2.96× for
medium, 4.89× for large; mutation scores showed no meaningful difference.
The judge model, reading traces, found non-TDD agents "tended to think through
the data model, edge cases, contracts, and overall design before writing
anything", while under TDD they "kept making locally minimal changes around
the first test", with "early design hardening quickly and agents rarely
returning for a serious refactor". Recommendations: mutation testing as a
sensor, and tests written from the spec. The author's own caveat: five
batches, one judge model, tasks chosen by the author — exploratory, not a
controlled trial.

*Acts on:* "What not to copy" in `docs/VERIFICATION.md`, and the developer's
orders at `strict`, which must not become "make the failing tests pass one at
a time".

---

## [P43] TDD-Agent — **unverified**

> *TDD-Agent: Test-Driven Reasoning for Code Generation.* arXiv:2608.16742.
> Blocked; from a search-engine extract only: "at its fifth iteration,
> TDD-Agent exhibits comparable token consumption to baseline agents while
> consistently achieving superior performance."

Recorded because it appears to contradict [P42] and does not: it measures
test-first **reasoning** inside a generation on correctness benchmarks, where
[P42] measures test-first **process** in the tool loop on design-level tasks.
The distinction is load-bearing in `docs/AGENT-TDD.md` and should be checked
against the paper before being leaned on further.

*Acts on:* the developer's own test path in `docs/AGENT-TDD.md`, phase 3.

---

## [P40] Reward hacking on tests — **partial**

> ImpossibleBench (lesswrong summary; arXiv paper not fetched). "GPT-5
> exploiting test cases 76% of the time on the oneoff version of
> impossible-SWEbench." Also secondary reporting that Anthropic's own
> training-time countermeasures include hidden tests "to catch solutions that
> only pass training cases".

The 76% figure is from a summary, not the paper. The direction — frontier
models overfit a test oracle when the oracle and the specification disagree —
is consistent across ImpossibleBench, EvilGenie and SpecBench, all of which
appeared in the same search and none of which were read in full.

*Acts on:* the "TDD is a much weaker instance" table and gap 8 (held-out
tests) in `docs/VERIFICATION.md`.

---

## [P41] Buzzard's audit of the FLT repository — **unverified**

> Buzzard, K. *FLT: Anthropic has beaten me to it.* Xena Project blog,
> 4 Sep 2026. Blocked; the quoted check — asking an agent "to flag every line
> of the repository that was not a definition or a proof", roughly 100 lines
> returned, a convenience tactic — is from secondary coverage.

*Acts on:* gap 3 in `docs/VERIFICATION.md`, as the hand-run version of an
enumerated trust base.

---

## [P35] Claude Code substrate — **verified**, first-hand

**Verified 2026-08-12 against `claude 2.1.228`**, re-checked 2026-08-13 against
`2.1.229`, by inspecting the running process and the installed binary. These
are internals and they will rot; re-verify before relying on them.

| Fact | How it was checked |
|---|---|
| Session registry at `~/.claude/sessions/<pid>.json` carrying `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`, `version`, `peerProtocol`, `kind`, `entrypoint`, `messagingSocketPath`, `name`, `nameSource` | read the live file |
| Per-session key at `~/.claude/sessions/<pid>.<sha256>.key`, mode 0600 | `ls -l` |
| Per-session Unix socket at `/tmp/cc-socks/<pid>.sock`, mode `srw-------` | `ls -l` |
| `claude agents --json` returns the roster without a TTY | ran it |
| Shared task list at `~/.claude/tasks/<id>/` with `N.json` per task and a zero-byte `.lock` | created a task, inspected the directory |
| `CLAUDE_CODE_TASK_LIST_ID` selects the directory | binary's settings surface |
| `crossSessionInbound` accept/hold/refuse | present in the binary |
| `dialogExpiry` — enum `60s`/`5m`/`10m`/`never`, **default 5m** | the setting's own description string |
| `isolation: "worktree"` and `disallowedTools` on agent definitions | present in the binary |
| Hook events `PostToolUseFailure`, `PostCompact`, `TaskCompleted`, `TaskCreated`, `TeammateIdle` | the binary's hook-event table |
| `claude --agent <name>`, `-n/--name`, `--bg`, `--permission-mode` | `claude --help` |

**Three corrections to the specification, found while verifying:**

1. **The declarative hook `if` field does not exist.** The settings validator
   states hooks map event names to matcher arrays carrying string matchers, and
   no if-condition appears in the binary. `orch` narrows by `matcher` and does
   the command match inside the hook.

2. **The roster does not report permission mode.** `claude agents --json`
   returns `pid`/`cwd`/`kind`/`startedAt`/`sessionId`/`name`/`status` only.
   `orch doctor` recovers the class from process arguments and reports
   `unknown` rather than guessing — a wrong class would produce a confident
   all-clear for exactly the failure the check exists to catch.

3. **`--settings` is documented as taking one file.** Whether it is repeatable
   is unstated, so `orch` does not depend on it: hook wiring goes into the
   project's `.claude/settings.json` at install time, and only the per-role
   permission file is passed on the command line.

Not verified first-hand, still taken on trust: that macOS verifies socket
ownership only while the posting child process lives; that Linux verification
survives the process exiting; that a container running as PID 1 cannot verify
it at all.

---

## [P20] Matched-budget ablation — **verified**, and narrower than it looks

> Tran, D. & Kiela, D. *Single-Agent LLMs Outperform Multi-Agent Systems on
> Multi-Hop Reasoning Under Equal Thinking Token Budgets.* Stanford.
> [arXiv:2604.02460](https://arxiv.org/abs/2604.02460), 2 Apr 2026 (rev. 11 Apr).

**Checked against the paper.** Single-agent matched or beat multi-agent across
five topologies (sequential, subtask-parallel, parallel-roles, debate,
ensemble) at every thinking-token budget tested.

| what the paper is | what it is not |
|---|---|
| FRAMES and MuSiQue (4-hop), text-only QA | any coding or software-engineering task |
| Qwen3-30B, DeepSeek-R1-Distill-Llama-70B, Gemini 2.5 Flash/Pro | any frontier agentic coding model |
| tools explicitly out of scope, per the authors | evidence about tool-using agents |

**The crossover, stated precisely.** Multi-agent overtakes under *masking* at
α=0.7 — **70% of context tokens substituted with misleading content.** That is
corruption, not occupancy.

**Where this went wrong here.** `ORCH_T_CONTEXT_PCT=70` in `lib/health.sh` was
commented as "[P20]'s literal condition" while measuring how *full* the context
window is. A window 70% full of correct information has nothing to do with one
70% poisoned. The threshold stays at 70 but is now documented as ours and
unvalidated, justified only as a leading indicator of imminent compaction —
and compaction is the signal that actually matters.

**What [P20] legitimately supports:** starting cheap and escalating on evidence
of degradation; measuring that condition rather than assuming it; and the
methodological point that comparing a single agent against a multi-agent system
using far more compute proves nothing.

---

## [P9] MAST — **verified**

> Cemri, M., Pan, M. Z., Yang, S., et al. *Why Do Multi-Agent LLM Systems
> Fail?* [arXiv:2503.13657](https://arxiv.org/abs/2503.13657).
> 14 failure modes, 1600+ annotated traces, 7 MAS frameworks.

| Failure mode | Frequency | Used in |
|---|---|---|
| step repetition | 15.7% | `step_repetition`, threshold 3 |
| unrecognized completion | 12.4% | — |
| task-spec disobedience | 11.8% | — |
| incomplete verification | 8.2% | the attested-gate design |
| task derailment | 7.4% | — |

Step repetition being the most frequent single mode is why it is the cheapest
signal in `lib/health.sh`. The threshold of 3 is ours.

---

## [P11] Reviewer precision ≠ critique uptake — **verified**

> *Precise but Uncoupled: Reviewer Precision Does Not Guarantee Critique Uptake
> in Multi-Agent Math Reasoning.*
> [arXiv:2607.15388](https://arxiv.org/abs/2607.15388). 4,181 verifier-grounded
> Omni-MATH problems.

The planner-executor-reviewer protocol had the better reviewer (precision 0.861
vs 0.644) and the worse outcome, because its solver acted on verified-useful
critique **33.6%** of the time against broadcast's **93.5%**.

Two findings this repository acts on directly:

- Embedding reviewer guidance in the solver's working context **partially**
  improves follow-through and **does not close the gap**. `lib/findings.sh`
  inlines finding text verbatim for this reason — it is the best lever
  available, not a fix.
- **Forcing explicit acknowledgment lowered final accuracy.** Nothing in orch
  makes an agent restate a finding back at anyone.

A previous version of this file claimed inline delivery "recovered most of the
loss". The paper does not say that.

*Scope: math reasoning, not code review.*

---

## [P8] Code review agent benchmark — **verified**

> Code Review Agent Benchmark, 234 tests across four agentic review tools.

Individual tools passed **20.1%–32.1%**; the union of all four reached
**41.5%** (97/234). Human reviewers pass 100%.

Note what this actually shows: the union beats any single tool, *and* the best
available ensemble still misses most defects. It argues for running more than
one lens. It does not argue that the reviewers are good.

*Acts on:* the reviewer ensemble at tier `standard` and above, the union
assertion in `test/findings.test.sh`, and the independence requirement enforced
by `hooks/task-scope.sh` — the union result holds only while the lenses are
independent.

---

## [P3] [P4] Cost multiplier — **partial**

Anthropic reports standalone agents at roughly **4×** the tokens of a chat
interaction and multi-agent runs at roughly **15×**
([source][anthropic-research]). The "revised down to 3–10×" figure [P4] that
`orch lab ablation` prints for comparison could not be located and is
**unverified**.

---

## [P18] Best-of-N on SWE-bench — **partial**

The claimed trajectory (20.6% → 28.8% at Best@8 → 32.0% at Best@16, verifier
correct ~86% of the time) could not be matched to a single source. Adjacent
published work supports the shape: Best@K on SWE-bench Verified improves
substantially with rollouts before plateauing (execution-based and
execution-free verifiers converging around 43.7% and 42.8%), and sampling
diversity is repeatedly identified as the binding constraint rather than
verification.

*Acts on:* rung 3, and specifically why `lib/candidates.sh` seeds three
genuinely different approach directives rather than three temperatures. The
design rationale survives; the exact numbers should not be quoted.

---

## [P12] [P13] Debate — **unverified**

Recorded figures: debate raised inter-agent consensus from 81.7% to 90.1% while
accuracy fell (worst case 48.3% → 20.7%), sycophancy to 85.5%, correct
reasoning discarded at up to 32.3 points [P12]; competitive debate as cheap
talk, underperforming a single agent by up to 15 points on error detection
[P13].

**No source located for these numbers.** Real work on the same failure mode
exists — sycophancy propagation in multi-agent debate, and controlled studies
finding isolated self-correction beating unguided homogeneous debate — and
[P20] independently found debate among the topologies that did not beat a
single agent.

*Acts on:* invariant 5 and `agents/auditor.md` — conflicts are settled by
running an experiment, never by a vote. The direction is well-supported even
though these figures are not.

---

## Claims still carried without a source — **unverified**

Each records the figure the specification stated and the place that acts on it.

- **[P1]** Parallel competing-hypothesis debugging as the remedy for anchoring;
  a hook returning exit 2 outranks in-prompt instruction. *Acts on:*
  `lib/diagnose.sh`, all five gate hooks.
- **[P2] [P5] [P30]** Reviewers should get fresh context and see only the diff,
  never the builder's trace. *Acts on:* invariant 3, `agents/code-reviewer.md`,
  `hooks/task-scope.sh`.
- **[P6] [P7]** Every gate backed by an external oracle. *Acts on:* invariant 6,
  `lib/evidence.sh`.
- **[P10]** Calibrated ensembles of diverse weak verifiers beat single judges by
  13–18 points. *Acts on:* why the ensemble is (model × lens) diverse rather
  than N copies of one reviewer.
- **[P14]** Four of eight notable 2025 orchestration tools are dead. *Acts on:*
  the delete-what-shows-no-yield discipline.
- **[P16]** Reducing agent specs from ~1,000 to ~200 lines reported as an
  improvement. *Acts on:* the prompt budget in `test/agent-lint.sh`.
- **[P17]** 80+ agents unanimously endorsed a non-existent padding oracle in
  OpenSSL; one empirical test killed it. *Acts on:* invariant 5, and the rule
  that two simultaneously-held predictions escalate rather than get a tiebreak.
- **[P21] [P22] [P23]** No architecture consistently wins; agents can be "100x
  more expensive while only being 1% better"; the Pareto-winning harness used 3×
  less context and simpler prompts. *Acts on:* invariant 8 and the rejection of
  "more roles" as an answer to poor output.
- **[P25]** The blackboard pattern. *Acts on:* the `docs/features/**` artifact
  contract.

---

## Re-verifying [P35]

```bash
claude --version
claude agents --json
ls -l ~/.claude/sessions/ /tmp/cc-socks/
ls -l ~/.claude/tasks/*/            # after any session creates a task
orch doctor
```

`orch doctor` warns when the installed CLI is not the version recorded in
`lib/common.sh`, because a from-memory model of another program's internals is
the most likely failure point in this build.
