# Verification

What the Fermat's Last Theorem formalization teaches this pipeline, and what it
does not. Every `[Pn]` resolves in [`PROVENANCE.md`](PROVENANCE.md), which
records what was actually read.

---

## The one-line version

In the FLT run, Claude wrote 13 million lines nobody will ever read, and the
result is trusted anyway — because **trust was moved entirely out of the proof
and into three small things**: a frozen statement, a checker that cannot be
argued with, and a mechanical list of the escape hatches that were forbidden.

That is the whole lesson. `orch` already has the shape of it. The gaps are the
places where the statement is still mutable, the checker is still bypassable,
and the escape hatches are still unlisted.

---

## What actually happened

The figures below are from the published repository [P36] unless marked
otherwise. The research post itself [P38] could not be fetched from this
environment; where a number comes only from secondary coverage it says so.

| | |
|---|---|
| wall clock | 11 days, "largely autonomously" (secondary) |
| output tokens | ~6 billion, one internal model (secondary) |
| Lean written | 13 million lines; 60,475 modules |
| intermediate theorems | 29,511 |
| declarations checked by the second kernel | 1,052,234 |
| human mathematical input | "occasional high-level instructions" about *priority*, not correctness (secondary) |

Four mechanisms did the work of making that trustworthy:

1. **The statement is small, separate, and frozen.** `Theorems/` holds
   statements; `P2M/Sol/` holds proofs. The theorem is one line. On the
   Prove2Me platform that coordinated the run, a statement is stored as a
   `sorry` placeholder and the solver's first rule is that its proof's type
   must "match the target's `formal_statement` exactly — same binders, same
   conclusion" [P37]. Solvers cannot modify statements. Published statements
   are immutable.

2. **The checker is external, mechanical, and the only arbiter.** The README's
   own words: the sources "were produced by AI agents building on human-written
   open-source Lean, with Lean as the arbiter, and are written to be checked
   rather than read ... where a name and a statement disagree the statement is
   what was proved." Prove2Me returns one of `ACCEPTED`, `SKETCH_ACCEPTED`,
   `CE`, `WA`, `SORRY`, `FAILED`, `ERROR` — a verdict, not an opinion.

3. **The escape hatches are enumerated and denied by the build.** The default
   build target fails unless the theorem "depends on axioms: [propext,
   Classical.choice, Quot.sound]" — exactly Lean's three, nothing added. No
   module contains `axiom`, `sorry`, `native_decide`, `unsafe`, `extern`,
   `implemented_by`, `partial def` or `#eval`. This is not a review checklist;
   it is `#print axioms` under `#guard_msgs`, and the build is red otherwise.

4. **The statement is checked against an independent reference, and the proof
   is replayed by an independent checker.** `leanprover/comparator` confirmed
   "the proved statement and every constant it mentions are identical" to a
   challenge file written only against stock Mathlib. Then `nanoda`, a second
   kernel in a different language, replayed the whole environment. Two
   verifiers, neither of which is the one the agents iterated against.

And one thing that failed first. Early multi-agent runs "collapsed because
agents accumulated too much local context, lost track of proved results, and
duplicated work across the dependency graph" (secondary). The fix was not a
better model. It was a **directed acyclic graph of statements as the shared
state**: an agent takes an open node, proves it, publishes; a parent
"auto-resolves to Proved once every imported lemma is proved" [P37]. No
summary step, no agent's word for it.

The trust model is stated in one sentence, and the caveat that follows it is
the honest part: "Nothing else in Mathlib needs to be trusted — the kernel
checks everything beneath the statement." And: "No tool verifies that each
intermediate theorem means what its name suggests; that is for reader
judgment."

---

## TDD is the same shape, and a much weaker instance

The analogy the FLT result invites — a test suite is to code what Lean is to a
proof — holds structurally and fails on strength. It is worth being exact
about which, because the gaps below fall out of the differences.

