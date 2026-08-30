# plan-sparring

Claude Code plugin. When you enter plan mode it asks how the plan should be produced, and if you
pick a sparring route it holds the plan back until a model from another vendor has actually
reviewed it.

The point is the second opinion you would otherwise have to ask for by hand, every time.

```
Shift+Tab  →  "How should this plan be produced?"
                 · Spar with Codex      rounds until you agree
                 · One review pass      one review, then present
                 · Straight from Claude no external review
```

On a sparring route, `ExitPlanMode` is denied until a receipt exists for this planning round.
Claude runs one bundled command, the reviewer's objections are printed straight into the
conversation, and only then does the plan reach you.

## Requirements

- Claude Code
- the [`codex`](https://developers.openai.com/codex) CLI, signed in
- `jq`
- bash — macOS and Linux. On Windows the hooks are no-ops unless you run Claude Code under Git Bash.

Without `codex` on your `PATH` the plugin says so once and stays out of the way.

## Install

```
/plugin marketplace add <owner>/plan-sparring
/plugin install plan-sparring@plan-sparring
```

Or try it without installing anything:

```
claude --plugin-dir /path/to/plan-sparring
```

## How it works

Two hooks, one script, no changes to your `settings.json`.

| Hook | What it does |
|---|---|
| `UserPromptSubmit` | Notices the transition into plan mode, opens an *epoch*, and asks Claude to put the route question to you. Silent on every other prompt. |
| `PreToolUse` on `ExitPlanMode` | Decides whether the plan may be shown. |

An **epoch** is one planning round. It records where the transcript stood when the round began, so
an answer you gave in an earlier round cannot authorise this one. When a plan is allowed through,
the epoch and everything in it is deleted.

The gate has four outcomes:

- no route chosen yet → ask the question first
- *Straight from Claude* → allowed
- *One review pass* → needs a receipt for this epoch
- *Spar with Codex* → needs a receipt whose verdict is `AGREED`

**Receipts, not guesswork.** The gate does not scan the conversation for signs that a review
happened — that would be fooled by `codex exec … || true`, by an unrelated older call, or by a
command whose permission you denied (the attempt is recorded either way). Instead the plugin runs
the review itself through `bin/plan-sparring-review`, which insists on a clean exit and a non-empty
answer before it writes anything down.

The plan text never travels through a shell argument: `ExitPlanMode` hands the hook the full plan,
the hook puts it on disk, and the runner reads it from there.

**If the reviewer will not cooperate** — rate limit, hang, no network — nothing is ever waved
through on a counter. After repeated failures the gate asks *you*: retry, switch this plan to the
unreviewed route, or cancel. You always get to your plan, as a visible decision.

## Configuration

| Variable | Default | |
|---|---|---|
| `PLAN_SPARRING_OFF` | unset | set to anything to disable both hooks |
| `PLAN_SPARRING_MODEL` | `gpt-5.6-sol` | |
| `PLAN_SPARRING_EFFORT` | `xhigh` | |
| `PLAN_SPARRING_TIMEOUT` | `600` | seconds before the reviewer is killed |

## Another vendor

The name says sparring, not Codex, because the reviewer is meant to be replaceable. The contract
is plain text in, review on stdout, one final line `VERDICT: AGREED` or `VERDICT: OBJECTIONS`,
receipt out. Everything vendor-specific lives in `ps_backend_run()` in `bin/plan-sparring-review`,
marked as the swap point. Nothing else knows which CLI is being called.

## Limits

Read these before you rely on it.

- **This is a workflow guard, not a security boundary.** The receipt is a file in your own temp
  directory. Anything running as you can write one.
- **The receipt proves a review happened this round — not that the reviewer blessed the final
  wording.** The plan is supposed to change after objections, so there is deliberately no hash
  comparison against what you finally see.
- **Plan mode inside a subagent is untested and unsupported.**
- **Leaving and re-entering plan mode with Shift+Tab, with no prompt in between, is invisible**
  to the plugin. There is no hook on the toggle itself.
- **The sparring routes send your plan to another vendor's model.** The route question says so.
  Review artifacts, including the plan text, live under `$TMPDIR/plan-sparring/` with mode 600
  until the epoch closes.

## Tests

```
bash tests/run.sh
```

43 assertions against a fake backend: no network, no auth, no rate limit.

## Uninstall

```
/plugin uninstall plan-sparring@plan-sparring
```

## License

MIT
