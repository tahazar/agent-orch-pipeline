# Playbook: `full-tdd`

**When:** a real feature with logic - anything with branching, state, parsing,
error handling, or a contract surface.

**Workers:** `prover` (opus) + `inspector` (sonnet) + `builder` (sonnet).

**Review depth:** full adversarial.

The prover gets the strongest model because its suite gates every downstream
implementation decision. A weak test suite silently lowers the bar for
everything that follows it.

## Separation of duties (hard)

- **builder NEVER edits tests or contracts.** If a test looks wrong, it signals
  `BLOCKED reason="test dispute: ..."`. It does not "fix" the test.
- **prover NEVER edits implementation code.** It writes tests from the
  requirements, not from the implementation.
- **inspector NEVER fixes anything.** It audits and reviews; the fix comes from
  whoever owns the code.

These are enforced in each worker's permissions as well as here. If a tool call
is denied, that is the protocol working - escalate, do not route around it.

## Cycle

```
prover writes failing tests
      -> inspector audits the TESTS        (AUDIT_FAIL -> prover fixes, max 2)
      -> builder makes them pass             (test dispute -> inspector re-audits, max 2)
      -> inspector reviews the IMPLEMENTATION (REVIEW_FAIL -> builder fixes, max 3)
      -> foreman signals FEATURE_COMPLETE
```

### 1. Spawn

```bash
pipeline spawn prover:opus:prover-F003-auth
pipeline spawn inspector:sonnet:inspector-F003-auth
pipeline spawn builder:sonnet:builder-F003-auth
```

Foreman sends each worker the feature id, the branch, the worktree path if any, and
the path to `requirements.md`.

### 2. Tests first

**prover** writes tests that encode the requirements - including every code
example copied verbatim into `requirements.md`. The tests must **fail** against
the current tree; a test that passes before any implementation exists is testing
nothing.

```bash
pipeline tell foreman-F003-auth 'Wrote 14 failing tests covering the token refresh paths and the three error cases from the design. All fail as expected. ~28k (est.) [SIGNAL:TESTS_READY]'
```

### 3. Audit the tests

**inspector** audits the tests *before any implementation exists*:

- Do they actually encode the requirements, including the verbatim examples?
- Do they fail for the right reason (a missing feature, not a typo or a bad
  import)?
- Are they testing behaviour, or are they testing an implementation the prover
  imagined?
- What requirement has no test at all?

Write the audit into `review.md` **before** signalling.

- Pass: `[SIGNAL:AUDIT_PASS]`
- Fail: `[SIGNAL:AUDIT_FAIL]` - prover fixes, inspector re-audits. **Max 2
  cycles**, then `FEATURE_STUCK`.

Implementation does not start until the audit passes. An unaudited suite is a
bar nobody checked.

### 4. Implement

**builder** makes the failing tests pass. It does not touch the tests. It does not
touch contracts.

If a test appears wrong:

```bash
pipeline tell foreman-F003-auth 'tests/auth.test.ts:212 asserts the refresh token rotates on every call, but requirements.md says it rotates only on expiry. [SIGNAL:BLOCKED reason="test dispute: auth.test.ts:212 contradicts requirements.md on rotation timing"]'
```

The foreman routes it to the **inspector**, which re-runs the audit on that specific
test and adjudicates. **Max 2 dispute cycles**, then `FEATURE_STUCK`. Impl never
resolves a dispute by editing the test.

When green:

```bash
pipeline tell foreman-F003-auth 'All 14 tests pass. Implemented in src/auth/refresh.ts; no test files or contracts touched. ~34k (est.) [SIGNAL:IMPL_COMPLETE]'
```

### 5. Review the implementation

**inspector** now reviews the code, not the tests:

- Does it pass for the right reasons, or does it special-case the assertions?
- What does it do on the inputs the tests do not cover?
- Error handling, resource cleanup, concurrency, boundaries.
- Does it match the requirements, including the verbatim examples?

Write findings into `review.md` **before** signalling.

- Pass: `[SIGNAL:REVIEW_PASS]`
- Fail: `[SIGNAL:REVIEW_FAIL]` - builder fixes, inspector re-reviews. **Max 3
  cycles**, then `FEATURE_STUCK`.

### 6. Complete

**Foreman** writes the feature's `status.md`, then:

```bash
pipeline tell conductor 'F003-auth complete: 14 tests green, audited and reviewed, no contract changes. ~74k (est.) total for the team. [SIGNAL:FEATURE_COMPLETE feature=F003-auth]'
```

GATE 2 (arbiter spot-check) follows. The foreman does not tear down the team
until conductor sends `KILL_WORKERS` - a rejected spot-check needs the same workers.

## Cap exhaustion

When any cap is hit, the foreman stops and escalates rather than trying again:

```bash
pipeline tell conductor 'F003-auth: builder and inspector disagree on the session-expiry semantics after 3 review cycles; the requirements are ambiguous on whether a refresh extends the absolute lifetime. [SIGNAL:FEATURE_STUCK feature=F003-auth cycles=3]'
```

The conductor parks the feature and asks the developer. Do not silently start a
fourth cycle.