| | Lean kernel | a test suite |
|---|---|---|
| what it checks | every input, by construction | the inputs somebody wrote down |
| can the prover game it | no; the kernel is not consulted about tactics | yes; special-case the fixture, catch the exception, skip the test |
| who writes the statement | a human, from a source, checked word for word | an agent, from `requirements.md` |
| is the statement checked against a reference | yes, by comparator | no |
| cost of an unbounded retry loop | tokens | tokens, **and** drift toward whatever passes |
| trusted computing base | the kernel and the statement | the runner, the language, the deps, the environment, the statement |

The last two rows matter most. Lean can afford an agent that retries for eleven
days because every retry is judged by something that cannot be persuaded. A
test suite judging an agent's retries is a gradient toward passing the tests,
and frontier models follow it: on impossible-SWE-bench, where the tests
contradict the specification, models exploited the tests in up to 76% of
attempts [P40]. Anthropic's own reward-hacking countermeasures include hidden
tests that catch "solutions that only pass training cases" [P40]. The
verifier's weakness is not a footnote; it is the reason `orch` escalates on
`test_oscillation` instead of retrying.

So the analogy licenses exactly the FLT discipline, applied harder: because the
checker is weaker, the statement must be **more** frozen, the escape hatches
**more** carefully enumerated, and the replay **more** independent — not less.

---

## What orch already has

Most of the FLT shape is here, and it was here for reasons argued in
[`DESIGN.md`](../DESIGN.md) before this comparison was made. Recorded so the
gaps read as gaps and not as a rewrite.

| FLT / Prove2Me mechanism | `orch` |
|---|---|
| Lean is the arbiter; a claim is worth nothing | `orch run` is the only writer of `evidence.jsonl`; `EVIDENCE_UNATTESTED`, `EVIDENCE_CONTRADICTED` |
| statement and proof in separate files, written by different parties | `test-engineer` writes from `requirements.md` alone; `developer` cannot edit test paths at `strict` |
| a `sorry` placeholder must fail before it is filled | the red phase: `tests-fail-correctly` requires an attested non-zero exit |
| the DAG is the state; agents are stateless | the shared task list plus the ledger; `orch team recycle` on compaction |
| parent auto-resolves from children; no summary step | `blocks`/`blockedBy` auto-unblock; `status.md` rendered from the ledger, never authored |
| the solver reads "logged dead-ends" before retrying | `orch decision record`, partially — see gap 7 |
| the mission auditor reads *only* the Lean, never the intent | `code-reviewer` and `test-engineer` are denied the task list and all artifacts but the criteria |
| verdicts are one of seven enumerated statuses | gates are `met`/`open` at a sha, hooks exit 2 |
| a human sets priority, never verifies | the human confirms the tier and approves the merge — see "What not to copy" |

---

## The gaps

Each was checked against the source on this branch, not inferred from the
README. They are ordered by how much trust they buy per line of shell.

### 1. The statement is not frozen

**FLT:** the statement is immutable once published; the solver may not touch
it; the comparator proves the thing checked is the thing asked for.

**orch:** `requirements.md` is the statement. `hooks/write-scope.sh` gives the
`developer` `ALLOW='*'` with only test paths denied, so the developer may
rewrite `requirements.md` and `request.md` at any tier. The `test-engineer` is
allowed `docs/features/*`, so it may rewrite the requirements it is supposed to
be blind to. Nothing records a hash of either file when the tier is confirmed,
so a rewritten statement leaves no trace in the ledger.

**Mechanism:** at `orch tier confirm`, record `sha256(requirements.md)` and
`sha256(request.md)` as a `statement.frozen` ledger event. `write-scope.sh`
denies both files to every role but `tech-lead` and `director`. `task-guard.sh`
and `gate-guard.sh` recompute the hashes at every gate and block with
`STATEMENT_MOVED` if they differ — the same way a moved branch tip voids an
approval. A tech-lead that genuinely needs to amend the statement does it
through `orch decision record`, which re-freezes and voids the red-phase
attestation, because tests written against the old statement no longer
describe the new one.

Enforced by hooks; no model call. One afternoon.

### 2. The proof can edit the statement through the executor

**FLT:** the prover has no path to the statement file at all.

