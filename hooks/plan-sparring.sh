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
    *'"PreToolUse"'*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"plan-sparring needs jq and it is not on PATH, so it cannot tell whether this plan was reviewed. Install jq, or set PLAN_SPARRING_OFF=1 to disable the plugin, then call ExitPlanMode again."}}' ;;
  esac
  exit 0
fi

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
tp=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
dir=$(ps_epoch_dir "$sid")
cmd=$(printf '%q --epoch %q' "$PS_HOME/bin/plan-sparring-review" "$dir")

deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
ask_route() { printf 'Ask exactly one AskUserQuestion with the question "%s" (header "%s") and these labels VERBATIM: "%s", "%s", "%s".' "$PS_QUESTION" "$1" "$PS_LABEL_SPAR" "$PS_LABEL_PASS" "$PS_LABEL_DIRECT"; }

case "$event" in

UserPromptSubmit)
  mode=$(printf '%s' "$payload" | jq -r '.permission_mode // empty' 2>/dev/null)
  mf=$(ps_mode_file "$sid")
  mkdir -p "$PS_ROOT" 2>/dev/null
  last=$(cat "$mf" 2>/dev/null || true)
  printf '%s' "$mode" > "$mf" 2>/dev/null

  if [ "$mode" != "plan" ]; then
    # Leaving plan mode ends the round: the epoch holds the plan text, so it goes now.
    [ "$last" = "plan" ] && rm -rf "$dir" 2>/dev/null
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
  1. "$PS_LABEL_SPAR" - draft the plan, hand it to $PS_BACKEND_NAME for objections, work through
     them over as many rounds as it takes, present it only once you agree. Sends the plan to
     another vendor's model.
  2. "$PS_LABEL_PASS" - one $PS_BACKEND_NAME review, incorporate the objections, then present.
     Sends the plan to another vendor's model.
  3. "$PS_LABEL_DIRECT" - no external review.
The labels must match exactly; the gate reads them back. Then continue with the actual task.
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

  # Capture the plan first: ExitPlanMode carries the full text, so it never has to travel through
  # a shell argument, and the hash below has to cover exactly the bytes the runner will read.
  printf '%s' "$payload" | jq -r '.tool_input.plan // empty' > "$dir/plan.md" 2>/dev/null

  off=$(cat "$dir/offset" 2>/dev/null || echo 0)
  route=$(ps_route "$tp" "$off")

  [ -z "$route" ] && deny "No plan route has been chosen yet. $(ask_route "Plan route") Then act on the answer and call ExitPlanMode again."
  [ "$route" = "direct" ] && exit 0

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    deny "This plan is on the \"$route\" route, but the \"$PS_BACKEND_BIN\" CLI is not on PATH, so no review can be produced. $(ask_route "Sparring unavailable") Picking \"$PS_LABEL_DIRECT\" switches this plan to the unreviewed route."
  fi

  id=$(cat "$dir/id" 2>/dev/null || true)
  status=$(jq -r '.status // empty' "$dir/receipt.json" 2>/dev/null || true)
  outcome=$(jq -r '.outcome // empty' "$dir/receipt.json" 2>/dev/null || true)
  repoch=$(jq -r '.epoch // empty' "$dir/receipt.json" 2>/dev/null || true)
  rsha=$(jq -r '.input_sha256 // empty' "$dir/receipt.json" 2>/dev/null || true)

  if [ -n "$id" ] && [ -n "$repoch" ] && [ "$repoch" = "$id" ] && [ "$status" = "ok" ]; then
    if [ "$route" = "pass" ]; then
      exit 0                          # one pass, objections expected to be worked in afterwards
    fi
    if [ "$outcome" = "agreed" ]; then
      # Agreement is about the exact text that was agreed to. On this route the plan is not
      # supposed to change afterwards, so a changed plan means the agreement no longer applies.
      if [ "$rsha" = "$(ps_sha "$dir/plan.md")" ]; then exit 0; fi
      deny "$PS_BACKEND_NAME agreed to an earlier version of this plan, but the plan has changed since. Run one more round so the agreement covers what you are about to present: $cmd"
    fi
  fi

  fails=$(cat "$dir/fails" 2>/dev/null || echo 0)
  if [ "$fails" -ge 2 ] 2>/dev/null; then
    deny "$PS_BACKEND_NAME failed $fails times in a row for this plan. Do NOT present the plan on your own. $(ask_route "Sparring failed") Add a fourth option \"$PS_LABEL_RETRY\" as the first choice. \"$PS_LABEL_RETRY\" means: run $cmd again. \"$PS_LABEL_DIRECT\" switches this plan to the unreviewed route. The other two labels re-affirm the current route."
  fi

  if [ "$route" = "spar" ]; then
    deny "This plan still needs to be sparred with $PS_BACKEND_NAME. Run: $cmd - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. Work through every objection (incorporate it, or rebut it in the plan), then run the same command again for the next round. ExitPlanMode opens once $PS_BACKEND_NAME returns VERDICT: AGREED for the plan as it then stands. Do not edit or fake the receipt."
  fi
  deny "This plan still needs one $PS_BACKEND_NAME review pass. Run: $cmd - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. Incorporate what it raises (or rebut it in the plan), then call ExitPlanMode again. Do not edit or fake the receipt."
  ;;

esac
exit 0
