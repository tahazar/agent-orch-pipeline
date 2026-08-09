# Playbook: `direct`

**When:** documentation, configuration, a rename, a one-line change - work with
no logic to get wrong and nothing meaningful to test.

**Workers:** none. The foreman does the work itself.

**Review depth:** BLOCKING-only skim.

## Why no workers

Spawning a three-agent team to change a config value costs more than it
protects. The tier exists so that trivial work stays trivial.

It is also the tier most often chosen dishonestly. If the change has *any*
branching, state, parsing, or error handling in it, it is not `direct` - it is
at least `lite`. Arbiter reviews the tier choice specifically for this, and
the developer can override at the approval gate.

## Cycle

1. **Foreman** reads `requirements.md` and writes `plan.md` with
   `workflow: direct` and a one-line justification.
2. Plan goes through GATE 1b (arbiter) and developer approval as usual - the
   tier does not skip gates.
3. **Foreman** does the work on the feature branch, commits it.
4. **Foreman** skims its own diff for BLOCKING issues only: does it do what the
   requirements say, does it break anything else, is anything committed that
   should not be. Not style, not polish.
5. **Foreman** writes the feature's `status.md` and signals:

   ```bash
   pipeline tell conductor 'F001-readme-badge done: added the CI badge and the
   install section, no code paths touched. ~4k (est.) [SIGNAL:FEATURE_COMPLETE
   feature=F001-readme-badge]'
   ```

6. GATE 2 (arbiter spot-check) runs exactly as it does for every other tier.
   `direct` reduces the work, not the gates.

## If it turns out to be bigger than it looked

The moment the change grows a branch, a new dependency, or a behaviour you would
want a test for, stop and signal:

```bash
pipeline tell conductor 'F003-config: this needs argument validation and error paths, direct is not honest here. [SIGNAL:BLOCKED reason="tier too small: needs validation logic and error handling"]'
```

Then re-plan at the heavier tier and go back through the plan gate. Finishing
under-tiered work is worse than the round trip.
