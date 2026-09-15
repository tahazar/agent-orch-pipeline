# TDD, agent-first

How to keep what test-driven development is *for* while dropping the ritual
that was built for a human's working memory. This is the design for what
`strict` should become. [`VERIFICATION.md`](VERIFICATION.md) is the gap list
it grew out of; the `[Pn]` tags resolve in [`PROVENANCE.md`](PROVENANCE.md).

The goal, stated so it can be missed: **better design and code, with every
line of production code demanded by a test, at a token cost we would rather
lower than raise — but quality first.**

---

## Take TDD apart before adapting it

Red-green-refactor is one ritual carrying six separate benefits. Böckeler's
experiment [P42] is what happens when you hand the ritual to an agent whole:
three to eight times the tokens and no better design, because the agent gets
the ritual's costs and almost none of its benefits. The traces show why — the
non-TDD agents designed first and wrote once; the TDD agents made "locally
minimal changes around the first test" and never refactored.

So: separate the benefits, ask what each is *made of*, and give the agent that
thing directly.

| what TDD gives a human | made of | a human gets it by | an agent gets it by |
|---|---|---|---|
| 1. the interface is designed before the implementation commits to one | thinking as a caller first | writing the test before the code | a **design pass** that emits the contract in one generation, by the role that decides |
| 2. the test is honest, because its author does not yet know the implementation | information asymmetry | not having written the code yet | a **blind author** — a different context that never sees the code [P37] |
| 3. small steps keep the problem inside working memory | cognitive-load relief | one test at a time | nothing. The agent holds the whole design; forcing it into a drip is what cost 3–8× |
| 4. green tests make aggressive refactoring safe | a frozen oracle | the tests exist and pass | the tests exist, pass, **and cannot be edited** while refactoring |
| 5. the refactor happens | felt pain of duplication and awkwardness | taste | a **separate pass with a mechanical trigger and mechanical exit**, because the agent feels nothing |
| 6. nothing is written that a test did not demand | restraint | discipline | **diff coverage** as an attested number: an undemanded line is a finding |

Row 3 is the one to delete outright. Rows 1, 2 and 4 already exist in
`strict`, partly. Rows 5 and 6 do not exist at all, and they are the two that
concern design. That is the whole reason the ritual disappointed: the parts of
TDD that produce design are exactly the parts an agent does not do
spontaneously.

One more thing the ritual conflates. "Test-first" in the TDD-Agent result
[P43] — where it helped correctness at no extra cost — is test-first
**reasoning**: the model enumerates behaviours and edge cases as tests while
it is deciding what to write, in the same generation as the code. That is
cheap because it is one pass. Test-first **process** in the tool loop is what
Böckeler measured. Keep the reasoning, drop the process.

---

## The shape

Seven phases. Each is one pass of one context, feedback is batched, and every
transition is a mechanical gate. Model calls are marked; everything else is
CPU.

```
 request ──▶ 1 contract ──┬──▶ 2 oracle (blind) ──┐
   frozen     [opus, 1×]  │                        ├──▶ 4 gates ──▶ 5 refactor ──▶ 6 review ──▶ 7 approve
                          └──▶ 3 implement ────────┘     [cpu]      [sonnet, 1×]   [sonnet ×L]   [packet]
                               [sonnet, 1× + repairs]
```

### 1. Contract — the statement, made compilable

The `tech-lead` already writes `requirements.md` and `design.md`. It now also
commits the **contract**: the public interface as compilable stubs — types,
signatures, docstrings, bodies that raise `NotImplemented` (or the language's
`todo!()`, `throw new Error("unimplemented")`). The build must pass with the
stubs in place, attested: gate `contract-compiles`.

This is the Lean statement with `sorry` in it, and it is the single change
that makes the blind oracle work in practice. Today the test-engineer, blind
by design, must guess the interface; when it guesses differently from the
developer, the first repair cycle is spent reconciling names — tokens burned
on nothing. With a contract, both blind parties are blind to *each other* and
sighted on the same interface.