**orch:** the crew's Bash allowlist is narrow, but it contains `Bash(orch:*)`,
and `orch run --label x -- <cmd>` executes an arbitrary command. `write-scope.sh`
is a `PreToolUse` hook on `Edit|Write|NotebookEdit|MultiEdit`; it never sees a
shell. So `orch run -- sh -c 'echo > test/parser.test.js'` is permitted by the
allowlist, invisible to the write guard, and — because it goes through `orch
run` — **attested**. The tool that exists to make claims honest is the widest
hole in the write boundary.

**Mechanism:** the statement-identity check the comparator performs, done on
git trees. The red-phase attestation records `git rev-parse <sha>:<test-path>`
for every test path glob — the tree hash of the tests as they failed. The
`tests-pass` gate compares against the same tree hashes at HEAD and blocks
with `ORACLE_MOVED` on any difference. It does not matter how the tests were
edited, by which tool, or in which worktree: the tests that pass must be the
tests that failed. At `quick` and `standard`, where the developer authors its
own tests, the check is informational and the report counts it.

This also closes the case the current `--fresh` check misses: a green run
attested at HEAD's sha with **uncommitted** changes in the working tree. An
evidence row should carry `dirty: true` when `git status --porcelain` is
non-empty, and `evidence verify --fresh` should reject it with
`EVIDENCE_DIRTY`. Git tracks the sha; it does not track what was lying next to
it.

Enforced by hooks over `git rev-parse`; no model call. Small.

### 3. The escape hatches are not enumerated

**FLT:** `FinalCheck.lean` lists the ways a Lean proof can lie — `sorry`,
`axiom`, `native_decide`, `unsafe`, `extern`, `implemented_by`, `partial def`
— and the build fails if any appears. Note the shape: the list is short, it is
mechanical, and it is checked by the build rather than by a reviewer.

**orch:** nothing equivalent. A developer can make a suite green with
`it.skip`, `.only`, `@pytest.mark.xfail`, `# type: ignore`, `eslint-disable`,
`expect(true).toBe(true)`, a `try/except: pass` around the assertion, an
`if os.environ.get("CI")` branch, a widened timeout, a regenerated snapshot,
or one edit to the test command in `package.json`. Each is a `sorry` with a
different spelling. The `reproduction` review lens might catch some, at the
cost of a model call and with the yield of any single reviewer — 20 to 32
percent [P8].

**Mechanism:** `orch axioms <feature>` — a diff scan, run inside the
`tests-pass` gate, over a short per-language list of escape-hatch patterns
plus a per-repo `ORCH_AXIOMS` override. It counts occurrences in the base
and in HEAD; **any increase is a blocking finding** raised by `axioms`, which
the developer must fix or dispute like any other. Config paths — CI files, test
runner config, lint config, snapshot directories, the test script in the
package manifest — are treated as axioms wholesale: at `strict` they are
denied to the developer by `write-scope.sh`, and at every tier a change to
them is listed first in the approval packet (gap 5).

Buzzard's own audit of the FLT repository was this check by hand: he asked an
agent "to flag every line of the repository that was not a definition or a
proof"; about a hundred lines came back, and he read them [P41]. A hundred
lines out of thirteen million is what an enumerated trust base buys.

Mechanical; no model call. Small, and the pattern list will need tuning per
codebase — the report should count how often `axioms` blocks, so a list that
never fires can be deleted like any other gate.

### 4. The red phase does not have to compile

**FLT:** a statement with `sorry` compiles. A reduction sketch that imports
child lemmas is itself type-checked before it is `SKETCH_ACCEPTED`. The
skeleton is verified before the holes are filled.

**orch:** `tests-fail-correctly` requires only a non-zero exit. The
`test-engineer` role definition asks in prose that the failure be "because the
behaviour is missing, not because of an import error, a typo in a fixture, or
a missing file" — and nothing checks. A suite that fails to import is
indistinguishable, to the gate, from a suite that asserts the right thing.
It also stays indistinguishable afterwards: when the developer's first commit
makes the import resolve, the same suite may go green having asserted nothing.

