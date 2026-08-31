# plan-sparring — working notes

A Claude Code plugin that holds `ExitPlanMode` until a plan has been reviewed by a model from
another vendor. Architecture, install and known limits are in `README.md` — this file is only the
conventions that are not obvious from the code.

## What this is

- `hooks/plan-sparring.sh` — one script, two branches on `.hook_event_name`. UserPromptSubmit arms
  an epoch and asks for the route; PreToolUse gates `ExitPlanMode`.
- `bin/plan-sparring-review` — hands the plan to the backend, prints the digest, writes the receipt.
- `lib/common.sh` — the shared contract: backend config, question and label strings, state paths,
  receipt parsing. Anything both sides must agree on lives here exactly once.
- Vendor **identity** — name, binary, model, effort — is configuration in `lib/common.sh`: the hook
  builds `PS_LABEL_SPAR` from `PS_BACKEND_NAME` and never sources the runner, so it cannot live
  anywhere else. The vendor **protocol** lives **only** in `ps_backend_run()` and
  `ps_backend_thread()` in `bin/plan-sparring-review`, marked as the swap point. Nothing outside
  those two functions knows how the CLI is invoked or how its output is shaped.

## Goal and priority

Production quality: correct, simple, readable, maintainable, hard to misuse.
Priority: **correctness > simplicity > readability > maintainability > performance > extensibility.**

The rule that outranks all of them here: **when the gate cannot verify, it denies.** A missing `jq`,
an unreadable or unparseable receipt, an epoch that does not match — all deny with a reason the user
can act on (`hooks/plan-sparring.sh:20-25`, `lib/common.sh:116-121`).

Two bypasses are deliberate. Do not "fix" them into denials:

- The backend CLI was not on PATH when the round was armed → `hooks/plan-sparring.sh:74` writes a
  `skip` marker, the user is told once, and the gate steps aside at `:116`. A plugin that blocks
  planning for people who never installed the backend is worse than no plugin. If the CLI disappears
  *after* arming, that is a different case and does deny (`:151-153`).
- The epoch directory cannot be created at all → `:113` exits without a decision: there is no state
  to verify against and nothing useful to say.

Every decision leaves through `deny()` or `say()`. Every bare `exit 0` carries a comment saying why
no decision goes out there — that is the rule; do not keep an inventory of them here, it rots.

## Core principles

Pragmatically, never dogmatically.

- **KISS** — simple and obvious over clever.
- **YAGNI** — no design for hypothetical requirements.
- **DRY** — deduplicate knowledge, not every repeated line. The question strings, labels and state
  paths are that knowledge, and they live in `lib/common.sh`. "State paths" means the directory
  helpers (`ps_epoch_dir`, `ps_mode_file`); the file names inside an epoch are literals on purpose,
  because eleven constants for eleven readers buys nothing. And do not extract a shared string when
  extracting makes the consumer harder to read — the `SUMMARY BEGIN`/`END` markers are built in the
  runner's prompt and matched by `ps_headlines`, and as an `awk -v` variable they would turn a fixed
  anchor into a dynamic regex. Cross-reference in both places instead.
- **Separation of concerns** — the hook decides, the runner talks to the backend, the library holds
  the contract.
- **Explicit over implicit** — no hidden behaviour, no surprising side effects.
- **Fail fast** — detect invalid state early, never silently ignore an unexpected failure.

## Before coding

- Read the code you are about to change, and trace the flow end to end.
- A change to a label, the question string, a state path or the receipt shape touches **both** sides:
  change it in `lib/common.sh` and check both callers.
- Reuse the existing helpers (`ps_num`, `ps_sha`, `ps_receipt`, `ps_records_since`) before writing a
  new one.
- Make the smallest coherent change that fully solves the problem. Do not touch unrelated code.

## Bash rules

- Bash 3.2 (macOS system bash). No associative arrays, no `${x^^}`, no `mapfile`, no `&>>`.
- `set -uo pipefail`, never `set -e`: the gate inspects exit statuses instead of dying on them.
- Quote every expansion, or say in a comment why not.
- `local` every function variable, and initialise any that can be **read before it is assigned** —
  including through a loop or a branch that may not run. From bash 4.4 on a bare `local x` leaves it
  unset and dies under `set -u` (see `more=0` in `ps_route`). `local x` followed immediately by
  `x=…` is fine. Never `local x=$(cmd)` when you need the command's exit status: `$?` then reports
  `local`, not the command.
