# Coordination layer

This layer is for coordinators only - `orch`, `principal`, and `lead`. Workers
do not receive it and should not be told its contents; they work inside a
feature and do not need session, git, or integration mechanics.

## Session modes

There are two modes, chosen by the developer at kickoff.

| Mode | Behaviour at the end |
|---|---|
| `normal` | Rebase base on `main`, then `gh pr create` against `main`. Never push to `main` directly - the developer reviews and merges the PR |
| `test` | No PR, no touching `main`. Report and stop with the work on the base branch, telling the developer the manual follow-up |

The mode is recorded in `session.md` at kickoff and **read from there on every
restart**. Never re-derive it from the conversation, and never silently fall
back to `normal` - a test-mode run that opens a PR is a real incident.

## Git strategy

### Base branch capture (do this first, at kickoff)

```bash
git rev-parse --abbrev-ref HEAD
```

**Whatever this returns at kickoff IS the integration branch.** Record it in
`session.md`. Every later git step uses the recorded value.

- If it returns `main` or `master` - the PR target - **STOP and ask the
  developer to check out a working branch.** Do not proceed, and do not pick a
  branch name yourself.
- Never hardcode a branch name anywhere. Read it from `session.md`.

### Feature branches

- One branch per feature: `feature/<F00N-slug>`, branched off the recorded base.
- The feature identifier is the same string everywhere: folder name, branch
  name, and `feature=` signal value.
- On completion, orch **squash-merges into the base branch** with a
  conventional-commits message, then deletes nothing (branches stay for
  forensics).

### Merging the reviewed commit, not the branch

When GATE 2 approves a feature, principal's `work-review.md` records the exact
commit SHA it reviewed. Orch merges **that SHA**:

```bash
git merge --squash <reviewed-sha>
```

Never `git merge --squash feature/X`. Between validating the header and running
the merge, the branch can move; merging the branch name would ship whatever
landed in that window, unreviewed. That window is precisely what the evidence
header exists to close.

Record the resulting merge commit SHA in `feature-state.json` before moving on.

### Write-ahead state

**Record the intent before performing the action, not after.**

A crash between "merged" and "wrote it down" leaves state claiming the merge
never happened, and a resumed run merges a second time. So:

1. Write the intent (`state: MERGING, target_sha: <sha>`) and flush.
2. Perform the action.
3. Write the outcome (`state: DONE, merge_sha: <sha>`).

On resume, if state says `MERGING`, check the repository before acting: if the
base branch already contains that work, record the outcome and move on. **Every
effect must be idempotent on retry** - merges, branch creation, worktree
creation, symlink repointing.

### Rollback

If a feature already merged into base is later found broken - typically at the
final gate - do not patch it silently and do not rewrite history:

```bash
git revert -m 1 <merge-sha>      # or: git revert <squash-commit-sha>
```

Record the revert and the reason in `design-decisions.md`, then re-run the
feature as new work. Rewriting a merged squash commit invalidates every review
artifact that points at it.

### Parallel groups and worktrees

Parallel execution is the exception, and it must be *proven*, not assumed. See
the decomposition rules below for when a group is allowed at all.

When a group is approved:

- Create a git worktree per feature at `<repo-root>/.worktrees/<F00N-slug>`,
  with branch `feature/<F00N-slug>`.
- Include `worktree=<path>` in the `FEATURE_START` signal.
- **ALL code work happens inside the worktree.** Agents prefix commands with
  `cd <worktree> && ...`. Spawned panes start in the *shared checkout*, so an
  unprefixed command runs in the WRONG tree. This is a real, observed failure:
  the symptom is commits appearing on the shared checkout's branch and a
  feature branch that looks empty.
- **Coordination files stay at the shared checkout's
  `docs/features/current/`** - never inside a worktree. Only code lives in the
  worktree.
- Worker aliases are suffixed per feature: `lead-F002-parser`, `impl-F002-parser`.
- **A contract change serializes the whole group.** Park the group, apply the
  contract on base, then resume.
- **Route every incoming signal by its `feature=` value**, never by what you
  last sent. With two features in flight, "the reply to my last message" is not
  a thing.