**Mechanism:** the red-phase attestation must show the tests *ran*. The
cheapest general form: `orch run --label tests-red` records the runner's
collected/ran/failed counts from a per-runner extractor (pytest, jest, go
test, cargo test each print them), and the gate requires `ran > 0` and
`failed > 0`. Where the project has a build or typecheck step, the red phase
additionally requires `build` attested green at the red-phase sha — which
pushes the tech-lead toward leaving compilable stubs, the `sorry`
placeholder's real analogue.

Mechanical; per-runner extractors are the cost. Medium.

### 5. The human is handed the proof, not the statement

**FLT:** the reviewer reads `Thm_fermat_last_theorem.lean` (one line),
`PROOF-PATH.md`, the axiom list, and the comparator verdict. Nobody reads the
proof. Prove2Me goes further: before a statement is published, a **read-back**
is attached — "a natural-language rendering of what a Lean 4 declaration
*literally asserts*", written by an independent agent that "receives *only*
the Lean code ... never the informal statement, mission pitch, or author's
intent", because "an auditor who knows what the code is 'supposed to say' will
read that meaning into it" [P37]. The human compares read-back to source.
"Omitting a hypothesis is the worst failure mode."

**orch:** `orch approve <F> --gate human` sets a gate. It shows the human
nothing. What the human will look at is whatever is in the terminal, which is
usually the diff — the proof — and the largest, least informative artifact on
the table.

**Mechanism:** `orch approve` without `--yes` prints an **approval packet** and
asks. In order:

1. `request.md`, verbatim — what was asked.
2. The read-back: a fresh `sonnet` session given the test files and nothing
   else, told to state in plain language what each test literally asserts,
   including what would satisfy it vacuously. It is denied `requirements.md`
   and `request.md`. It is the Prove2Me auditor, and it is the one new model
   call in this document; it is cheap, it runs once per gate, and it is the
   only place the "does the test mean what the requirement says" question
   gets asked by something that has not seen the answer.
3. `requirements.md` beside it, each requirement tagged with the tests that
   cite it (gap 6) or **UNCOVERED**.
4. The axiom delta (gap 3) and every changed line outside source and test
   paths.
5. The evidence rows for the gate, with `dirty`, sha and oracle-tree hashes.
6. The diff stat, last.

The human should be able to approve most features without opening the diff.
That is the goal, and the measure of whether the packet is right.

### 6. Nothing ties a test to a requirement

**FLT:** in Prove2Me, "linking is attestation": a captain attaching a theorem
to a milestone declares it faithful to the source, and only the captain may.
Faithfulness is "the single most important thing".

**orch:** `requirements.md` and the test suite are two documents with no
mechanical relationship. A requirement with no test is invisible. The
`tech-lead` role already asks that each requirement be "testable by someone
who cannot see your reasoning"; nothing checks that someone did.

**Mechanism:** requirements carry ids (`R1`, `R2`, …), which the tech-lead
already produces in practice. A test cites one in its name or a comment. `orch
spec coverage <F>` greps the test paths for `R\d+` and prints, per requirement,
the citing tests. An uncovered requirement at the review gate is a `blocking`
finding raised by `coverage`, against `requirements.md:<line>`. The
`test-engineer` disputes it by naming the ambiguity, which is what the role
definition already tells it to do — and now the dispute lands in the same
channel as every other finding.

Mechanical; one grep. Small. The rule it enforces is weaker than the
comparator's — citation is not fidelity — which is why the read-back in gap 5
exists alongside it.

### 7. Dead ends are not recorded for the next context

**FLT:** the solver's checklist begins with "read the mission's discussion for
strategies and logged dead-ends", checks failed submissions on the target, and
is told "do NOT retry an approach the captain already rejected" [P37]. This is
what made agents stateless relative to the DAG survivable: what was tried is
on disk, not in a context window.

**orch:** `orch team recycle` respawns a fresh context from the ledger, and the
ledger carries decisions, gates and evidence. It does not carry the developer's
failed approaches. A recycled developer reads `requirements.md` and `tasks.md`
and begins, quite possibly, with the approach that failed an hour ago. The
`step_repetition` signal will eventually notice. It would be cheaper not to
need it.

