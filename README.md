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
conversation, and only then does the plan reach you. The loop is:

```
write the plan → ExitPlanMode (blocked) → run the command → work the objections in
              → ExitPlanMode again → … → it opens
```

Calling `ExitPlanMode` is what hands the current draft over, so it is not optional between rounds.
Running the review twice in a row is refused rather than silently re-reviewing the old draft.

**You can watch it happen.** Every round prints a digest covering both directions, and Claude is
required to relay it:

```
plan-sparring · round 2/3 · Codex gpt-5.6-sol medium · 94s
sent   draft, 187 lines (+34 / -7 since round 1)
       rechecking 3 previously highlighted point(s)
back   OBJECTIONS — 2 highlighted point(s)
       - dry-run reports every file as skipped
       - category dir may be a symlink
next   work them into the plan, then call ExitPlanMode to hand the revision over
```

Failures print the same shape with `back FAILED — …`, because a timeout or a dead backend is
exactly when you most want to know what happened. The outgoing half says *rechecking*, never
*addressed*: a line delta cannot prove an objection was answered.

Each gate decision also carries a one-line status. The block on a review route is the handover, not
a rejection — it is how your draft reaches the reviewer at all.

## Requirements

- Claude Code
- the [`codex`](https://developers.openai.com/codex) CLI, signed in
- `jq`
- bash — macOS and Linux. On Windows the hooks are no-ops unless you run Claude Code under Git Bash.

Without `codex` on your `PATH` the plugin says so once and stays out of the way.

## Install

```
/plugin marketplace add paul-schulleri/plan-sparring
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
an answer you gave in an earlier round cannot authorise this one. It is deleted when you leave plan
mode — not when a plan is allowed through: if you reject the plan and keep planning, the round you
already paid for still counts and no fresh review is demanded.

The gate has four outcomes:

- no route chosen yet → ask the question first
- *Straight from Claude* → allowed
- *One review pass* → needs a receipt for this epoch
- *Spar with Codex* → needs a receipt whose verdict is `AGREED`

**Receipts, not guesswork.** The gate does not scan the conversation for signs that a review
happened — that would be fooled by `codex exec … || true`, by an unrelated older call, or by a
command whose permission you denied (the attempt is recorded either way). Instead the plugin runs
the review itself through `bin/plan-sparring-review`, which insists on a clean exit, a non-empty
answer, and a well-formed verdict as the final line before it writes anything down.

The route is read back the same way: only an answer that belongs to an actual `AskUserQuestion`
call counts, so a tool that merely *prints* the answer string cannot choose your route.

On the *Spar* route the receipt is bound to the exact plan that was agreed to. Change the plan
after agreement and the gate asks for another round — agreement is about text, not about having
once run a review.

The plan text never travels through a shell argument: `ExitPlanMode` hands the hook the full plan,
the hook puts it on disk, and the runner reads it from there.

**Reviews end.** An adversarial reviewer at full effort will find something in any plan, forever,
so two things bound it: the reviewer is told to raise only what would cause data loss, a crash, or
the plan simply not working — not style, not coverage wishes. A limitation your plan states openly
and accepts counts as an answer, so you can narrow the scope instead of building what the reviewer
asks for. Rebutting is the other half of the loop and Claude is told to treat it as an equal move:
a point it does not accept goes into the plan under `## Rebuttals`, and the reviewer is asked to
weigh the rebuttal rather than repeat itself. A `## Scope` section naming what the plan
deliberately leaves out is checked against, not counted as a gap. After three rounds without
agreement the gate stops asking for more and puts it to you: **Keep sparring**, present it as it
stands, or drop to the unreviewed route. Keeping on grants another three rounds and the question
comes back then — you are asked once per budget, never once per round, and it never disappears
entirely.

**If the reviewer will not cooperate** — rate limit, hang, no network — nothing is ever waved
through on a counter. After repeated failures the gate asks *you*: **Retry**, re-affirm the route
you are on, or switch this plan to **Straight from Claude**. That question uses the same wording as
the first one, so your answer actually changes the route rather than disappearing into a dialogue
the gate does not recognise. You always get to your plan, as a visible decision.

## Configuration

| Variable | Default | |
|---|---|---|
| `PLAN_SPARRING_OFF` | unset | set to anything to disable both hooks |
| `PLAN_SPARRING_MODEL` | `gpt-5.6-sol` | |
| `PLAN_SPARRING_EFFORT` | `medium` | `xhigh` for genuinely large plans; it roughly quadruples the wait |
| `PLAN_SPARRING_TIMEOUT` | `600` | seconds before the reviewer is killed |
| `PLAN_SPARRING_MAX_ROUNDS` | `3` | after this many rounds without agreement the gate asks you what to do; *Keep sparring* grants the same number again. Set it high for an effectively unlimited run |
| `PLAN_SPARRING_KEEP` | unset | set to anything to keep the round's artifacts instead of deleting them on the way out |
| `PLAN_SPARRING_BIN` | `codex` | which CLI to call. On its own this does **not** make the plugin vendor-agnostic: the arguments are still Codex's. Swapping vendor means editing the two functions in [Another vendor](#another-vendor) |
| `PLAN_SPARRING_ACCOUNTS` | unset | one `Name=directory` per line, one per login. Two or more turn on the account question; one is used without asking; unset leaves the CLI's home alone. See [Two accounts](#two-accounts) |
| `PLAN_SPARRING_BACKEND_NAME` | `Codex` | what the reviewer is called in the route labels, messages and digest. Change it together with `PLAN_SPARRING_BIN` |

## Two accounts

If you have more than one Codex login — work and private, say — the plugin can ask which one
reviews a given plan, and the gate then holds you to the answer.

Each login lives in its own `CODEX_HOME`, and that is the whole mechanism: the CLI keeps and
refreshes its own tokens in there, so selecting an account is selecting a directory. This plugin
never holds a credential.

```
codex login                                    # the default home, ~/.codex
CODEX_HOME=~/.codex-private codex login        # a second one, once
export PLAN_SPARRING_ACCOUNTS="Work=$HOME/.codex
Private=$HOME/.codex-private"
```

The route question then carries a second question in the same dialogue, one label per account.
The answer is recorded for the round and written into the receipt, and the gate compares the two:
a review that came back from a different account does not open the gate, and it says which account
answered. Switching account mid-plan is allowed and starts a fresh conversation, because a thread
belongs to the login that opened it — the same draft is reviewed once more, by the account you
switched to.

A malformed entry is dropped rather than guessed at, so a typo costs you an option in the dialogue
instead of a round that cannot be verified. A configured directory that is not there stops the
round with that message, rather than letting the CLI quietly fall back to another login.

## Another vendor

The name says sparring, not Codex, because the reviewer is meant to be replaceable. Two functions in
`bin/plan-sparring-review`, marked as the swap point, are the whole protocol:

| | in | out |
|---|---|---|
| `ps_backend_run` | the prompt as one argument | the review, and a last non-empty line of exactly `VERDICT: AGREED` or `VERDICT: OBJECTIONS` |
| `ps_backend_thread` | the round's log file | the CLI's own conversation id on stdout, or nothing |

The thread id is what lets round 2 continue the same conversation instead of re-explaining
everything; without one, every round starts fresh and says so. Storing it is the runner's business,
not the backend's.

Which CLI is being called is *configuration*, not code — `PS_BACKEND_NAME` and `PS_BACKEND_BIN` in
`lib/common.sh`, because the route label the gate reads back is built from the name. The account
list is configuration in the same sense; the only vendor-specific part of it, the variable that
carries the home into the CLI, sits inside `ps_backend_run` with the rest of the protocol. Nothing outside
those two functions knows how the CLI is invoked or how its output is shaped.

## Limits

Read these before you rely on it.

- **This is a workflow guard, not a security boundary.** The receipt is a file in your own temp
  directory. Anything running as you can write one.
- **The receipt proves a review happened this round — not that the reviewer blessed the final
  wording.** The plan is supposed to change after objections, so there is deliberately no hash
  comparison against what you finally see.
- **A hard crash of the hook still fails open.** Claude Code treats a non-zero hook exit as
  non-blocking, so the gate can only deny when it runs far enough to say so. Missing dependencies
  and unreadable state are handled explicitly; a broken interpreter is not.
- **Plan mode inside a subagent is untested and unsupported.**
- **Leaving and re-entering plan mode with Shift+Tab, with no prompt in between, is invisible**
  to the plugin. There is no hook on the toggle itself.
- **The sparring routes send your plan to another vendor's model.** The route question says so.
  Review artifacts, including the plan text, live under `$TMPDIR/plan-sparring/` with mode 600
  until the round ends. On the *Straight from Claude* route the plan is never written down at all.
  A session that ends normally takes its round with it. A crash, a `kill`, or an end with
  `PLAN_SPARRING_OFF` set leaves it for the OS instead.
- **A round does not survive the session it was started in.** Quit while planning and resume, and
  the route question comes back and the review starts from round one — the round ends when the
  session does, not when you come back to it.
- **The hook costs about 25ms on every prompt**, plan mode or not.

## Tests

```
bash tests/run.sh
```

199 assertions against a fake backend: no network, no auth, no rate limit. They cover the route
provenance, epoch binding, plan-hash binding, verdict parsing, the failure escape, the timeout,
a transcript that has been truncated underneath a running round, the account binding, and every
shape of receipt the
gate must refuse to trust - a round that is not a whole number, a control character smuggled into
a field, valid JSON with garbage after it.

Linting needs the flags, not just the filenames:

```
shellcheck -x --source-path=SCRIPTDIR hooks/plan-sparring.sh bin/plan-sparring-review
```

Without them shellcheck cannot open `lib/common.sh`, checks the two scripts blind, and then
reports every shared variable in the library as unused. With them, both come out clean.

## Uninstall

```
/plugin uninstall plan-sparring@plan-sparring
```

## License

MIT
