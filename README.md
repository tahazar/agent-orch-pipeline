# orch

A multi-agent development pipeline for [Claude Code](https://claude.com/claude-code).

You describe a feature. A crew of named Claude sessions plans it, writes tests
for it, implements it, reviews it, and hands you a merge to approve — each in
its own terminal window, where you can watch the work happen and interrupt it.

Nothing merges without your approval. No agent can claim a test passed that
never ran. And you choose how much machinery each feature is worth, from one
session to six.

```bash
git clone https://github.com/tahazar/agent-orch-pipeline && cd agent-orch-pipeline
./install.sh ~/code/my-project
```

---

## Requirements

| | | |
|---|---|---|
| `git`, `jq` | required | `brew install jq` |
| `claude` | required | [claude.com/claude-code](https://claude.com/claude-code) |
| [`cmux`](https://github.com/manaflow-ai/cmux) | optional | without it, agents run headless and you cannot watch them |

macOS or Linux. Bash 3.2 is fine — nothing here needs a newer one.

## Install

```bash
./install.sh ~/code/my-project
```

This puts `orch` on your `PATH`, installs the six role definitions into your
project's `.claude/agents/`, and merges orch's hooks into
`.claude/settings.json` (backing up whatever was there first).

Then, once, in your shell profile:

```bash
export CLAUDE_CODE_TASK_LIST_ID=orch-my-project
```

Every agent in a run must share that value — it is the shared, file-locked task
list they coordinate through. Sessions with different values coordinate with
nobody, and they do it silently.

```bash
cd ~/code/my-project
orch doctor
```

`orch doctor` checks the whole install: the CLI version its facts were verified
against, whether the role definitions resolved, whether your sessions share a
permission mode, and whether cross-session messaging can actually reach them.
Start here whenever something behaves strangely.

## Layers

Not every repository wants all of this. A repo names the layers it uses in
`.claude/orch.json`; each depends only on the one below, and a command from a
layer that is off refuses with one line saying so.

| layer | what it is | needs |
|---|---|---|
| `floor` | attested evidence, frozen statement and oracle, escape-hatch count, sensors, the packet | git, jq, a test command. Always on |
| `crew` | tiers, blind roles, reviewers, auditor, refactor pass, read-back, holdout | the `claude` CLI |
| `upkeep` | a repo-wide census, overnight refactor passes, a morning to keep or discard them | the `claude` CLI |
| `product` | personas, stories, the chain to a feature, the walkthrough, the night and the morning | the `claude` CLI, and a product the walkthrough can run (`ORCH_PRODUCT_CMD`) |

```bash
orch init --profile library    # floor, crew          — the default when there is no file
orch init --profile service    # floor, crew, upkeep
orch init --profile product    # everything
orch layers                    # what this repo has on; orch doctor says what each needs
```

## Kickoff — the director drives

For a whole design, one command starts the run:

```bash
orch kickoff --request docs/specs/my-design.md    # or inline text
```

The request is frozen, and the `director` wakes with orders: decompose the
design into features, then drive each one — spawning the tech-lead, crewing up
at the confirmed tier, running the gates. Every spawned agent wakes already
pointed at its work; nobody sits at an empty prompt.

You are needed exactly where the gates name you:

```bash
orch tier confirm <F>              # each feature's cost, before any crew
orch approve <F> --gate human      # each merge
```

Everything below is the same machinery driven by hand — useful for a single
feature, or when you want each step under your fingers.

## Your first feature, step by step

**1. Start the run.** This opens two sessions that live for the whole run: the
`director`, which owns coordination and the merge, and the `auditor`, which
reviews at every gate.

```bash
orch team start
```

**2. Say what you want built.** The request is frozen at this point — editing
your spec afterwards cannot silently change what the crew was asked for.

```bash
orch feature start F001-csv-parser --request "Parse the CSV export. Tolerate a
  BOM in the header row, and reject rows with the wrong column count instead of
  padding them."
```

Or point at a file, if you have written one:

```bash
orch feature start F001-csv-parser --request docs/specs/csv-parser.md
```

That also checks out `feature/F001-csv-parser`. Your working branch is left
alone.

**3. Agree on how much machinery it needs.** The `tech-lead` reads the request,
writes `requirements.md`, and proposes a tier — that command is *its* job, not
yours. Nothing is spawned until you answer:

```bash
orch tier show F001-csv-parser      # what it proposed, and why
orch tier confirm F001-csv-parser   # accept
```

Override it whenever you disagree:

```bash
orch tier confirm F001-csv-parser --tier strict
```

If you already know, skip the negotiation with `--tier` on step 2.

**4. Let it work.**

```bash
orch team start --feature F001-csv-parser   # spawn the crew for that tier
orch watch                                  # follow along
```

The crew writes tests, implements against them, and reviews the diff. Review
findings are delivered to the developer verbatim, and every test result has to
come from a real command — see [Evidence](#evidence).

**5. Approve, then land.** Nothing reaches your base branch without this, and
it binds to the exact commit you approved. Read the packet first — the
request, whether the statement and the oracle held, which tests cite each
requirement, any escape hatch in the diff, the sensors, the evidence, and the
diff last:

```bash
orch packet F001-csv-parser
orch approve F001-csv-parser --gate human
orch merge F001-csv-parser --close     # the queue: integration run, then the base advances
```

You can run that from any terminal, including one with no session open. If the
branch moves afterwards, the approval is void and you will be asked again.

## Tiers

You choose what a feature costs. A one-line config change should not pay for a
six-agent crew.

| tier | crew | for |
|---|---|---|
| `quick` | tech-lead, developer | docs, config, renames, one-liners |
| `standard` | + code-reviewer | ordinary work with a clear oracle |
| `strict` | + test-engineer | real logic, or anything expensive to get wrong |

`strict` is full TDD: the `test-engineer` writes the tests from
`requirements.md` alone, before any implementation exists, and cannot read the
developer's work. The tests describe what was asked for rather than what was
built.

`director` and `auditor` are not in the table because they run for the whole
session, not per feature.

Pick up front if you already know:

```bash
orch feature start F002-typo --request "fix the typo in the README heading" --tier quick
```

## What it does to your git

One branch and one worktree per feature: `feature/<id>` checked out under
`.orch/worktrees/<id>/main`, created when you start it. Your checkout is never
touched. Features run in parallel, each crew in its own tree, and every
`orch` command that names a feature reads that feature's tree — its HEAD, its
evidence, its gates — not your checkout's.

```bash
orch feature start F002-export --request "..." --after F001-csv-parser
orch waves                       # the graph: landed, running, ready, blocked
orch waves next --start          # crew everything whose dependencies have landed
```

Nothing reaches the base branch except through the merge queue. `orch merge
<F>` checks the human approval at the feature's HEAD, the frozen statement and
oracle, and the holdout if there is one; then, under a lock, squash-merges
onto an integration worktree, runs the build and test commands on the merged
result, and advances the base only if that is green. Two features that each
passed alone can fail together, and when they do the base does not move.

Best-of-N, the refactor pass, the holdout run and every upkeep pass each get
their own worktree under the feature's, so parallel attempts cannot see or
overwrite each other.

Nothing rebases and nothing force-pushes — those are denied outright. A bad
merge is reverted, not rewritten. `--here` on `feature start` keeps the old
one-feature-at-a-time behaviour of checking the branch out in place.

## When orch overrules you

A tier is a floor, not a ceiling. Six mechanical signals watch the run —
compaction, context pressure, repeated steps, tool failure rate, test
oscillation, edit churn — and if the work is going badly the crew grows whether
or not you asked:

```
quick ──▶ standard ──▶ strict ──▶ best-of-N ──▶ diagnose ──▶ human
└──── you choose ────┘           └──── the signals decide ────┘
```

None of the six costs a model call. Past `strict` the ladder reaches
configurations you cannot request, because they answer a run going wrong rather
than a job being big:

- **best-of-N** — N developers solve the same requirements in isolated
  worktrees, each seeded with a different approach. Selection is mechanical and
  happens before any model judgement: candidates failing a gate are discarded,
  survivors ranked on attested numbers. One merges; all N are archived.
- **diagnose** — K read-only agents each get a different starting hypothesis and
  must return a falsifiable prediction *and the command that tests it*. `orch`
  runs all K. One holds, it directs the repair. None or two hold, you get it.
- **human** — reached when no distinguishing experiment can be constructed. Not
  when a retry counter runs out.

```bash
orch health signals F001-csv-parser   # what is firing
orch escalate check F001-csv-parser   # act on it
```

## The agents

```
director            owns the run, the merge, the human gate
│
├─ tech-lead        owns ONE feature: the plan and the tier
│  │
│  ├─ test-engineer writes failing tests from requirements alone
│  ├─ developer     makes them pass; cannot edit tests
│  └─ code-reviewer ×3 lenses, fresh context, sees only the diff; one lens runs opus
│
└─ auditor          adversarial approval — spawned fresh for each gate
```

Boundaries are enforced by hooks that exit 2, not by prompts asking nicely:

| boundary | mechanism |
|---|---|
| no merge without approval for the current sha | `hooks/gate-guard.sh` |
| no stage completes on an unattested claim | `hooks/task-guard.sh` |
| the director cannot write source | `hooks/write-scope.sh` |
| the developer cannot edit the tests it must satisfy | `hooks/write-scope.sh` |
| the code-reviewer cannot read the task list | `hooks/task-scope.sh` |
| the code-reviewer and test-engineer read only the requirements and the contract | `hooks/artifact-scope.sh` |
| the test-engineer cannot read the developer's tasks | `hooks/task-scope.sh` |
| only the tech-lead writes the statement, and a frozen statement that moves blocks every gate | `hooks/write-scope.sh`, `hooks/task-guard.sh` |
| the tests that pass are the tests that failed, however an edit was made | `hooks/task-guard.sh` |
| no new skip, ignore, disabled lint or changed test config without a finding | `hooks/task-guard.sh` |
| every requirement id is cited by an oracle test before the red phase completes | `hooks/task-guard.sh` |
| the contract builds before the oracle is written, and the red phase builds after | `hooks/task-guard.sh` |
| the read-back session reads the tests and no artifact | `hooks/artifact-scope.sh` |
| the developer never reads, writes, or runs a command naming the holdout; no merge until it passes | `hooks/artifact-scope.sh`, `hooks/write-scope.sh`, `lib/evidence.sh`, `hooks/gate-guard.sh` |
| the base advances only through the queue, only when the merged result is green | `lib/merge.sh` |
| a feature is not crewed until every feature it depends on has landed | `lib/waves.sh` |
| reviewers can report, never act | `disallowedTools` |
| candidates cannot escape their worktree | `isolation: worktree` |

The two task-scope rules are what make the reviewers worth running. A reviewer
that has seen the author's reasoning is anchored to it, and a test written
against the implementation passes by construction.

## Evidence

No agent's claim about its own diligence counts for anything. The only way to
produce an evidence row is to run the command:

```bash
orch run --feature F001-csv-parser --label tests -- npm test
```

That records the exit code, duration, output hash, git sha, and whether the
tree was dirty. An approval citing a command with no entry is rejected
`EVIDENCE_UNATTESTED`; one citing a non-zero exit while claiming success is
rejected `EVIDENCE_CONTRADICTED`; one over uncommitted changes is rejected
`EVIDENCE_DIRTY`. None consumes a repair cycle — rejecting a false claim is
not the same event as failing an honest attempt.

Three more things are checked by hash rather than by anyone's word, and the
reasoning is in [`docs/VERIFICATION.md`](docs/VERIFICATION.md):

- **The statement is frozen.** `request.md` at feature start, `requirements.md`
  and `contract.md` at tier confirm. A frozen file that changes is
  `STATEMENT_MOVED` at every gate and at the merge, until the tech-lead
  re-freezes it with a reason — which voids the red phase, because tests
  written against the old statement do not describe the new one.
- **The oracle is frozen.** The test tree at the red-phase sha is hashed; the
  green gate refuses `ORACLE_MOVED` if the tree differs, whether the edit came
  through Edit, Bash, `orch run`, or another worktree. The developer's own
  tests go under `test/dev/` and are outside the oracle.
- **Escape hatches are counted.** `orch axioms` lists every new skip, ignore,
  disabled lint, or changed test config in the diff against the base. Each is
  a blocking finding; the gate holds until it is fixed or disputed.

```bash
orch statement check F001-csv-parser   # exit 6 if a frozen file changed
orch oracle check F001-csv-parser      # exit 7 if the test tree differs
orch axioms F001-csv-parser            # exit 1 on any new escape hatch
orch spec coverage F001-csv-parser     # which oracle tests cite each R-id
```

Two sensors read numbers the gates cannot compute from git alone. Both are
report lines until you set a threshold, and gates after:

```bash
orch run --feature F001-csv-parser --label coverage -- npm test -- --coverage
orch sensor coverage F001-csv-parser   # of the executable lines the diff touched, how many ran
orch sensor mutation F001-csv-parser   # from a Stryker or cargo-mutants report, or an attested run's score
export ORCH_T_DIFF_COV=100 ORCH_T_MUTATION=80   # now they hold the green gate
```

Line coverage says a line ran. Mutation score says a test would notice if it
were wrong. A suite with the first and not the second exercises the code and
asserts nothing about it, which is the suite an agent writes once it has seen
the implementation.

## Upkeep

The codebase improves while you sleep, on the same terms as everything else:
nothing is kept on a model's say-so.

```bash
orch upkeep scan               # the census: escape hatches, tests older than their source,
                               # churn on size, uncovered lines, TODOs — ranked, no model call
ORCH_TEST_CMD='npm test' orch upkeep night --top 3
                               # one refactor pass per file, each on a fresh developer in its
                               # own worktree, the existing suite frozen as the oracle
orch upkeep morning            # what held, with the numbers
orch upkeep keep F903-upkeep-src-parser-py       # merge it into the base
orch upkeep discard F904-upkeep-src-legacy-py --why "not worth the churn"
```

A pass lands on a branch, never on your checkout, and only if the refactor
exit held: tests green and clean at its head, oracle unchanged, no new escape
hatch, the diff no larger than the file was, any attested metric no worse. A
nightly re-run does not plan a file twice while its pass is open. An attested
per-file metric (`orch run --feature _orch --label upkeep-metrics -- <tool
printing "score path" lines>`) is read into the census when present.

The log half reads aggregates your own script prints — error clusters and
p95 latency, never raw logs — and the worst become features with requests
written from the numbers, crewed like any other:

```bash
orch run --feature _orch --label telemetry -- ./scripts/telemetry.sh   # "error <cluster> <count> [path]" / "latency <endpoint> <p95_ms> [path]"
orch upkeep telemetry --top 3 --start
```

## Product: personas, stories, the night, the morning

The persona chain is the verification chain one level up: a small frozen
statement at the top, everything below measured against it. You write the
top; nothing else may.

```
docs/product/personas/maya.md          # Maya, the weekly exporter
                                       evidence: observed          ← hypothesized | observed | measured
                                       sources: support tickets 2026-Q2
docs/product/stories/S001-export-week.md
                                       # S001 Export the week as CSV
                                       persona: maya
                                       tier: standard               (optional)
                                       after: S000                  (optional: the feature graph)
                                       metric: exports per user rises   (a hypothesis, for later)
```

```bash
orch product trace          # persona -> story -> feature -> state; a broken link or an orphan exits 1
orch product plan           # one feature per story: the request IS the story, the tier is the story's
orch product night          # plan, then crew every ready feature in parallel, up to ORCH_PRODUCT_BUDGET
orch product morning        # each feature: the walkthrough first, then the numbers, never the diff
orch product keep F001-export-week                          # your approval and the landing, in one verb
orch product iterate F002-schedule --note "weekly by default"   # amend the request; re-freeze; the crew re-reads
orch product discard F003-share --why "nobody shares on Monday" # archived, and the reason is written against the persona
orch product personas       # each persona, its stories, what the mornings taught it
```

Three things hold the chain honest:

- **Evidence status.** A persona nobody has observed is a hypothesis, and
  everything built for it is exploratory: the morning says so, and `keep`
  refuses it without `--exploratory`. Real behaviour is the persona's
  oracle; a persona you invented gets exploratory features until you meet
  one of its people.
- **Frozen by hash.** Personas and stories are frozen like the statement.
  An edit after the freeze is `PRODUCT_MOVED` (exit 9) and `plan` refuses
  until `orch product freeze --why "..."` records why. Discards are the
  input: the reason is written against the persona in the run ledger, and
  the file is yours to amend and re-freeze.
- **The walkthrough.** Before a story-backed feature can land, a fresh
  session is given the persona, the story and the running product, and
  nothing else: source, tests and every feature artifact are denied to it by
  the read guard. It tries to reach the goal as that person, counts its
  steps, records done or blocked at that sha, and files what stopped it as
  findings in the persona's voice. The merge checks the record, not the
  prose; the packet leads with it.

```bash
ORCH_PRODUCT_CMD='npm run dev' orch walkthrough start F001-export-week
orch walkthrough record F001-export-week --outcome done --steps 4 --minutes 3 --note "the button says Download"
```

A story-backed feature is any feature whose request carries a `Story: S00N`
line, so a feature you start by hand joins the chain by citing one. Upkeep
features do not need a story.

**The metrics loop** closes the chain from the other end. `docs/product/metrics.md`
defines what the product is measured by, frozen with the personas and
stories; a story's `metric:` line names one and a direction; readings are
aggregates your own script prints, attested. Once a feature is kept, the
loop says whether its hypothesis held.

```
docs/product/metrics.md
- exports_per_user: up — exports per weekly active user
- error_rate: down guardrail — 5xx per 1k requests; a breach while features land is a blocking finding
- p95_ms: down guardrail holdout — never shown to a crew, never a story's target; the human's number
```

```bash
orch run --feature _orch --label metrics -- ./scripts/metrics.sh    # prints "name value" lines; aggregates, never raw logs
orch product metrics        # readings, guardrails, each kept feature's hypothesis confirmed|refuted|unchanged, proposals
```

A confirmed hypothesis is evidence for the persona: the loop proposes
`evidence: measured` for a persona whose stories' hypotheses were confirmed
and none refuted. Proposed; the file is yours.

## Security

Three mechanisms, against four references: OWASP Top 10:2025, OWASP ASVS
5.0.0, the CWE Top 25, and the CIS AWS Foundations Benchmark 4.0.1. The
references are data under `lib/security/`, each file saying where it came
from and how it was verified.

**The sensor** reads what a scanner wrote. Run the scanner through `orch run`
so the run is attested, then read its SARIF; every scanner worth running
writes SARIF (semgrep, CodeQL, bandit, gosec, trivy, grype, checkov, tfsec).

```bash
orch run --feature F001 --label security-code -- semgrep --config auto --sarif -o .orch/sec/code.sarif .
orch sensor security F001 --class code --sarif .orch/sec/code.sarif
orch run --feature F001 --label security-deps -- trivy fs --format sarif -o .orch/sec/deps.sarif .
orch sensor security F001 --class deps --sarif .orch/sec/deps.sarif
orch run --feature F001 --label security-iac  -- checkov -d infra -o sarif --output-file-path .orch/sec
orch sensor security F001 --class iac --sarif .orch/sec/results_sarif.sarif
```

Results are scoped to the diff: a result on a line the diff touched is new,
the rest is pre-existing and counted separately. Each new result is mapped to
its CWE, the OWASP Top 10:2025 categories that CWE belongs to, whether it is
in the CWE Top 25, and for infrastructure a CIS AWS recommendation id, and it
becomes a finding raised by `security`: blocking when it is Top 25 or the
tool says error, major otherwise. `ORCH_T_SECURITY=0` makes any new finding
a gate failure; `ORCH_SECURITY_CLASSES="code deps"` makes a missing reading
at HEAD a gate failure.

**The lens.** At strict, a `security` code-reviewer joins the ensemble. Its
orders begin with `orch security checklist`, which puts the ten OWASP
categories as questions with the ASVS chapters that answer each, the Top 25,
and the recurring CIS recommendations in front of it, and every finding it
raises cites a CWE id or an ASVS requirement id. The scanner finds what a
pattern finds; the lens is for missing authorization, a logic bypass, a trust
decision made on the client's word.

```bash
orch security checklist            # what the lens reviews against
orch security asvs V8.2            # ASVS requirements of a chapter, section, or id; or a word
orch security owasp CWE-89         # which categories map a CWE; whether it is Top 25
orch security cis 5.3              # CIS AWS recommendations by section or Prowler check
```

**The axioms.** `# nosec`, `# nosemgrep`, `checkov:skip`, `trivy:ignore`,
`NOSONAR` and `lgtm[...]` are escape hatches like `.skip`: an increase in the
diff is a blocking finding.

What orch does not do is pick the scanner or its rules. That is the
repository's call; orch attests that it ran, reads what it wrote, and holds
the diff to it.

## Performance

A benchmark number on its own is a claim about a machine. The sensor makes
it a claim about the diff: it checks the base out into a clean worktree,
runs the same command there and at HEAD, interleaved, N times, takes the
median of each side, and records the ratio with the base's own spread
beside it.

```bash
orch sensor perf F001 --runs 5 -- go test -bench . -run xxx ./...     # or hyperfine --export-json, pytest --benchmark-json, or lines of "name value"
ORCH_T_PERF=10 orch sensor perf F001 -- npm run bench                  # a gate: over 10% worse, outside the base's spread, is a perf finding
```

A regression smaller than the base's own spread is reported and not held
against the diff. A budget file, `.claude/orch-perf.json` with
`{"budgets": {"parse_1mb_ms": 15}}`, adds an absolute ceiling per benchmark
that is blocking whatever the base did. Lower is better unless the name
says otherwise (`ops`, `/s`, `throughput`, `qps`: `ORCH_PERF_HIGHER_RE`).

## Dead ends

What was tried and failed travels with the orders, not with a context
window. A developer that hits one records it with the attested run that
showed it; every developer spawned or recycled afterwards is told not to
retry it, verbatim, before it reads anything else.

```bash
orch decision record F001 --kind dead-end --text "cache the parsed header" \
  --why "the header is re-read per row; caching moved the cost, 31% slower" --evidence perf
orch decision deadends F001
```

## The read-back and the holdout

Two more things borrowed from how the FLT proof was checked. Both are optional.

**The read-back** is a natural-language rendering of what each oracle test
literally asserts, written by a session that is denied the requirements, so
it cannot read their meaning into the tests. The packet puts it beside the
requirements; the comparison is yours. It is bound to the oracle it describes
and shown as stale if the oracle changes.

```bash
orch readback start F001-csv-parser    # sonnet, low effort, sees only the tests
```

**The holdout** is the part of the oracle the developer never sees. The
test-engineer designates it before the red phase; it leaves the tree; the
developer is denied it by the read guard, the write guard and the executor;
it runs once, in a clean worktree at the approved sha, and a feature that has
one does not merge until it has passed. A failing holdout escalates to
best-of-N rather than opening a repair cycle, because a repair cycle would
make it visible.

```bash
orch holdout add F001-csv-parser test/test_edge.py     # test-engineer, before red
orch holdout run F001-csv-parser -- npm test           # director, at the gate
```

The boundary is stated in `lib/holdout.sh`: a developer that goes looking with
`orch run -- find` can find it. It is a discouragement with a ledger row, not
a secret.

## The refactor pass

Red-green-refactor's third step is where design comes from, and it is the one
an agent skips: it feels no duplication. So it is a separate pass, once per
feature, between the green gate and review:

```bash
orch refactor check F001-csv-parser    # always at strict; at standard on diff size or a metric
orch refactor start F001-csv-parser    # a fresh developer in its own worktree, design only
orch refactor finish F001-csv-parser   # kept (fast-forward) or discarded — mechanically
```

Kept only if the tests are green and clean at the refactor head, the oracle is
untouched, no escape hatch appeared, the refactor's diff is no larger than the
feature's was, and every metric attested before is attested after and no
worse. Otherwise the pre-refactor commit stands and the reason is on the
ledger. There is no repair loop on a refactor.

## Watching, and stepping in

```bash
orch team status              # who is alive, and where
orch peek developer           # read an agent's screen as text
orch status show F001-…       # status.md, generated from the ledger — never authored
orch team recycle developer   # fresh context after a compaction; state lives on disk
orch watch                    # live state; no terminal UI needed
orch report                   # cost, critique uptake, gate yield
```

With cmux, every agent is a named workspace you can open and type into. Without
it agents run headless, and `orch watch` plus the artifacts under
`docs/features/**` tell you everything — all state is on disk, so this works
over SSH and from a phone.

If a session dies, nothing is lost. Agents are stateless relative to their
artifacts; respawn and it resumes from the recorded phase.

## Knowing what it cost

Every run records itself. `orch report` reads the ledger and the session
transcripts and tells you what actually happened:

```bash
orch report                    # per feature: cost, wall clock, tier
orch findings yield --all      # which review lenses are finding real defects
```

| what it tells you | why you want it |
|---|---|
| output tokens and wall clock, per feature and per tier | whether `strict` is earning its extra sessions |
| gate yield — how often each gate actually blocked something | a gate that never blocks is ceremony |
| critique uptake | whether review findings are being acted on or waved through |
| per-lens unique-find rate | which reviewers to keep |

Every number comes from a recorded event or a transcript. Nothing here asks a
model how much it spent, and where there is no data it says so rather than
printing a zero.

That is what makes the tuning knobs meaningful: the escalation thresholds in
`lib/health.sh` are all overridable, and the report is how you find out which
ones are set wrong for your codebase.

### Going further: the ablation

If you want to know not just what a run cost but whether the crew beat a single
agent on the same work, there is a controlled comparison. It attempts a feature
solo from the same `requirements.md`, in a throwaway worktree, and merges
nothing:

```bash
orch lab baseline F001-csv-parser -- npm test   # the solo attempt
orch lab ablation --all                         # the comparison
```

**This is off by default and stays off.** A control means doing each feature
twice, so it roughly doubles the bill — worth it when you are deciding how to
configure the pipeline, wasteful as a standing cost. `orch report` says nothing
about it unless you have run it.

If you do run it, run it on every feature rather than only the ones that
escalated, or `escalation_precision` has no denominator.

The reasoning behind the ladder, the tiers and the reviewer ensemble — and the
research each rests on — is in [`DESIGN.md`](DESIGN.md), along with the
standing rule that keeps this honest: **if a tier, a lens, or a gate shows no
unique yield after 20 features, delete it and say so.**

## Tests

```bash
bash test/run-all.sh
```

1160 assertions across twenty-one suites. No Claude session, no API key, no network.
Each suite builds a throwaway git repo and its own task-list root, so nothing
touches `~/.claude` and nothing is left behind.

The suite asserts the failure modes, not just the happy path: a merge blocked
without approval and unblocked with it; the same approval voided once the branch
tip moves; a claim citing a command that never ran, rejected; six concurrent
writers allocating task ids with no lost write; a candidate's commit not moving
the main checkout; two simultaneously-held diagnostic predictions escalating
instead of getting a tiebreak.

It proves the protocol and the CLI. It does not prove a model follows the
prompts — that is what a live run is for.

## Layout

```
bin/orch          the CLI
lib/
  substrate/      the coordination seam: task list, messaging, gates
  launcher/       the session seam: cmux, background, print
  tier.sh         what you chose        escalate.sh   what the evidence forces
  health.sh       the six signals       evidence.sh   attested execution
  findings.sh     review findings       candidates.sh best-of-N
  statement.sh    frozen statement, frozen oracle
  axioms.sh       escape hatches        spec.sh       requirement coverage
  sensors.sh      diff coverage, mutation score
  refactor.sh     the refactor pass: trigger, invariant, exit
  packet.sh       the approval packet: statement first, diff last
  readback.sh     what the tests literally assert, written blind
  holdout.sh      the part of the oracle the developer never sees
  layers.sh       which layers a repository has on
  upkeep.sh       the census, the night, the morning
  product.sh      personas, stories, the chain, the product night and morning
  walkthrough.sh  the persona walkthrough: the read-back at product level
  metrics.sh      the metrics loop: definitions, guardrails, the holdout metric, hypotheses measured
  security.sh     the security sensor (SARIF, diff-scoped, CWE/OWASP/CIS) and the lens's references
  perf.sh         the performance sensor: A/B against the base, interleaved, medians, budgets
  security/       OWASP Top 10:2025, ASVS 5.0.0, CWE Top 25, CIS AWS 4.0.1 as data
  merge.sh        the merge queue: lock, integration run, advance
  waves.sh        the feature dependency graph
  diagnose.sh     competing hypotheses  report.sh     cost and outcomes
agents/           six role definitions, ~3k tokens total
hooks/            the seven enforcement hooks
test/             run-all.sh
docs/PROVENANCE.md  every cited result, with its verification status
docs/VERIFICATION.md what the FLT formalization teaches this pipeline, and the gaps it exposes
docs/AGENT-TDD.md   TDD taken apart and rebuilt for an agent; what strict should become
```

State lives in three places: the **shared task list** (coordination),
**`SendMessage`** (notification only), and **`docs/features/`** (artifacts). A
message is never load-bearing — every state transition is a task-list mutation
plus an artifact write, which is what makes an ephemeral transport safe to rely
on.

## Troubleshooting

**An agent came up without its role.** `claude --agent` could not resolve the
name, and that failure is silent — you get a plain assistant with none of the
role's restrictions. `orch doctor` checks for it. Re-run `./install.sh`.

**Agents are not coordinating.** They do not share
`CLAUDE_CODE_TASK_LIST_ID`, or they are in different permission-mode classes. A
message across mismatched classes is held and then dropped after `dialogExpiry`,
so the symptom is silence rather than an error. `orch doctor` reports both.

**A merge was refused with `stale-sha`.** The branch moved after approval, so
the approval describes a diff that is not the one being merged. Re-review and
approve again. This does not consume a repair cycle.

**`orch peek` says it has no screen.** You are on the background launcher.
Install cmux, or read `orch watch` and `docs/features/` instead.

## Licence

[Apache-2.0](LICENSE).