**Mechanism:** `orch decision record` grows a `--kind dead-end` flag. Dead-ends
are rendered into the developer's orders on spawn and recycle, verbatim, the
way findings are: "these were tried and failed, with the attested run that
showed it." Tiny.

### 8. Held-out tests, at `strict` and above

**FLT:** the comparator's challenge file and the second kernel are checks the
agents never iterated against. Anthropic's reward-hacking defences use hidden
tests for the same reason [P40].

**orch:** every test the developer must pass is visible to the developer.
Visible tests are a specification the developer can read *and* an oracle it
can overfit; there is no held-out set.

**Mechanism:** at `strict`, the test-engineer partitions its suite: most tests
into the test paths, a designated minority into
`docs/features/<F>/holdout/`. `artifact-scope.sh` denies that directory to the
`developer` (today the developer may read anything in its own feature
directory). At the review gate the director copies the holdout in and runs it
via `orch run --label holdout` in a clean worktree at the approved sha. A
holdout failure does not open a repair cycle against the holdout tests — that
would just make them visible — it escalates to rung 3, best-of-N, where the
selection ranks on the holdout result.

This is the strongest anti-overfitting control available and the most
expensive: it costs a partition rule and a second gate run, and it can fail on
interface mismatches the developer never saw. `design.md` naming the public
interface is the mitigation, and the `orch report` line that decides whether
it stays is *holdout unique catches* — a holdout that never fails where the
visible suite passed is ceremony, and should be deleted like any other gate
that never blocks.

---

## What not to copy

**Unbounded retries.** The FLT run could spend six billion tokens in a loop
because every iteration was judged by a sound checker. `orch` has no sound
checker. Copying the loop without the kernel is how a pipeline overfits its
tests at scale. The ladder's response to a repeated failure is to change the
configuration — a blind reviewer, N candidates, K hypotheses — not to retry,
and that stays.

**Taking the human out of verification.** The FLT human set priorities and
read nothing. That is correct when the verifier is sound and wrong when it is
not. The human gate stays; what changes is what the human is handed (gap 5).
The measure of success is that the human reads the packet and not the diff,
not that the human stops reading.

**Thirteen million lines.** "Written to be checked rather than read" is a
choice available to a project whose checker is the kernel. A codebase is read
by the next agent and the next human, and code nobody can read is code nobody
can change. `diff_lines` stays a ranking axis for best-of-N.

**Agent-driven TDD as a design tool.** One analysis of Claude Code usage found
agent-led TDD cost "three to eight times more tokens without producing better
designs" than test-after [P39, secondary]. `strict` is not there to produce
better designs. It exists so that the tests describe what was asked and not
what was built, and `orch report` already prints what that costs per feature.
If `strict` shows no unique yield after twenty features, the standing rule
applies to it too.

---

## What would falsify this

- **`axioms` never blocks across twenty features.** The pattern list is wrong
  for this codebase, or the developers do not reach for escape hatches. Either
  way, delete it and say so.
- **The read-back never disagrees with `requirements.md`.** Then the tests
  are faithful without it, and it is one model call per gate for nothing.
- **The holdout never fails where the visible suite passed.** Overfitting is
  not happening at the rate that justifies a partition; remove the partition.
- **`ORACLE_MOVED` and `STATEMENT_MOVED` never fire.** Keep them anyway. They
  cost nothing, and a boundary that is never tested is not evidence that it
  is not needed — it is evidence that the roles are behaving, which is what
  the boundary is for. This is the one exception to the delete-on-no-yield
  rule, and it is the same exception `gate-guard.sh` already enjoys.

---

## Order of work

Gaps 1, 2 and 3 first: they are hooks over `sha256` and `git rev-parse`, they
cost no model calls, and together they turn "the tests that pass are the tests
that failed, against the statement that was frozen, with no new escape
hatches" from a hope into a property. Gap 5 next, because it changes what the
human does at the only point the human is in the loop. Gaps 4, 6 and 7 as they
come. Gap 8 only once `orch report` has enough features to say whether the
visible suite is being overfit at all.