It is also where design happens, and deliberately so. Böckeler's non-TDD
agents "think through the data model, edge cases, contracts, and overall
design before writing anything" — that is the behaviour to keep, and it
belongs to the role that runs opus and decides, not to the producer. The
contract is one generation. Requirements carry ids (`R1`…) so everything
downstream can cite them.

### 2. Oracle — blind, whole, and constraining

Unchanged in spirit: the `test-engineer` writes the suite from
`requirements.md` and the contract, seeing neither the plan nor the code. Three
changes to what "done" means:

- **The red phase must show the tests ran.** `ran > 0`, `failed > 0`, and the
  build green at the same sha — the suite fails on `NotImplemented`, not on an
  import error (gap 4 in `VERIFICATION.md`).
- **Every requirement is cited.** `orch spec coverage` maps `R`-ids to tests;
  an uncovered requirement is a blocking finding against the test-engineer,
  disputed by naming the ambiguity (gap 6).
- **The oracle tree is frozen at the red-phase sha.** From here on, the
  `tests-pass` gate compares tree hashes and blocks `ORACLE_MOVED` on any
  change, however it was made (gap 2).

Optionally at `strict`, the test-engineer marks a holdout subset (gap 8). Not
by default; see "What to measure".

### 3. Implement — design first, one pass, own tests allowed

The `developer` gets the requirements, the contract, and **the whole visible
oracle at once**. Its orders change in one sentence, and it is the sentence
Böckeler's traces argue for: *read the entire suite and the requirements,
design the implementation, then write it; the suite is a specification, not a
to-do list.* Not "make the failing tests pass". The two orders produce
different code from the same model.

The developer may **add** tests. It may not touch the oracle. Concretely,
`write-scope.sh` allows a developer test path (`test/dev/**` or the repo's
equivalent, `ORCH_DEV_TEST_GLOB`) and denies the oracle paths; `ORACLE_MOVED`
checks only the frozen tree. This is test-first *reasoning* made executable:
the edge cases the developer enumerates while designing become tests in the
same generation as the code, at almost no marginal cost, and they are what
carries coverage from "the requirements are checked" to "every line is
demanded". They are reviewed by the `reproduction` lens like any other test,
and they count toward diff coverage but **not** toward the oracle — a
developer's own test cannot be the reason a requirement is considered met.

Repairs are batched: `orch run` records every failure, all of them are
delivered verbatim in the next turn (the findings mechanism already does this
for reviews), and the developer fixes in one pass. `test_oscillation` still
escalates. There is no per-test loop anywhere in this design.

### 4. Gates — CPU, not tokens

All mechanical, all attested, all before any reviewer is spawned:

| gate | checks | closes |
|---|---|---|
| `statement-frozen` | `requirements.md`/`request.md` hashes unchanged since tier confirm | gap 1 |
| `oracle-frozen` | oracle tree hash at HEAD == at red-phase sha | gap 2 |
| `evidence-clean` | the green run was at HEAD with no dirty tree | gap 2 |
| `axioms` | no new `skip`/`only`/`xfail`/ignore/disable, no config or CI edits | gap 3 |
| `spec-coverage` | every `R`-id cited by an oracle test | gap 6 |
| `diff-coverage` | lines added or changed by the diff executed by the suite ≥ `ORCH_T_DIFF_COV` (default 100, exclusions allowlisted per repo) | benefit 6 |
| `mutation` | mutation score on changed files ≥ `ORCH_T_MUTATION` | benefit 4, honestly measured |

The last two are new sensors and the most important lines in this document.
**Line coverage says a line ran; mutation score says a test would notice if it
were wrong.** A suite with 100% coverage and a 40% mutation score is a suite
that exercises the code and asserts nothing about it — which is precisely the
suite an agent writes when it has already seen the implementation. Böckeler's
recommendation was mutation testing as the sensor; it slots in as an attested
metric, costs CPU rather than tokens, ranks best-of-N candidates, and is the
only gate here that measures whether the oracle constrains anything.

