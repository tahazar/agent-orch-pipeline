# `orch` protocol

Your phases run in order. On respawn, read `session.md` and `status.md` and
resume from the recorded phase - never redo completed work.

---

## PHASE 0 - kickoff

Triggered by the developer messaging you with the request (inline, or a path or
URL to a design doc) and optionally the words "test mode".

### 0.1 Capture the base branch

```bash
git rev-parse --abbrev-ref HEAD
```

**Whatever this returns IS the integration branch for this session.**

If it is `main` or `master`, stop here and reply to the developer:

> This session would integrate onto `main`, which is the PR target. Please check
> out a working branch (e.g. `git checkout -b feature/<name>`) and message me
> again - I have not created anything yet.

Do not pick a branch name for them. Do not proceed.

### 0.2 Create the session directory

```bash
mkdir -p docs/features/session-<ISO-date>-<slug>
ln -sfn session-<ISO-date>-<slug> docs/features/current
```

- `<ISO-date>` is `YYYY-MM-DD`; `<slug>` is a short kebab-case name from the
  request.
- **Prior sessions stay as siblings.** They are history. Never delete them.
- `ln -sfn` is idempotent - repointing an existing symlink is safe on resume.
- **All agents read and write through `docs/features/current/` from here on.**

### 0.3 Freeze the request

Write the developer's request to `request.md` **verbatim**. Not summarised, not
tidied, not reformatted. If they gave you a path or a URL, fetch or read it
**once** and freeze the content into `design.md`; later phases read the frozen
copy, never re-fetch.

If the design lives in the repo (typically `docs/specs/<name>.md`), copy it to
`design.md`. Never treat a file under `docs/features/` as an input design -
that tree is yours.

### 0.4 Write `session.md`

```markdown
# Session
- id: session-<ISO-date>-<slug>
- mode: normal | test
- base: <branch captured in 0.1>
- started: <ISO8601>
- pr-target: main

## Kickoff (verbatim)
<the developer's kickoff message, exactly as received>
```

Mode and base are read from this file on every restart, by you and by every
other coordinator. They are never re-derived.

### 0.5 Confirm

Tell the developer what you captured - mode, base branch, session path - and
that you are moving to decomposition. If anything about the request is
ambiguous, ask now, before you decompose.

---

## PHASE 1 - decompose, then GATE 1a

### 1.1 Decompose

Read `request.md` **and** `design.md`. Decompose into ordered features:

- Named `F001-<slug>`, `F002-<slug>`, ... zero-padded, **in implementation
  order**.
- **This prefixed name is THE identifier** - the folder name, the branch name
  (`feature/F001-auth`), and the `feature=` value in every signal. One string,
  everywhere.

Produce:

- `feature-order.md` - the ordered list, each with a one-line summary, its
  dependencies, and the files it is expected to own.
- `F00N-<slug>/requirements.md` for each feature - what it must do, its
  acceptance criteria, and **every relevant code example from the design copied
  VERBATIM**. Those examples are the contract with the developer; paraphrasing
  one is how a requirement quietly changes.
- Contracts, only if more than one feature must import a shared shape.

**This layout is mandatory even for a single feature.** No shortcuts for small
sessions - recovery, review, and the status surface all depend on it.

### 1.2 Parallel groups (optional, and rarely)

You may mark a pair of features as a parallel `group:` in `feature-order.md`
only if you can *prove*, in writing, for that specific pair:

- **Disjoint file ownership**, including configuration hotspots (a shared
  `package.json`, `settings`, a route table, an index file that both would edit).
- **No dependency edge** in either direction.
- **No expected contract change** from either feature.

Rules: **maximum 2 features per group**; a per-pair independence justification
recorded in `feature-order.md`; **when in doubt, do not group.**

Principal will reject an unproven parallel claim, and it should.

### 1.3 GATE 1a - principal reviews the decomposition

Write everything to disk first, then:

```bash
pipeline tell principal 'Decomposition ready for session <id>: 5 features, one proposed parallel group (F003/F004). Request is at docs/features/current/request.md, design at design.md, decomposition at feature-order.md. [SIGNAL:DECOMPOSITION_READY]'
```

Principal replies `APPROVED` or `REJECTED` with **no discriminator** - that is
how you know it is the decomposition verdict.

- On `REJECTED`: read `decomposition-review.md`, revise, resubmit.
- **Maximum 2 revision cycles.** If principal rejects a third time, stop and
  escalate to the developer with both positions summarised.

### 1.4 Developer approval

Present the decomposition to the developer: the ordered features, one line each,
any parallel group with its justification, and anything you had to interpret.
Ask for approval or changes.

### 1.5 Initialise the session status surface

Write `status.md` (the rollup) and `feature-state.json` (every feature in
`PLANNING`, all counters zero). Commit `docs/features/**` on the base branch.

---

## PHASE 2 - execute, one feature at a time

For each feature in order. **Only one feature team is alive at a time**, unless
this feature is in an approved parallel group.

### 2.1 Prepare the branch

Serial feature:

```bash
git checkout <base> && git checkout -b feature/F00N-<slug>
```

Parallel group - a worktree per feature:

```bash
git worktree add <repo-root>/.worktrees/F00N-<slug> -b feature/F00N-<slug> <base>
```

### 2.2 Spawn the lead and start it

```bash
pipeline spawn lead:opus:lead-F00N-<slug>      # suffix the alias only in a parallel group
pipeline tell lead-F00N-<slug> 'Start F00N-<slug>. Requirements at docs/features/current/F00N-<slug>/requirements.md, branch feature/F00N-<slug>, base <base>. [SIGNAL:FEATURE_START feature=F00N-<slug>]'
```

In a parallel group, include the worktree so the lead knows to prefix its
commands: `[SIGNAL:FEATURE_START feature=F00N-<slug> worktree=<abs-path>]`.

Set the feature's state to `PLANNING`.

### 2.3 GATE 1b - the plan and the tier

On `PLAN_READY feature=X`, move X to `PLAN_GATE` and forward it:

```bash
pipeline tell principal 'Plan ready for F00N-<slug>, tier <tier>. Plan at docs/features/current/F00N-<slug>/plan.md, requirements alongside it. [SIGNAL:PLAN_REVIEW_READY feature=F00N-<slug>]'
```

Principal replies `APPROVED feature=X` or `REJECTED feature=X`. **Route on the
discriminator, not on what you last sent.**

- `REJECTED`: send `PLAN_REJECTED feature=X` to the lead with the review path.
  Back to `PLANNING`. Max 2 plan-gate cycles, then escalate to the developer.
- `APPROVED`: move to `DEV_APPROVAL` and take it to the developer, including the
  tier and its justification. **The developer may override the tier** - if they
  do, tell the lead the new tier and have it re-plan against it.

Then:

```bash
pipeline tell lead-F00N-<slug> 'Plan approved by principal and the developer, tier stays <tier>. Proceed. [SIGNAL:PLAN_APPROVED feature=F00N-<slug>]'
```

Move to `EXECUTING`.

### 2.4 GATE 2 - the spot-check

On `FEATURE_COMPLETE feature=X`, move X to `WORK_GATE`:

```bash
pipeline tell principal 'F00N-<slug> reports complete on branch feature/F00N-<slug>. Spot-check it. [SIGNAL:WORK_REVIEW_READY feature=F00N-<slug>]'
```

Principal writes `work-review.md` and replies `WORK_APPROVED feature=X` or
`WORK_REJECTED feature=X`.

**On `WORK_APPROVED`, validate the evidence header before doing anything else.**

`work-review.md` must open with a header giving: the commit SHA reviewed, the
diff command run, the files read, and the tests run. Check:

1. Is the header present and complete? Any missing field invalidates it.
2. Does the SHA equal the current tip?

```bash
git rev-parse feature/F00N-<slug>
```

If the header is missing or incomplete, or the SHA does not match (the branch
moved after the review), **the approval is INVALID**:

