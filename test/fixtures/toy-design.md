# Toy design: two small changes

A deliberately tiny design used by the smoke test. One feature is `direct`
(a static file), one is `lite` (a bug fix that needs a regression test), so a
single run exercises both a no-worker tier and a worker tier.

## Feature 1 - application config file

Add `config/app.json` describing the application.

```json
{"name": "toy", "version": 1}
```

Acceptance criteria:

- `config/app.json` exists and is valid JSON.
- It contains exactly the object above.

## Feature 2 - fix the argument count

`scripts/count.sh` reports one fewer argument than it was given. It must print
the number of arguments it received.

```
count.sh a b c  ->  3
```

Acceptance criteria:

- `scripts/count.sh a b c` prints `3`.
- A regression test covers the reported case.