Mutation testing is slow on a whole codebase and fast on a diff. Run it on
the files the diff touches, with the mutation tool the repo already uses
(`mutmut`, `stryker`, `cargo-mutants`, `go-mutesting`); the per-runner
extractor is the cost, as it is for the red-phase counts.

### 5. Refactor — the step agents skip, made unskippable

This is benefit 5, and it is the one that produces design. It runs as a
**separate pass**, after green, in a **fresh context**: the developer
recycled, or a second `developer` session with orders that say *design only*.
Fresh, because an agent asked to refactor its own code is anchored to the
reasons it wrote it that way; the refactor benefits from the same
independence a reviewer does.

The pass has:

- **a mechanical trigger.** Design metrics computed on the diff — cyclomatic
  complexity, function and file length, duplication (`jscpd`, `radon`,
  `gocyclo`, `lizard` — one per language, in the same extractor slot as the
  runners), plus the diff-size ranking that already exists. Thresholds are
  ours and unvalidated, like every threshold in `lib/health.sh`, and get the
  same treatment: overridable, and `orch report` says whether they fire. At
  `strict` the pass can also be unconditional; the trigger decides whether
  `standard` pays for it.
- **a frozen invariant.** The oracle and the developer's tests both green
  before and after, `ORACLE_MOVED` enforced, `axioms` delta zero. This is
  where a frozen oracle earns its keep: it is the only reason an agent can be
  told "change anything you like" safely.
- **a mechanical exit.** The metrics that triggered it improved, tests green,
  and the diff against the pre-refactor sha is not larger than the pre-refactor
  diff was (a refactor that doubles the code is a rewrite). If the exit is not
  met, the pass is discarded — the pre-refactor commit stands — and the ledger
  records `refactor.discarded` with the numbers. No repair loop on a refactor.

One pass, one budget, no cycles. The human ritual's refactor step is cheap
because a human does it continuously; this one is bounded because an agent
does it once, deliberately, with a number to hit.

### 6. Review — as now, delta-scoped

The existing ensemble: `correctness`, `failure-modes`, `reproduction`, fresh
context, `orch review scope` giving a re-review only the delta and the open
findings. A `design` lens (coupling, naming, abstraction level) is a candidate,
**added only if the mechanical metrics leave it unique finds** — the yield
report decides, as it does for every lens. The reviewers now review code that
has passed diff coverage, mutation and a refactor; the findings they raise
should be different in kind from today's. If they are not, that is a result.

### 7. Approve — the packet

The human sees the statement, the read-back, the coverage table, the axiom
delta, the metrics before and after refactor, and the evidence rows — the diff
last (gap 5). The aim is a human who approves most features without opening
the diff, because everything the diff could tell them has already been checked
by something that cannot be persuaded.

---

## Where the tokens go, and where they do not

The acceptance of higher token cost is for *quality*, not for ritual. This
design spends on exactly three things and refuses to spend on the rest.

**Spent, on purpose:**

- one opus generation for the contract (design, by the role that decides);
- one extra sonnet context for the blind oracle (independence);
- one extra sonnet context for the refactor pass (the design step agents skip).

**Refused:**

- per-test cycles. Every phase is one pass with batched feedback. This is the
  entire 3–8× that Böckeler measured, and it buys nothing.
- interface-reconciliation cycles. The contract removes them.
- model calls for sensing. Coverage, mutation, complexity, duplication,
  tree hashes and axiom scans are CPU. The report will show these gates
  blocking; if they never do, delete them.
- whole-feature re-reads. Re-review and repair are delta-scoped already.
- opus for production. Contract and audit decide; everything that produces
  runs sonnet.
- a model judge of design quality in the pipeline. Böckeler needed one for
  an experiment; a pipeline needs numbers it can act on every feature. If a
  judge is ever wanted, it lives in `orch lab`, opt-in, with a control.

Parallelism is for wall clock, not tokens: the oracle and the implementation
can start together from the contract, since they are blind to each other
anyway. The developer does not wait for the red phase to begin designing.

---

## What changes per tier

The mechanical floor is cheap enough to apply everywhere; the model contexts
are what a tier buys.