- **A group must fully merge before the next serial feature starts.**

When in doubt, do not group. A serial run that takes longer is not a failure; a
parallel run with an interface race is.

### Coordination docs are committed by orch

Feature work commits code on the feature branch. The coordination documents live
in the shared checkout and would otherwise sit uncommitted forever, leaving no
record of the reviews that gated a merge.

**Orch commits `docs/features/**` on the base branch at each transition** -
after the decomposition is approved, after each plan approval, after each work
review, and at integration. Nobody else commits those files.

## Feature state machine

Orch maintains `feature-state.json`. Each feature is in exactly one state:

```
PLANNING -> PLAN_GATE -> DEV_APPROVAL -> EXECUTING -> WORK_GATE -> MERGING -> DONE
                 |             |              |            |
                 +-------------+--------------+------------+--> PARKED
```

| State | Meaning | Legal incoming signals |
|---|---|---|
| `PLANNING` | Lead is writing the plan | `PLAN_READY`, `BLOCKED`, `DESIGN_DEVIATION`, `FEATURE_STUCK` |
| `PLAN_GATE` | Principal is reviewing the plan | `APPROVED feature=X`, `REJECTED feature=X` |
| `DEV_APPROVAL` | Waiting on the developer | developer input only |
| `EXECUTING` | The team is doing the work | `FEATURE_COMPLETE`, `BLOCKED`, `DESIGN_DEVIATION`, `FEATURE_STUCK` |
| `WORK_GATE` | Principal is spot-checking | `WORK_APPROVED feature=X`, `WORK_REJECTED feature=X` |
| `MERGING` | Orch is merging the reviewed SHA | none (orch-internal) |
| `DONE` | Merged into base | none |
| `PARKED` | Halted, awaiting the developer | `FEATURE_RESUME` |

**A signal that is not legal for the feature's current state is a protocol
violation.** Log it (append to `status.md` and note it in your next report) and
**do not act on it**. A stale `WORK_APPROVED` arriving for a feature that has
gone back to `PLANNING` must not merge anything.

## Circuit breakers

`feature-state.json` carries per-feature counters and budgets:

| Counter | Cap | On breach |
|---|---|---|
| plan gate cycles | 2 | Escalate to the developer |
| spot-check cycles | 2 | Escalate to the developer |
| test audit cycles | 2 | `FEATURE_STUCK` |
| test dispute cycles | 2 | `FEATURE_STUCK` |
| implementation review cycles | 3 | `FEATURE_STUCK` |
| messages per feature | 200 (default) | `FEATURE_STUCK` - something is looping |
| estimated tokens per feature | developer-set, if any | `FEATURE_STUCK` |

Playbook caps are per-cycle and cannot catch a feature that ping-pongs between
`BLOCKED` and re-planning while staying under every individual cap. The message
and token budgets are the backstop. When a budget trips, park the feature and
hand the decision to the developer - never quietly keep going.

**An invalid evidence header does NOT count against the spot-check cycles.** It
is a process failure, not a review cycle.

## Design drift and the decision log

When work reveals that the design is wrong or incomplete, the lead signals
`DESIGN_DEVIATION reason="..."`. Orch then:

1. **Asks the developer.** Never guess on ambiguity or on an architectural
   decision.
2. Records the approved divergence in `design-decisions.md` (append-only:
   timestamp, feature, what the design said, what we are doing instead, who
   approved it).
3. Updates the affected `requirements.md` files so downstream features see the
   new truth.

A finding at the final review that **the design itself is wrong** routes through
this same path - it is a design decision for the developer, not a code fix to
paper over.

## Status surface

`docs/features/current/status.md` is the developer's single file for "where is
everything". Orch rewrites it at **every** transition. It must always answer:

- What mode and base branch is this session on?
- Which feature is active, and what state is it in?
- What is the developer being asked for right now, if anything?
- Which features are done, which are parked, and why?
- Any protocol violations, dropped signals, or dead-lettered messages so far?

Per-feature `status.md` is the lead's equivalent for its own feature, and is the
anchor a respawned lead reads to resume.

Write it atomically (temp file, then move). Keep it short enough to read at a
glance - it is a dashboard, not a log.
