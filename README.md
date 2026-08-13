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

**5. Approve the merge.** Nothing reaches your base branch without this, and it
binds to the exact commit you approved:

```bash
orch approve F001-csv-parser --gate human
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

One branch per feature, `feature/<id>`, created when you start it. Work happens
there; your base branch is untouched until you approve a squash-merge of the
exact commit you reviewed.

Best-of-N (below) puts each candidate in its own git worktree under `.orch/`,
so parallel attempts cannot see or overwrite each other. Exactly one is merged
and the rest are archived with their gate results.

Nothing rebases and nothing force-pushes — those are denied outright. A bad
merge is reverted, not rewritten.

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
│  └─ code-reviewer fresh context, sees only the diff
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
| the code-reviewer and test-engineer read only the requirements | `hooks/artifact-scope.sh` |
| the test-engineer cannot read the developer's tasks | `hooks/task-scope.sh` |
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

That records the exit code, duration, output hash, and git sha. An approval
citing a command with no entry is rejected `EVIDENCE_UNATTESTED`; one citing a
non-zero exit while claiming success is rejected `EVIDENCE_CONTRADICTED`.
Neither consumes a repair cycle — rejecting a false claim is not the same event
as failing an honest attempt.

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

501 assertions across eleven suites. No Claude session, no API key, no network.
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
  diagnose.sh     competing hypotheses  report.sh     cost and outcomes
agents/           six role definitions, ~3k tokens total
hooks/            the six enforcement hooks
test/             run-all.sh
docs/PROVENANCE.md  every cited result, with its verification status
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
