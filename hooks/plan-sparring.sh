#!/usr/bin/env bash
# plan-sparring — one script, two branches, dispatched on .hook_event_name.
#
#   UserPromptSubmit : notice entry into plan mode, open an epoch, make Claude ask the route.
#   PreToolUse       : hold ExitPlanMode until a valid receipt for THIS epoch exists.
#
# Exit code 2 on UserPromptSubmit would ERASE the user's prompt, so nothing here ever exits 2.
set -uo pipefail

PS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$PS_HOME/lib/common.sh"

# The opt-out: a plugin the user switched off must not emit a decision at all, not even a
# permissive one - an allow would still show up as this plugin having had an opinion.
[ -n "${PLAN_SPARRING_OFF:-}" ] && exit 0

payload=$(cat)

# The gate must not fall open just because a dependency is missing: without jq it cannot read the
# state, so it says so instead of waving the plan through. UserPromptSubmit stays silent.
if ! command -v jq >/dev/null 2>&1; then
  case "$payload" in
    *'"PreToolUse"'*) printf '%s\n' '{"systemMessage":"plan-sparring · jq missing, cannot verify","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"plan-sparring needs jq and it is not on PATH, so it cannot tell whether this plan was reviewed. Install jq, or set PLAN_SPARRING_OFF=1 to disable the plugin, then call ExitPlanMode again."}}' ;;
  esac
  exit 0
fi

# One jq call, not four: this hook runs on every prompt of every user. One line per field, not
# @tsv: bash collapses runs of IFS whitespace, and a tab IS IFS whitespace, so an empty
# transcript_path used to shift permission_mode into tp and leave mode empty - the hook then read
# "not plan mode" and never armed at all. Control characters are stripped so no field value can
# fake a line break and shift the rest.
{ read -r event; read -r sid; read -r tp; read -r mode; } <<< "$(printf '%s' "$payload" | jq -r \
  '[.hook_event_name // "", .session_id // "", .transcript_path // "", .permission_mode // ""]
   | map(tostring | gsub("[[:cntrl:]]"; " ")) | .[]' 2>/dev/null)"
dir=$(ps_epoch_dir "$sid")
cmd=$(printf '%q --epoch %q' "$PS_HOME/bin/plan-sparring-review" "$dir")

# $1 is the one-line status: it goes out as systemMessage and opens the reason.
# say() is the same channel on the allow path - a message with no decision is not an opinion.
deny() { jq -n --arg m "$1" --arg r "$1 — $2" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
say()  { jq -n --arg m "$1" '{systemMessage:$m}'; exit 0; }
ask_route() { printf 'Ask exactly one AskUserQuestion with the question "%s" (header "%s") and these labels VERBATIM: "%s", "%s", "%s".' "$PS_QUESTION" "$1" "$PS_LABEL_SPAR" "$PS_LABEL_PASS" "$PS_LABEL_DIRECT"; }
ask_account() {   # $1 = the words that lead into the instruction
  printf '%s one AskUserQuestion with the question "%s" (header "Account") and these labels VERBATIM: %s. It picks which %s login reviews the plan; recommend nothing, the user knows which account this work belongs to.' \
    "$1" "$PS_QUESTION_ACCOUNT" "$(ps_account_names | awk '{ printf "%s\"%s\"", (NR > 1 ? ", " : ""), $0 }')" \
    "$PS_BACKEND_NAME"
}
# The account is a follow-up, not a second question in the same call: one AskUserQuestion cannot
# make its second question depend on its first, and asking it on the direct route puts a question
# to the user whose answer is thrown away. Nothing at all is asked below two accounts: one
# configured account needs no choosing, and none means the plugin leaves the CLI's home alone.
ask_start() {
  ask_route "Plan route"
  [ "$(ps_account_count)" -ge 2 ] || return 0
  ask_account " If the user picks \"$PS_LABEL_SPAR\" or \"$PS_LABEL_PASS\", follow up with"
}

case "$event" in