- Never put a number from a file or the environment into `$(( ))` unchecked. `1.5`, `1e100` and `08`
  are all fatal there, and a fatal error mid-decision is a fail-open. Run it through `ps_num` first.
- Multi-field `jq` output is one line per field, never `@tsv`: bash collapses runs of IFS whitespace,
  so one empty field shifts every field after it.
- Strip control characters from anything that came out of JSON before it reaches a `systemMessage`.
- `2>/dev/null` goes before the redirect it is meant to silence, not after.
- Never exit 2 from the UserPromptSubmit branch — it erases the user's prompt.
- Handle errors intentionally: no branch that silently swallows a failure, and preserve the original
  cause when adding context.
- Validate anything from outside — payload, transcript, receipt, environment — where it enters. Do
  not add defensive checks for states the surrounding code already makes impossible.

## Comments

Code says what; comments say **why**. Every non-obvious line here names the failure it prevents —
match that register and that density (`lib/common.sh` is the reference). Do not restate the code.
Remove a comment that has outlived the code it explains.

This file works the same way: it states prohibitions and the failure each one prevents. It does not
keep inventories. Anything that counts, or names a line number, belongs in a test or nowhere — the
only parts of this document that have ever gone stale were the ones describing the code's state
rather than forbidding something.

## Simplicity

Do not introduce an abstraction, wrapper, indirection, config option or dependency without a
concrete current need. Prefer a little obvious duplication over a premature abstraction, and avoid
speculative layers, premature extensibility, premature optimisation and unrelated refactors.

No new file without a reason. A fourth script has to justify itself against putting the code in one
of the three that exist. Good code here should feel boring, obvious and reliable.

## Dependencies

Runtime set: `bash`, `jq`, the backend CLI, plus the coreutils already assumed (`awk`, `sed`, `diff`,
`od`, `shasum`/`sha256sum`).

Adding a fourth runtime dependency is a design change: each one is a new way for the gate to fail,
and each needs an explicit answer to "what happens when it is missing". The two existing answers are
the models — `jq` denies with instructions (`hooks/plan-sparring.sh:20-25`) because without it
nothing can be verified; the backend CLI steps aside with a visible message (`:71-76`) because its
absence is the normal state for someone who never installed it. Silence is not one of the options.

Tests must keep running with no network and no auth — that is what `tests/fake-backend` is for.

## Testing

```
bash tests/run.sh
```

No framework, asserts only, exits non-zero on failure.

- New behaviour gets an assertion in `tests/run.sh` using the existing helpers (`ups`, `gate`,
  `answer`, `forged`, `rcpt`, `check`, `has`, `hasnt`). New backend behaviour gets a `FAKE_MODE`
  branch in `tests/fake-backend`.
- Anything that could make the gate open when it should not gets a **negative** test. The suite is
  built around that: `forged`, the malformed-receipt fixtures, the epoch and plan-hash binding.
- Test behaviour, not implementation details. Cover the failure paths, not just the happy one.
- For a bug fix, reproduce it with an assertion first where practical.
- Never claim the suite passed without running it. The assertion count in `README.md` is checked by
  the suite itself, so it is not yours to remember.

## Style and lint

Roughly 100 characters per line, matching the current files. Readability beats artificial wrapping.

Linting needs the flags, not just the filenames — without them shellcheck cannot open
`lib/common.sh` and reports every shared variable as unused:

```
shellcheck -x --source-path=SCRIPTDIR hooks/plan-sparring.sh bin/plan-sparring-review
```

## Bug fixes

1. Find the root cause, not the symptom.
2. Understand why the existing code allowed it.
3. Reproduce it where practical.
4. Implement the smallest robust fix.
5. Add a regression assertion where it is worth one.
6. Check the other side of the contract for the same pattern — nearly every bug here has been a
   fail-open, and the hook and the runner read the same state.
7. No unrelated cleanup.

## Completion checklist

1. Re-read the original requirement.
2. Review the complete diff for unintended changes.
3. `bash tests/run.sh`
4. `shellcheck -x --source-path=SCRIPTDIR hooks/plan-sparring.sh bin/plan-sparring-review`
5. Confirm every failure path you touched still behaves as **Goal and priority** documents — denying
   where it denies, stepping aside where it deliberately steps aside.
6. Remove debug code, dead code and temporary workarounds.
7. Make sure the solution is no more complex than it needs to be.

State explicitly if a step could not be run.

Commit messages: imperative, sentence case, no prefix, no trailing period — "Close the gate: a
receipt the hook cannot parse must never open it".