- Do not merge.
- Re-request the gate, saying exactly what was wrong.
- **This does NOT count against the 2 spot-check cycles** - it is a process
  failure, not a review cycle.

On a valid approval:

```bash
pipeline tell lead-F00N-<slug> 'F00N-<slug> approved and merging. Tear down the team. [SIGNAL:KILL_WORKERS feature=F00N-<slug>]'
```

### 2.5 Merge

Write the intent first (`state: MERGING`, `target_sha: <reviewed-sha>`), then:

```bash
git checkout <base>
git merge --squash <reviewed-sha>
git commit -m "feat(F00N-<slug>): <summary>"
```

**Merge the reviewed SHA, never the branch name.** Between validating the header
and running the merge the branch could move, and merging the name would ship
that window unreviewed.

Then record the outcome (`state: DONE`, `merge_sha: <sha>`), rewrite `status.md`,
commit `docs/features/**`, kill the lead, and start the next feature.

In a parallel group: a group must **fully merge** before the next serial feature
starts, and a contract change **serializes the whole group** - park both
features, apply the contract on base, then resume.

---

## PHASE 3 - integration

After the last feature merges:

1. **Full test suite on the base branch.** If it fails, that is a finding, not a
   formality - park and investigate.
2. **Rebase base on the PR target**: `git fetch origin main && git rebase origin/main`.
3. **FINAL GATE:**

   ```bash
   pipeline tell principal 'All features merged onto <base> and rebased on main; suite green. Review the assembled system against request.md AND the full design. [SIGNAL:FINAL_REVIEW_READY]'
   ```

   Principal reviews against **both** `request.md` and `design.md` - the design
   itself may have dropped or misread the request, and requirements can fall
   between features. It writes `final-review.md` and replies `FINAL_APPROVED` or
   `FINAL_REJECTED`.

   A `FINAL_REJECTED` saying the *design* is wrong routes through
   `DESIGN_DEVIATION`, not through a code fix.

4. **Normal mode:**

   ```bash
   gh pr create --base main --head <base> --title "..." --body "..."
   ```

   Never push to `main`. The developer reviews and merges the PR.

   **Test mode:** no PR, no touching `main`. Report to the developer: what
   landed on the base branch, what the final review said, and the manual
   follow-up they need to do. Then stop.

5. Write `cost-report.md` covering all six roles. The **model column is
   authoritative from the spawn spec** - what each agent was actually spawned
   with - not from what an agent says about itself. The token column sums the
   `~Nk (est.)` self-reports from `costs.md`.

---

## Contracts

You own them exclusively.

1. A `BLOCKED reason="need contract change: ..."` reaches you from a lead.
2. You write the proposal to `contract-change-<n>.md`: what shape changes, why,
   which features are affected.
3. Gate it: `pipeline tell principal '... [SIGNAL:CONTRACT_REVIEW reason="..."]'`.
   Principal replies `APPROVED contract` or `REJECTED contract` - it will reject
   over-stuffing and unnecessary coupling.
4. Apply it **on the base branch, between features**. Never mid-feature, and
   never inside a worktree.
5. Update the affected `requirements.md` files, then resume.

## Design deviations

On `DESIGN_DEVIATION reason="..."` from a lead:

1. **Ask the developer.** Never guess on ambiguity or on an architectural
   decision.
2. Record the approved divergence in `design-decisions.md` (append-only).
3. Update the affected `requirements.md` files so later features see it.
4. Tell the lead what was decided.

## Handling the developer

The developer is a gated decision-maker, not a driver. They own: kickoff,
decomposition approval, per-feature plan approval (including tier overrides),
deadlock arbitration, and design deviations.

When you need them, say precisely what you need and what the options are. When
you do not, do not interrupt them - `status.md` is where they look.

On `STATUS_REQUEST`, report: mode, base, active feature and its state, what you
are waiting on, what is done, and anything anomalous (dropped signals, protocol
violations, dead-lettered messages).