UserPromptSubmit)
  mf=$(ps_mode_file "$sid")
  mkdir -p "$PS_ROOT" 2>/dev/null
  last=$(cat "$mf" 2>/dev/null || true)
  printf '%s' "$mode" > "$mf" 2>/dev/null

  if [ "$mode" != "plan" ]; then
    # Leaving plan mode ends the round: the epoch holds the plan text, so it goes now.
    if [ "$last" = "plan" ]; then
      if [ -n "${PLAN_SPARRING_KEEP:-}" ]; then
        printf '[plan-sparring] Keeping %s for inspection (PLAN_SPARRING_KEEP is set).\n' "$dir"
      else
        rm -rf "$dir" 2>/dev/null
      fi
    fi
    exit 0
  fi
  [ "$last" = "plan" ] && exit 0     # already planning: do not ask on every prompt

  # A fresh epoch. Wiping is what scopes everything: old answers, old receipts, old plans.
  rm -rf "$dir" 2>/dev/null
  mkdir -p "$dir" 2>/dev/null || exit 0
  ps_token > "$dir/id"
  if [ -f "$tp" ]; then wc -c 2>/dev/null < "$tp" | tr -d ' ' > "$dir/offset"; else echo 0 > "$dir/offset"; fi

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    # Visible, not silent: "not installed" must be distinguishable from "plugin broken". The
    # marker keeps the gate consistent with what the user was just told.
    : > "$dir/skip"
    printf '[plan-sparring] Installed, but the "%s" CLI was not found on PATH, so no sparring route is offered and planning continues normally. Mention this to the user once, briefly.\n' "$PS_BACKEND_BIN"
    exit 0
  fi

  cat <<TXT
[plan-sparring] You just entered plan mode. Before anything else, $(ask_start)
  "$PS_LABEL_SPAR" - rounds until you agree. Worth the wait when the plan touches data, money,
     security or concurrency. Sends the plan to another vendor's model.
  "$PS_LABEL_PASS" - one review, incorporate the objections, present. A good default.
     Sends the plan to another vendor's model.
  "$PS_LABEL_DIRECT" - no external review. Right for small or throwaway work.
Order them as you see fit and recommend the one that actually fits this task - a trivial job does
not need rounds of sparring.
The labels must match exactly; the gate reads them back.

On either review route the work goes through ONE bundled command, which the gate will name when it
first blocks your plan. Do not build your own review with codex or any other CLI: the gate only
counts that command's receipt, so anything else is wasted effort. The loop is:
  write the plan -> call ExitPlanMode (it will be blocked) -> run the command it names ->
  work the objections into the plan -> call ExitPlanMode again -> repeat until it opens.
Calling ExitPlanMode is what hands your current draft over, so never skip it between rounds.

Keep the user in the loop, every round, without being asked: say one short line before you run the
command ("sending the draft to $PS_BACKEND_NAME, round 2"), and immediately after it relay the
digest block the command prints - round, what went out, what came back - in the language of the
conversation. Relay it on failures too. Do not paste the full review; the digest is the point.

Give the plan a short "Scope" line naming what it deliberately does not cover. The reviewer checks
against that, instead of against a bigger tool it imagines.

Now continue with the actual task.
TXT
  exit 0
  ;;