| | quick | standard | strict |
|---|---|---|---|
| contract stubs | no | no | **yes**, `contract-compiles` gate |
| who writes tests | developer | developer | **blind test-engineer**; developer adds its own |
| oracle frozen | n/a | n/a | **yes** |
| `axioms`, `diff-coverage`, `statement-frozen`, `evidence-clean` | **yes** | **yes** | **yes** |
| `mutation` | report only | gate | gate |
| refactor pass | no | on trigger | on trigger, or always |
| reviewers | none | 2–3 lenses | 2–3 lenses |
| holdout | no | no | optional |

`quick` gets the floor because it costs nothing and because "one-liner" is
the tier a `skip` slips into. The sensors are the same everywhere; the tier
decides what a failing sensor does.

---

## Who runs what

The rule is the one the v1 post-mortem produced, applied to the current
lineup: **the frontier model is reserved for the roles that decide; producers
run the cheapest model that holds quality.** What changed is that the frontier
model is now `fable`, its own reference says its lower effort levels often beat
prior models at `xhigh`, and that reference lists the prices [P44]:

| model | input $/M | output $/M | best at, per its reference |
|---|---|---|---|
| `fable` (Claude Fable 5.1) | 10 | 50 | long-horizon autonomous runs, first-shot implementation of well-specified systems, parallel sub-agent delegation, review and debugging |
| `opus` (Claude Opus 5) | 5 | 25 | the default general model |
| `sonnet` (Claude Sonnet 5) | 2 | 10 | coding and agentic work at `xhigh` |
| `haiku` (Haiku 4.5) | 1 | 5 | subagents and simple tasks |

Aliases, not dated ids: an alias tracks the current generation and a pinned id
is how a pipeline quietly ages. Effort is declared in each role's frontmatter
next to its model, so the two are read together; a tier may lower it at spawn
(`quick` runs `low`) and nothing raises it silently.

| role / phase | model | effort | why this, why not more |
|---|---|---|---|
| `director` | `fable` | `high` | the run's plan and every gate decision; long-lived, so the reference's "high is the start, sweep down to medium where quality holds" applies directly. Its memory surface is the ledger |
| `tech-lead` — contract, requirements, tier | `fable` | `high` | the most leveraged single generation in the pipeline and the one Fable is built for: design first, write once. Not `xhigh`: the reference warns that on long deliverables `xhigh` drafts the output in thinking and again in the reply, roughly doubling output tokens; move up only where measured |
| `auditor` — one gate, fresh | `fable` | `xhigh` | adjudication by experiment; short-lived and per gate, so the cost is bounded, and `xhigh` is where the reference says the model's verification behaviour is most rigorous |
| `test-engineer` — the oracle | `sonnet` | `xhigh` | one pass, and it is the statement everything else trusts; `xhigh` is the reference's setting for coding on Sonnet 5 |
| `developer` — implement, repairs | `sonnet` | `xhigh` | producer work; the volume role, so the model is the cheap one and the effort is the coding sweet spot. `quick` lowers it to `low` |
| `code-reviewer` × lenses | `sonnet`; the `correctness` lens on `opus` | `high` | the value is the union of independent lenses [P8], not depth in any one, and a second model is the cheapest independence there is — the ensemble was meant to be (model × lens) diverse and until now ran one model. Delta-scoped; `orch findings yield` decides whether the opus lens stays |
| refactor pass (phase 5) | `sonnet` | `xhigh` | one fresh context, design only, with a number to hit. The sweep-up candidate is `opus` at `high` if the discard rate says sonnet cannot do the step |
| read-back (phase 7) | `sonnet` | `low` | translation, not judgement; `haiku` is the sweep-down |
| best-of-N candidates | `sonnet` | `xhigh` | N × the developer; diversity comes from the directives, not the model. One candidate on `opus` is the next diversity axis to try, and selection stays mechanical so the model cannot bias the pick |
| diagnose hypotheses | `sonnet` | `high` | K read-only contexts that must each return a command; execution decides, not depth |

Three things the reference says about Fable that bear on how the roles are
written, recorded here so the prompts get re-checked rather than assumed:

