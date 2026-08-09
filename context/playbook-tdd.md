# Playbook: `full-tdd`

**When:** a real feature with logic - anything with branching, state, parsing,
error handling, or a contract surface.

**Workers:** `tdd-tester` (opus) + `tdd-reviewer` (sonnet) + `tdd-impl` (sonnet).

**Review depth:** full adversarial.

The tester gets the strongest model because its suite gates every downstream
implementation decision. A weak test suite silently lowers the bar for
everything that follows it.

## Separation of duties (hard)

- **impl NEVER edits tests or contracts.** If a test looks wrong, it signals
  `BLOCKED reason="test dispute: ..."`. It does not "fix" the test.
- **tester NEVER edits implementation code.** It writes tests from the
  requirements, not from the implementation.
- **reviewer NEVER fixes anything.** It audits and reviews; the fix comes from
  whoever owns the code.

These are enforced in each worker's permissions as well as here. If a tool call
is denied, that is the protocol working - escalate, do not route around it.

## Cycle

```
tester writes failing tests
      -> reviewer audits the TESTS        (AUDIT_FAIL -> tester fixes, max 2)
      -> impl makes them pass             (test dispute -> reviewer re-audits, max 2)
      -> reviewer reviews the IMPLEMENTATION (REVIEW_FAIL -> impl fixes, max 3)
      -> lead signals FEATURE_COMPLETE
```

### 1. Spawn

```bash
pipeline spawn tdd-tester:opus:tester-F003-auth
pipeline spawn tdd-reviewer:sonnet:reviewer-F003-auth
pipeline spawn tdd-impl:sonnet:impl-F003-auth
```

Lead sends each worker the feature id, the branch, the worktree path if any, and
the path to `requirements.md`.

### 2. Tests first

**tester** writes tests that encode the requirements - including every code
example copied verbatim into `requirements.md`. The tests must **fail** against
the current tree; a test that passes before any implementation exists is testing
nothing.

```bash
pipeline tell lead-F003-auth 'Wrote 14 failing tests covering the token refresh paths and the three error cases from the design. All fail as expected. ~28k (est.) [SIGNAL:TESTS_READY]'
```

### 3. Audit the tests

**reviewer** audits the tests *before any implementation exists*:

- Do they actually encode the requirements, including the verbatim examples?
- Do they fail for the right reason (a missing feature, not a typo or a bad
  import)?
- Are they testing behaviour, or are they testing an implementation the tester
  imagined?
- What requirement has no test at all?

Write the audit into `review.md` **before** signalling.

- Pass: `[SIGNAL:AUDIT_PASS]`
- Fail: `[SIGNAL:AUDIT_FAIL]` - tester fixes, reviewer re-audits. **Max 2
  cycles**, then `FEATURE_STUCK`.

Implementation does not start until the audit passes. An unaudited suite is a
bar nobody checked.

### 4. Implement

**impl** makes the failing tests pass. It does not touch the tests. It does not
touch contracts.

If a test appears wrong:

```bash
pipeline tell lead-F003-auth 'tests/auth.test.ts:212 asserts the refresh token rotates on every call, but requirements.md says it rotates only on expiry. [SIGNAL:BLOCKED reason="test dispute: auth.test.ts:212 contradicts requirements.md on rotation timing"]'
```

The lead routes it to the **reviewer**, which re-runs the audit on that specific
test and adjudicates. **Max 2 dispute cycles**, then `FEATURE_STUCK`. Impl never
resolves a dispute by editing the test.

When green:

```bash
pipeline tell lead-F003-auth 'All 14 tests pass. Implemented in src/auth/refresh.ts; no test files or contracts touched. ~34k (est.) [SIGNAL:IMPL_COMPLETE]'
```

### 5. Review the implementation

**reviewer** now reviews the code, not the tests:

- Does it pass for the right reasons, or does it special-case the assertions?
- What does it do on the inputs the tests do not cover?
- Error handling, resource cleanup, concurrency, boundaries.
- Does it match the requirements, including the verbatim examples?

Write findings into `review.md` **before** signalling.

- Pass: `[SIGNAL:REVIEW_PASS]`
- Fail: `[SIGNAL:REVIEW_FAIL]` - impl fixes, reviewer re-reviews. **Max 3
  cycles**, then `FEATURE_STUCK`.

### 6. Complete

**Lead** writes the feature's `status.md`, then:

```bash
pipeline tell orch 'F003-auth complete: 14 tests green, audited and reviewed, no contract changes. ~74k (est.) total for the team. [SIGNAL:FEATURE_COMPLETE feature=F003-auth]'
```

GATE 2 (principal spot-check) follows. The lead does not tear down the team
until orch sends `KILL_WORKERS` - a rejected spot-check needs the same workers.

## Cap exhaustion

When any cap is hit, the lead stops and escalates rather than trying again:

```bash
pipeline tell orch 'F003-auth: impl and reviewer disagree on the session-expiry semantics after 3 review cycles; the requirements are ambiguous on whether a refresh extends the absolute lifetime. [SIGNAL:FEATURE_STUCK feature=F003-auth cycles=3]'
```

Orch parks the feature and asks the developer. Do not silently start a fourth
cycle.