PreToolUse)
  # Self-healing: if the plugin was installed mid-session there is no epoch yet.
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || exit 0
    ps_token > "$dir/id"; echo 0 > "$dir/offset"
  fi
  [ -f "$dir/skip" ] && exit 0        # no backend was available when this round started

  off=$(cat "$dir/offset" 2>/dev/null || echo 0)
  # Two answers out of one scan: which route, and how many times the user chose to keep sparring
  # after the budget ran out. Line-based for the same reason the receipt is.
  { read -r route; read -r more; } <<< "$(ps_route "$tp" "$off")"
  budget=$(ps_budget "$more")
  # The step inside ps_budget is local, and naming it here would be an unbound variable under
  # set -u - in the MAIN shell, not a subshell, so the hook would die at the cap without ever
  # emitting a decision. ps_budget 0 is that same sanitized number by definition.
  step=$(ps_budget 0)

  [ -z "$route" ] && deny "plan-sparring · no route chosen yet" "No plan route has been chosen yet. $(ask_start) Then act on the answer and call ExitPlanMode again."
  case "$route" in
    direct) say "plan-sparring · no external review (your choice)" ;;
    accept) say "plan-sparring · presenting as it stands (your choice)" ;;
  esac

  # Below the routes that send the plan somewhere, so the direct route still writes nothing down.
  # With a single account there is nothing to ask and nothing to get wrong; with none configured
  # acct stays empty, the runner leaves the CLI's home alone, and the receipt carries no account
  # either - which is what makes the empty string compare equal further down.
  acct=""; naccts=$(ps_account_count)
  if [ "$naccts" -ge 2 ]; then
    acct=$(ps_account_pick "$tp" "$off")
    [ -n "$acct" ] || deny "plan-sparring · no account chosen yet" "This plan is on the \"$route\" route, but no $PS_BACKEND_NAME account has been chosen for it. $(ask_account "Ask exactly") Then act on the answer and call ExitPlanMode again."
  elif [ "$naccts" -eq 1 ]; then
    acct=$(ps_account_names)
  fi

  # Only now, once a review is actually on the table. ExitPlanMode carries the full plan text, so
  # it never travels through a shell argument - and the hash below covers exactly the bytes the
  # runner will read. On the direct route nothing of the plan is written down at all.
  # select() matters: an empty plan string would still make jq -r emit a newline, and a
  # one-byte file counts as non-empty - the fallback below would never run.
  printf '%s' "$payload" | jq -r '.tool_input.plan // "" | select(. != "")' > "$dir/plan.md" 2>/dev/null
  # ExitPlanMode's own description says it does not take the plan as a parameter, so do not rely
  # on tool_input.plan alone: fall back to the plan file the harness wrote.
  pf=$(printf '%s' "$payload" | jq -r '.tool_input.planFilePath // empty' 2>/dev/null)
  [ -n "$pf" ] && printf '%s' "$pf" > "$dir/planfile"
  [ -s "$dir/plan.md" ] || { [ -s "$pf" ] && cp "$pf" "$dir/plan.md" 2>/dev/null; }
  # The runner has no other way to know which route it is on, nor how far the budget was
  # extended, and "round 1/3" is a lie on a one-pass route - "round 4/3" is one after an
  # extension. Rewritten every time, so switching route mid-epoch heals itself.
  printf '%s' "$route" > "$dir/route" 2>/dev/null
  printf '%s' "$budget" > "$dir/cap" 2>/dev/null
  # Rewritten every round for the same reason as the route: switching account mid-plan has to heal
  # itself. The runner refuses to re-review an unchanged draft, but makes an exception when the
  # account changed - otherwise this switch would deadlock against that refusal.
  printf '%s' "$acct" > "$dir/account" 2>/dev/null

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    deny "plan-sparring · $PS_BACKEND_BIN not found on PATH" "This plan is on the \"$route\" route, but the \"$PS_BACKEND_BIN\" CLI is not on PATH, so no review can be produced. $(ask_route "Sparring unavailable") Picking \"$PS_LABEL_DIRECT\" switches this plan to the unreviewed route."
  fi

  id=$(cat "$dir/id" 2>/dev/null || true)
  # One read of the receipt, and the exit status decides whether any of it counts: a missing file
  # still prints six default lines, so blanking on failure is what keeps the gate closed.
  fields=$(ps_receipt "$dir") || fields=""
  { read -r repoch; read -r status; read -r outcome; read -r rsha; read -r rounds; read -r pts
    read -r racct; } <<< "$fields"
  rounds=$(ps_num "$rounds"); pts=$(ps_num "$pts")

  # A review by another account is not this round's review: the whole point of choosing one is
  # that the answer comes from it. Named separately from the generic "not reviewed yet" denial
  # because the fix is different - rerun the same command, it now uses the account you picked.
  if [ -n "$id" ] && [ "$repoch" = "$id" ] && [ "$status" = "ok" ] && [ "$racct" != "$acct" ]; then
    deny "plan-sparring · that review came from another account" "This plan was reviewed as \"${racct:-none}\", but this round is on \"${acct:-none}\". Run $cmd again - it uses the account recorded for this round - then call ExitPlanMode again."
  fi

  if [ -n "$id" ] && [ -n "$repoch" ] && [ "$repoch" = "$id" ] && [ "$status" = "ok" ]; then
    if [ "$route" = "pass" ]; then
      # one pass, objections expected to be worked in afterwards
      say "plan-sparring · one $PS_BACKEND_NAME review pass done · opening"
    fi
    if [ "$outcome" = "agreed" ]; then
      # Agreement is about the exact text that was agreed to. On this route the plan is not
      # supposed to change afterwards, so a changed plan means the agreement no longer applies.
      if [ "$rsha" = "$(ps_sha "$dir/plan.md")" ]; then
        say "plan-sparring · $PS_BACKEND_NAME agreed after $rounds round(s) · opening"
      fi
      deny "plan-sparring · plan changed after agreement · one more round" "$PS_BACKEND_NAME agreed to an earlier version of this plan, but the plan has changed since. Run one more round so the agreement covers what you are about to present: $cmd"
    fi
  fi

  # No 2>/dev/null any more: both operands are ps_num-clean, and the redirect used to hide
  # `[ 3 -ge abc ]` failing on a typo'd PLAN_SPARRING_MAX_ROUNDS - which removed the cap entirely.
  if [ "$route" = "spar" ] && [ "$rounds" -ge "$budget" ]; then
    deny "plan-sparring · $rounds rounds, no agreement · your call" "$rounds review rounds are complete and $PS_BACKEND_NAME still has objections. Stop and ask the user whether to continue for another $step rounds or consciously present the current plan with those objections: one AskUserQuestion with the question \"$PS_QUESTION\" (header \"Rounds used up\") and these labels VERBATIM: \"$PS_LABEL_MORE\", \"$PS_LABEL_ACCEPT\". Name the rounds spent, roughly what each cost, and what the last round actually brought, in one or two lines first so they can decide."
  fi

  # ps_num and no 2>/dev/null, for the same reason as the round count above: `[ abc -ge 2 ]` FAILS
  # rather than erroring, and the suppressed error took away the user's only way out of a broken
  # backend. The realistic corruption is an EMPTY file after an interrupted write, not letters.
  fails=$(ps_num "$(cat "$dir/fails" 2>/dev/null || true)")
  if [ "$fails" -ge 2 ]; then
    deny "plan-sparring · $PS_BACKEND_NAME failed $fails times · your call" "$PS_BACKEND_NAME failed $fails times in a row for this plan. Do NOT present the plan on your own. $(ask_route "Sparring failed") Add a fourth option \"$PS_LABEL_RETRY\" as the first choice. \"$PS_LABEL_RETRY\" means: run $cmd again. \"$PS_LABEL_DIRECT\" switches this plan to the unreviewed route. The other two labels re-affirm the current route."
  fi

  if [ -f "$dir/receipt.json" ]; then
    # after a revision the points are not "open" - they have not been looked at again yet
    [ "$route" = "spar" ] && where="round $((rounds + 1))/$budget" || where="round $((rounds + 1))"
    # pts is 0 when the reviewer sent no summary block; claiming "0 point(s)" would read as
    # "nothing to fix" while the gate is denying because of them.
    [ "$pts" -gt 0 ] && st="plan-sparring · $where · $pts point(s) pending recheck" \
                     || st="plan-sparring · $where · objections pending recheck"
  else
    st="plan-sparring · handing the draft to $PS_BACKEND_NAME"
  fi

  # A reviewer that is never contradicted is not a sparring partner. Naming rebutting as an equal
  # move was not enough - two field runs incorporated 5/5 and 4/4 objections and rebutted none,
  # because "incorporate or rebut" is a judgement call and incorporating is always the safe one.
  # So the choice follows from a check that can be answered by reading the source. The second
  # question is load-bearing: "already holds today" alone would rebut "the data-loss path you
  # were asked to close is still open", which is a defect, not an inherited limitation.
  rebut="For each objection, settle two questions against the source, not from memory. First: does it describe something THIS change introduces, or something that already holds in the code today? Second, only if it already holds today: is fixing it part of what this plan set out to do, does the change newly expose it or rely on it, or does leaving it defeat the plan's stated goal? Only when that second answer is no is the behaviour inherited rather than caused - rebut that, and cite file:line as the evidence. Everything else gets incorporated. A rebuttal belongs in the plan under a \"## Rebuttals\" heading, one line per point - \"- <the point> - <why it does not apply here>\". It is a legitimate answer, not a dodge: the reviewer is told to weigh it. Change nothing that was not the subject of an objection."
  # Only once a round has come back: on the handover there is nothing to call an edge case yet.
  [ -f "$dir/receipt.json" ] && edge=" If what came back is an edge case of an edge case for what this plan actually covers, say that in the rebuttal instead of hardening further."

  [ -f "$dir/receipt.json" ] || first=" (this first block is the handover, not a rejection: it is how your draft reaches the reviewer)"

  if [ "$route" = "spar" ]; then
    deny "$st" "This plan still needs to be sparred with $PS_BACKEND_NAME.${first:-} Run: $cmd - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. $rebut${edge:-} Then call ExitPlanMode again - that is what hands your revised draft over, and you will be pointed at the next round from there. Running the command twice in a row reviews the SAME draft again. ExitPlanMode opens once $PS_BACKEND_NAME returns VERDICT: AGREED for the plan as it then stands. Do not edit or fake the receipt."
  fi
  deny "$st" "This plan still needs one $PS_BACKEND_NAME review pass.${first:-} Run: $cmd - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. $rebut Then call ExitPlanMode again. Do not edit or fake the receipt."
  ;;

SessionEnd)
  # The round's artifacts include the plan text, so a session that ends in plan mode must not leave
  # them behind. The mode file goes with them: it is written on every prompt and, until now, removed
  # by nothing at all - one file per session id, kept forever.
  # $mode is deliberately not consulted: the documented SessionEnd payload does not carry
  # permission_mode, so "were we planning?" cannot be answered here, and removing what is not there
  # costs nothing. PLAN_SPARRING_OFF exits long before this, so switching the plugin off keeps the
  # state it had - the README names that as the limit it is.
  [ -n "${PLAN_SPARRING_KEEP:-}" ] || rm -rf "$dir" "$(ps_mode_file "$sid")" 2>/dev/null
  ;;

esac
# Both paths that reach here have nothing to decide. SessionEnd is done cleaning up and the session
# is over, so there is no one left to tell. Otherwise no branch matched: another event, or a payload
# jq could not parse, which leaves $event empty. The jq-missing path above denies instead, because
# there it is the plugin's own dependency that is broken. Here it is the caller's payload, and
# Claude Code always sends valid JSON - a defensive deny would guard a state the caller makes
# impossible.
exit 0
