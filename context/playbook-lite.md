# Playbook: `lite`

**When:** a bug fix or a small, well-understood change - real code, but not a
feature's worth of new logic.

**Workers:** `builder` (writes a regression test, then the fix) + `inspector`.

**Review depth:** focused - the changed behaviour and its blast radius, not the
whole subsystem.

## The shape

`lite` differs from `full-tdd` in one way that matters: **builder writes the
regression test itself**, because for a bug fix the test is the reproduction and
splitting it from the fix wastes a round trip.

Everything else holds. In particular:

- The test must **fail before the fix and pass after it**. A regression test
  that passes on the unfixed code proves nothing, and the inspector's first job
  is to check exactly that.
- Impl still may not modify **contracts**. Contracts are conductor-owned.

## Cycle

1. **Foreman** spawns the team:

   ```bash
   pipeline spawn builder:sonnet:builder-F002-off-by-one
   pipeline spawn inspector:sonnet:inspector-F002-off-by-one
   ```

2. **Foreman -> builder**: the requirements, the plan, and the feature branch (plus
   the worktree path, if this feature is in a parallel group).

3. **builder** reproduces the bug with a failing test, then fixes it, then commits.
   It reports:

   ```bash
   pipeline tell foreman-F002-off-by-one 'Regression test added in
   tests/parser.test.ts (fails on the old code, passes now) and the off-by-one
   fixed in src/parser.ts:88. ~12k (est.) [SIGNAL:IMPL_COMPLETE]'
   ```

4. **Foreman -> inspector**: review the implementation.

5. **inspector** checks, in this order:
   - Does the regression test actually fail without the fix? Verify it; do not
     take builder's word for it.
   - Does the fix address the root cause, or only the symptom the test happens
     to catch?
   - What else touches this code path, and did the fix break any of it?

   It writes `review.md` **before** signalling (artifact-before-signal), then:

   ```bash
   pipeline tell foreman-F002-off-by-one 'Reviewed; the regression test is
   genuine and the fix is at the root cause. Findings in review.md. ~9k (est.)
   [SIGNAL:REVIEW_PASS]'
   ```

6. On `REVIEW_FAIL`, builder fixes and the inspector re-reviews. **Max 3
   implementation review cycles**, then `FEATURE_STUCK`.

7. **Foreman** signals `FEATURE_COMPLETE feature=X` to conductor, and GATE 2 runs.

## Escalation

- If the "small change" turns out to need new interfaces or touches more than a
  couple of modules: `BLOCKED reason="tier too small: ..."` and re-plan as
  `full-tdd`.
- If the fix requires a shared shape to change: `BLOCKED reason="need contract
  change: ..."` up the chain. Impl does not edit contracts.