- **Prompts written for prior models are often too prescriptive and reduce
  its output quality.** `director.md` is a numbered procedure. The
  recommended check is an A/B with the step-by-step scaffolding removed —
  state the goal and the gates, not the steps. That is an `orch lab`
  experiment, not a blind edit.
- **On long unattended runs it can end a turn by describing the next step
  instead of taking it.** That is precisely the failure the first live run
  had — a director at an empty prompt — so the documented guard is now in
  `director.md`: check the last paragraph before ending a turn.
- **Sub-agent delegation is reliable, and asynchronous delegation beats
  spawn-and-block.** `orch` already does this: crews are spawned and the
  director carries on; a message is never load-bearing. Keep it that way.

The efficiency claim, stated so the report can check it: the frontier model
runs in three short-lived or low-volume places, and every high-volume token —
implementation, tests, repairs, reviews, candidates — is produced on the
cheapest model at the effort its own reference recommends for coding. If
`orch report` shows the coordinator share of tokens rising above the 28%
baseline after the switch to `fable`, the director's effort is the first thing
to sweep down.

---

## What to measure, and what would sink it

Every new piece is a mechanism with a number, so every one can be deleted on
evidence. `orch report` should print, per feature and per tier:

| number | what it decides |
|---|---|
| mutation score, oracle only vs oracle + developer tests | whether the developer's own tests add constraint or just coverage |
| diff coverage before and after the developer's tests | whether the 100% target is met by demand or by padding |
| refactor pass: metrics before/after, discarded rate | whether the trigger is set right; a pass that is always discarded is wrong, one that never triggers is decoration |
| interface-reconciliation repairs per feature | should go to ~0 with the contract; if not, the contract is not being written |
| tokens per feature at `strict` vs `standard`, and repair cycles | the actual cost of the design, against Böckeler's 3–8× as the number to stay well under |
| findings raised by reviewers on code that passed all gates, by lens | which lenses still find things once the CPU gates run |
| holdout unique catches | whether the visible oracle is being overfit at all |

Sinking conditions, stated up front:

- **Mutation score does not separate suites the reviewers rate as good from
  bad.** Then it is the wrong sensor for this codebase; keep coverage, drop
  the gate.
- **The refactor pass is discarded more than it is kept over twenty
  features.** The exit criterion is wrong or the model cannot do the step;
  either way, stop paying for it and say so.
- **The contract step does not reduce repair cycles.** Then blind oracles
  were not reconciling interfaces after all, and the contract is a design
  document like any other — keep it as prose, drop the compile gate.
- **`strict` costs more than 3× `standard` in tokens with no better gate
  yield.** Then this design reproduced the ritual it set out to replace, and
  the honest move is to say so in the README.

---

## Order of work

1. ~~The floor: `statement-frozen`, `oracle-frozen`, `evidence-clean`,
   `axioms`.~~ **Built.** `lib/statement.sh`, `lib/axioms.sh`, the guards,
   `test/floor.test.sh`, `test/axioms.test.sh`.
2. ~~The developer's orders and the developer test path.~~ **Built.**
3. The contract: **half built.** `contract.md` is part of the frozen statement,
   the tech-lead is told to write it, and the blind roles read it. The
   `contract-compiles` gate is not: the tech-lead writes no source, so
   compilable stubs would have to come from the developer's first attested
   step, and that ordering is not yet designed.
4. ~~`diff-coverage` and `mutation` extractors~~ **Built.** `lib/sensors.sh`:
   diff coverage from lcov (coverage.py, istanbul, cargo-llvm-cov, gcov2lcov
   all write it), mutation from Stryker, cargo-mutants, or the last number an
   attested run printed. Report lines by default; `ORCH_T_DIFF_COV` and
   `ORCH_T_MUTATION` make them gates. What they trust is stated in the file's
   header: the reports come from tools the developer runs.
5. The refactor pass, trigger and exit.
6. ~~`spec-coverage`~~ **built**; the read-back and the approval packet are not.
7. Holdout, only once the mutation and refactor numbers say the visible
   oracle is being overfit.
