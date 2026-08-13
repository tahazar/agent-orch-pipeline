# Provenance

Every design decision in this repository that rests on an outside result cites
it here by tag. The tags are referenced from `orch/`, from the v1 `pipeline`
prompts, and from the overhaul specification.

## Status of this file — read this first

**This file was reconstructed, and most of it is incomplete.**

The overhaul specification names `docs/PROVENANCE.md` as an existing companion
document and instructs §16 to *append* to it. No such file was present in this
repository at any commit; neither were the companion documents
`AUDIT-agent-orch-pipeline.md` and `UPGRADE-agent-orch-pipeline.md`. What
follows is therefore built from the claims as the specification states them,
not from the sources.

Consequently:

- **[P35] is first-hand.** It was verified empirically against the installed
  CLI on the date recorded below, by the commands shown. Every line of it can
  be re-run.
- **[P20] and [P9]** carry the bibliographic detail the specification supplies
  verbatim. They have not been checked against the papers.
- **Everything else is a claim with no citation.** The specification quotes
  figures for each; the figures are recorded here so the code that acts on them
  can be traced to *something*, and each is marked `CITATION MISSING`.

A `CITATION MISSING` entry is not evidence. It is a placeholder that says which
number a piece of this system was built on, so that the day someone checks it
and finds it wrong, they can find every place it leaked into the design. Do not
cite this file outward until the missing entries are restored from the
companion document or replaced with real sources.

If you are restoring this file: the tags below are load-bearing. `orch/` and
the v1 prompts reference them by number, and `orch/test/` does not check them.

---

## [P35] Claude Code substrate — verified first-hand

**Verified 2026-08-12 against `claude 2.1.228` (Claude Code)**, on Linux, by
inspecting the running process and the installed binary. This is the only entry
in this file that was not taken on trust, and it is the one most likely to rot:
these are internals, and §17 of the specification requires re-verification
before relying on them.

Confirmed present and behaving as described:

| Fact | How it was checked |
|---|---|
| Session registry at `~/.claude/sessions/<pid>.json`, mode 0644, carrying `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`, `version`, `peerProtocol`, `kind`, `entrypoint`, `messagingSocketPath`, `name`, `nameSource` | read the live file |
| Per-session key at `~/.claude/sessions/<pid>.<sha256>.key`, mode 0600 | `ls -l` |
| Per-session Unix socket at `/tmp/cc-socks/<pid>.sock`, mode `srw-------` | `ls -l /tmp/cc-socks` |
| `CLAUDE_CODE_MESSAGING_SOCKET` exported into the session environment | `env` |
| `claude agents --json` returns the roster without a TTY | ran it |
| Shared task list at `~/.claude/tasks/<id>/` with `N.json` per task **and a zero-byte `.lock`** | created a task, inspected the directory |
| Task `metadata` round-trips verbatim | created a task with metadata, read the file |
| `CLAUDE_CODE_TASK_LIST_ID` selects the directory | present in the binary's settings surface |
| `crossSessionInbound` accept/hold/refuse | present in the binary |
| `dialogExpiry` — enum `60s` / `5m` / `10m` / `never`, **default 5m**, governing "how long a HELD cross-session message awaits approval before it resolves to its safe no-action default (dropped-with-denial)" | the setting's own description string in the binary |
| `isolation: "worktree"` on agent definitions | present in the binary |
| `disallowedTools` on agent definitions | present in the binary |
| Hook events `PostToolUseFailure` ("Run after tool fails"), `PostCompact`, `TaskCompleted`, `TaskCreated`, `TeammateIdle` | the binary's hook-event table |
| `stop_hook_active` — "return success while it's true" | the binary's own guidance string |
| Agent teams gated behind `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | present in the binary |

**Two corrections to the specification's §1, found while verifying:**

1. **The declarative hook `if` field does not exist.** §6.2 calls for
   `"if": "Bash(git merge*)"` to pre-filter a hook without spawning a process.
   The settings validator in 2.1.228 states hooks "must be an object mapping
   event names to matcher arrays" carrying "hookCallbackIds arrays and string
   matchers", and no if-condition appears anywhere in the binary. `orch`
   narrows by `matcher` and does the command match inside the hook instead.
   Same correctness, one extra short-lived process per Bash call.

2. **The session roster does not report permission mode.** §1 requires every
   session in a team to share a permission-mode class, and `orch doctor` has to
   check it — but `claude agents --json` returns only
   `pid`/`cwd`/`kind`/`startedAt`/`sessionId`/`name`, and the session registry
   does not carry the mode either. `orch` recovers the class from the process
   arguments via `ps`, and reports `unknown` rather than guessing when it
   cannot: a wrong class would produce a confident all-clear for exactly the
   failure the check exists to catch.

Minor drift from the schema as §1 states it: the live registry file also
carries `updatedAt`, and `entrypoint` takes values beyond `remote_cowork`
(`remote` was observed). Neither affects anything orch does.

Not verified first-hand, and still taken from the specification: that macOS
verifies socket ownership only while the posting child process lives; that
Linux verification survives the process exiting; that a container running as
PID 1 cannot verify it at all; that agent teams give teammates no worktree
isolation; that workflows cannot pause for mid-run human sign-off. The `orch`
checks for these exist and are wired, but the underlying platform behaviour was
not reproduced here.

---

## [P20] Matched-budget ablation of multi-agent topologies

> Tran & Kiela (Stanford), arXiv:2604.02460, 2 Apr 2026 — as cited by the
> overhaul specification, §16. **Not verified against the paper.**

Thinking tokens held constant at 100 / 500 / 1k / 2k / 5k / 10k across
single-agent versus sequential, subtask-parallel, parallel-roles, debate, and
ensemble topologies. Single-agent matched or beat multi-agent throughout.
Multi-agent overtook **only at ~70% deliberate context degradation**.

**Where this lands in the code:** the entire escalation ladder
(`orch/lib/escalate.sh`), and specifically `ORCH_T_CONTEXT_PCT=70` in
`orch/lib/health.sh`, which is this result's threshold used literally. It is
also why rung 0 is the default and why `orch report` measures
`escalation_precision` rather than assuming orchestration helped.

Also cited for: no published controlled ablation of orchestrated versus solo
agents on a *coding* task at matched budget — every matched-budget study is
reasoning or math, and cross-scaffold SWE-bench comparison is unsound by the
maintainers' own admission. This is the gap `orch report --ablation` exists to
fill.

## [P9] MAST — multi-agent system failure taxonomy

> As cited by the overhaul specification, §16. **Not verified against the
> paper.**

Failure-mode frequencies, used directly as detector thresholds:

| Failure mode | Frequency | Used in |
|---|---|---|
| step repetition | 15.7% | `step_repetition`, threshold 3 |
| unrecognized completion | 12.4% | — |
| task-spec disobedience | 11.8% | — |
| incomplete verification | 8.2% | the attested-gate design |
| task derailment | 7.4% | — |

Step repetition being the single most frequent failure is why it is the cheapest
signal in `orch/lib/health.sh` and why it fires at three occurrences rather than
at some larger, safer-feeling number.

Also cited for: gates should block via a hook returning exit 2, not by prompt
instruction.

---

## Claims carried without citation

Each entry records the figure the specification states and the place in this
repository that acts on it. **All are `CITATION MISSING`.**

- **[P1]** — `CITATION MISSING`. Anthropic's documented remedy for anchoring in
  sequential investigation is parallel competing-hypothesis debugging. Also:
  a hook returning exit 2 outranks in-prompt instruction in Claude Code's own
  gate-strength ranking. *Acts on:* `orch/lib/diagnose.sh`, all four gate hooks.

- **[P2]** — `CITATION MISSING`. Reviewers should get fresh context and see only
  the diff plus criteria, never the developer's trace. *Acts on:* invariant 3,
  `orch/agents/code-reviewer.md`.

- **[P3]** — `CITATION MISSING`. A 15× cost multiplier for multi-agent
  orchestration, later revised down. *Acts on:* the comparison line in
  `orch report --ablation`.

- **[P4]** — `CITATION MISSING`. Revised multiplier of 3–10×. *Acts on:* the
  same comparison line; also cited for "the cheapest path is the default".

- **[P5]** — `CITATION MISSING`. Code-reviewer context isolation; gate strength
  ranking. *Acts on:* invariant 3, `orch/settings.json`.

- **[P6] [P7]** — `CITATION MISSING`. Every gate backed by an external oracle.
  *Acts on:* invariant 6, `orch/lib/evidence.sh`.

- **[P8]** — `CITATION MISSING`. On a 2026 code-review agent benchmark,
  individual tools caught 20–32% of defects while the union of four different
  ones reached 41.5%, with 84% of emitted comments judged useful. *Acts on:* the
  heterogeneous code-reviewer ensemble; the union assertion in
  `orch/test/findings.test.sh`.

- **[P10]** — `CITATION MISSING`. Calibrated ensembles of diverse weak verifiers
  beat single judges by 13–18 points; a single LM judge produces "noisy, biased,
  and poorly calibrated scores". *Acts on:* why the ensemble is
  (model × lens) diverse rather than N copies of one code-reviewer.

- **[P11]** — `CITATION MISSING`. A pipeline whose code-reviewer had better precision
  (0.861 vs 0.644) produced worse outcomes (85.2% vs 89.2%), because the solver
  acted on verified-useful critique only **33.6%** of the time; injecting
  guidance into the solver's working context recovered most of the loss.
  *Acts on:* `orch/lib/findings.sh` in its entirety — verbatim inline delivery,
  and `critique_uptake_rate` printed against 33.6% in every report.

- **[P12]** — `CITATION MISSING`. Debate raised inter-agent consensus from 81.7%
  to 90.1% while accuracy fell — worst case 48.3% → 20.7% — with sycophancy to
  85.5% and correct reasoning discarded at up to 32.3 points. *Acts on:*
  invariant 5; `orch/agents/auditor.md`.

- **[P13]** — `CITATION MISSING`. Competitive debate is provably cheap talk,
  underperforming a single agent by up to 15 points on error detection.
  *Acts on:* the same.

- **[P14]** — `CITATION MISSING`. Four of eight notable 2025 orchestration tools
  are dead. *Acts on:* the honesty discipline in the README — delete what shows
  no yield, and say so.

- **[P16]** — `CITATION MISSING`. Reducing agent specs from ~1,000 to ~200 lines
  reported as an improvement. *Acts on:* the prompt-budget ceilings enforced in
  `orch/test/agent-lint.sh`.

- **[P17]** — `CITATION MISSING`. 80+ agents unanimously endorsed a non-existent
  padding oracle in OpenSSL; one empirical test killed it. *Acts on:* invariant
  5, adjudication by experiment, and the rule that two simultaneously-held
  predictions in `orch/lib/diagnose.sh` escalate rather than get a tiebreak.

- **[P18]** — `CITATION MISSING`. SWE-bench Verified 20.6% → 28.8% at Best@8 →
  32.0% at Best@16, with the verifier picking correctly ~86% of the time —
  meaning generation diversity, not verification, was the binding constraint.
  *Acts on:* rung 3; specifically why `orch/lib/candidates.sh` seeds three
  genuinely different approach directives rather than three temperatures.

- **[P21] [P22] [P23]** — `CITATION MISSING`. No architecture consistently wins
  [P21]; agents can be "100x more expensive while only being 1% better" [P22];
  the Pareto-winning harness on a multi-million-line codebase used 3× less
  context and simpler prompts [P23]. *Acts on:* invariant 8, the prompt budget,
  and the rejection of "more roles" as an answer to poor output.

- **[P25]** — `CITATION MISSING`. The blackboard pattern. *Acts on:* the
  `docs/features/**` artifact contract, carried unchanged from v1.

- **[P30]** — `CITATION MISSING`. Code-reviewer context isolation. *Acts on:*
  invariant 3.

---

## Re-verifying [P35]

```bash
claude --version
claude agents --json
ls -l ~/.claude/sessions/ /tmp/cc-socks/
ls -l ~/.claude/tasks/*/            # after any session creates a task
env | grep CLAUDE_CODE_MESSAGING_SOCKET
orch doctor                         # checks the operational constraints
```

`orch doctor` warns when the installed CLI is not the version this file records,
because a from-memory model of another program's internals is the most likely
failure point in this build.
