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
  if [ -f "$tp" ]; then wc -c < "$tp" | tr -d ' ' > "$dir/offset"; else echo 0 > "$dir/offset"; fi

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    # Visible, not silent: "not installed" must be distinguishable from "plugin broken". The
    # marker keeps the gate consistent with what the user was just told.
    : > "$dir/skip"
    printf '[plan-sparring] Installed, but the "%s" CLI was not found on PATH, so no sparring route is offered and planning continues normally. Mention this to the user once, briefly.\n' "$PS_BACKEND_BIN"
    exit 0
  fi

  cat <<TXT
[plan-sparring] You just entered plan mode. Before anything else, $(ask_route "Plan route")
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
  route=$(ps_route "$tp" "$off")

  [ -z "$route" ] && deny "plan-sparring · no route chosen yet" "No plan route has been chosen yet. $(ask_route "Plan route") Then act on the answer and call ExitPlanMode again."
  case "$route" in
    direct) say "plan-sparring · no external review (your choice)" ;;
    accept) say "plan-sparring · presenting as it stands (your choice)" ;;
  esac

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
  # The runner has no other way to know which route it is on, and "round 1/3" is a lie on a
  # one-pass route. Rewritten every time, so switching route mid-epoch heals itself.
  printf '%s' "$route" > "$dir/route" 2>/dev/null

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    deny "plan-sparring · $PS_BACKEND_BIN not found on PATH" "This plan is on the \"$route\" route, but the \"$PS_BACKEND_BIN\" CLI is not on PATH, so no review can be produced. $(ask_route "Sparring unavailable") Picking \"$PS_LABEL_DIRECT\" switches this plan to the unreviewed route."
  fi

  id=$(cat "$dir/id" 2>/dev/null || true)
  # One read of the receipt, and the exit status decides whether any of it counts: a missing file
  # still prints six default lines, so blanking on failure is what keeps the gate closed.
  fields=$(ps_receipt "$dir") || fields=""
  { read -r repoch; read -r status; read -r outcome; read -r rsha; read -r rounds; read -r pts
  } <<< "$fields"
  rounds=$(ps_num "$rounds"); pts=$(ps_num "$pts")

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

  if [ "$route" = "spar" ] && [ "$rounds" -ge "$PS_MAX_ROUNDS" ] 2>/dev/null; then
    deny "plan-sparring · $rounds rounds, no agreement · your call" "$PS_BACKEND_NAME has been round $rounds on this plan without agreeing, and an adversarial reviewer will keep finding something. Stop and ask the user how to proceed: one AskUserQuestion with the question \"$PS_QUESTION\" (header \"Rounds used up\") and these labels VERBATIM: \"$PS_LABEL_SPAR\" (keep going), \"$PS_LABEL_ACCEPT\" (present the plan as it stands, unreviewed objections and all), \"$PS_LABEL_DIRECT\". Summarise what is still open in one or two lines first so they can decide."
  fi

  fails=$(cat "$dir/fails" 2>/dev/null || echo 0)
  if [ "$fails" -ge 2 ] 2>/dev/null; then
    deny "plan-sparring · $PS_BACKEND_NAME failed $fails times · your call" "$PS_BACKEND_NAME failed $fails times in a row for this plan. Do NOT present the plan on your own. $(ask_route "Sparring failed") Add a fourth option \"$PS_LABEL_RETRY\" as the first choice. \"$PS_LABEL_RETRY\" means: run $cmd again. \"$PS_LABEL_DIRECT\" switches this plan to the unreviewed route. The other two labels re-affirm the current route."
  fi

  if [ -f "$dir/receipt.json" ]; then
    # after a revision the points are not "open" - they have not been looked at again yet
    [ "$route" = "spar" ] && where="round $((rounds + 1))/$PS_MAX_ROUNDS" || where="round $((rounds + 1))"
    # pts is 0 when the reviewer sent no summary block; claiming "0 point(s)" would read as
    # "nothing to fix" while the gate is denying because of them.
    [ "$pts" -gt 0 ] && st="plan-sparring · $where · $pts point(s) pending recheck" \
                     || st="plan-sparring · $where · objections pending recheck"
  else
    st="plan-sparring · handing the draft to $PS_BACKEND_NAME"
  fi

  if [ "$route" = "spar" ]; then
    [ -f "$dir/receipt.json" ] || first=" (this first block is the handover, not a rejection: it is how your draft reaches the reviewer)"
    deny "$st" "This plan still needs to be sparred with $PS_BACKEND_NAME.${first:-} Run: $cmd - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. Work through every objection (incorporate it, or rebut it in the plan), then call ExitPlanMode again - that is what hands your revised draft over, and you will be pointed at the next round from there. Running the command twice in a row reviews the SAME draft again. ExitPlanMode opens once $PS_BACKEND_NAME returns VERDICT: AGREED for the plan as it then stands. Do not edit or fake the receipt."
  fi
  [ -f "$dir/receipt.json" ] || first=" (this first block is the handover, not a rejection: it is how your draft reaches the reviewer)"
  deny "$st" "This plan still needs one $PS_BACKEND_NAME review pass.${first:-} Run: $cmd - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. Incorporate what it raises (or rebut it in the plan), then call ExitPlanMode again. Do not edit or fake the receipt."
  ;;

esac
exit 0
