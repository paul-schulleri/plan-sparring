#!/usr/bin/env bash
# plan-sparring — one script, two branches, dispatched on .hook_event_name.
#
#   UserPromptSubmit : notice entry into plan mode, open an epoch, make Claude ask the route.
#   PreToolUse       : hold ExitPlanMode until a valid receipt for THIS epoch exists.
#
# Never exits non-zero: exit code 2 on UserPromptSubmit would erase the user's prompt.
set -uo pipefail

PS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$PS_HOME/lib/common.sh"

[ -n "${PLAN_SPARRING_OFF:-}" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
tp=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
dir=$(ps_epoch_dir "$sid")
runner="$PS_HOME/bin/plan-sparring-review"

deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

case "$event" in

UserPromptSubmit)
  mode=$(printf '%s' "$payload" | jq -r '.permission_mode // empty' 2>/dev/null)
  mf=$(ps_mode_file "$sid")
  mkdir -p "$PS_ROOT" 2>/dev/null
  last=$(cat "$mf" 2>/dev/null || true)
  printf '%s' "$mode" > "$mf" 2>/dev/null

  # Only on the transition INTO plan mode, not on every prompt while already there.
  [ "$mode" = "plan" ] || exit 0
  [ "$last" = "plan" ] && exit 0

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    # Visible, not silent: "not installed" must be distinguishable from "plugin broken".
    printf '[plan-sparring] Installed, but the "%s" CLI was not found on PATH, so no sparring route is offered. Planning continues normally. Mention this to the user once, briefly.\n' "$PS_BACKEND_BIN"
    exit 0
  fi

  # A fresh epoch: wiping is what scopes everything: old answers, old receipts, old plans.
  rm -rf "$dir" 2>/dev/null
  mkdir -p "$dir" 2>/dev/null || exit 0
  ps_token > "$dir/id"
  if [ -f "$tp" ]; then wc -c < "$tp" | tr -d ' ' > "$dir/offset"; else echo 0 > "$dir/offset"; fi

  cat <<TXT
[plan-sparring] You just entered plan mode. Before anything else, ask exactly one AskUserQuestion
(header "Plan route", question "$PS_QUESTION") with these three options, using these labels VERBATIM:
  1. "$PS_LABEL_SPAR" - draft the plan, hand it to $PS_BACKEND_NAME for objections, work through
     them over as many rounds as it takes, and present it only once you agree. Sends the plan to
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
  off=$(cat "$dir/offset" 2>/dev/null || echo 0)
  route=$(ps_route "$tp" "$off")

  [ -z "$route" ] && deny "No plan route has been chosen yet. Ask exactly one AskUserQuestion (header \"Plan route\", question \"$PS_QUESTION\") with the verbatim labels \"$PS_LABEL_SPAR\", \"$PS_LABEL_PASS\", \"$PS_LABEL_DIRECT\", then act on the answer and call ExitPlanMode again."

  if [ "$route" = "direct" ]; then rm -rf "$dir" 2>/dev/null; exit 0; fi

  if ! command -v "$PS_BACKEND_BIN" >/dev/null 2>&1; then
    deny "This plan is on the \"$route\" route, but the \"$PS_BACKEND_BIN\" CLI is not on PATH, so no review can be produced. Ask the user via AskUserQuestion whether to install it and retry, or to switch to \"$PS_LABEL_DIRECT\" (use that label verbatim). Do not present the plan until they answer."
  fi

  # A receipt only counts for THIS epoch.
  id=$(cat "$dir/id" 2>/dev/null || echo -)
  status=$(jq -r '.status // empty' "$dir/receipt.json" 2>/dev/null || true)
  outcome=$(jq -r '.outcome // empty' "$dir/receipt.json" 2>/dev/null || true)
  repoch=$(jq -r '.epoch // empty' "$dir/receipt.json" 2>/dev/null || true)

  if [ "$repoch" = "$id" ] && [ "$status" = "ok" ]; then
    if [ "$route" = "pass" ] || [ "$outcome" = "agreed" ]; then
      rm -rf "$dir" 2>/dev/null
      exit 0
    fi
  fi

  # Hand the plan to the runner ourselves: ExitPlanMode carries the full text, so it never has
  # to travel through a shell argument or be retyped by Claude.
  printf '%s' "$payload" | jq -r '.tool_input.plan // empty' > "$dir/plan.md" 2>/dev/null

  fails=$(cat "$dir/fails" 2>/dev/null || echo 0)
  if [ "$fails" -ge 2 ] 2>/dev/null; then
    deny "$PS_BACKEND_NAME failed $fails times in a row for this plan. Do NOT present the plan on your own. Ask the user via AskUserQuestion (header \"Sparring failed\") which they want: \"Retry\" (run the command below again), \"$PS_LABEL_DIRECT\" (use that label verbatim - it switches this plan to the unreviewed route), or \"Cancel planning\". Command: $runner --epoch \"$dir\""
  fi

  if [ "$route" = "spar" ]; then
    deny "This plan still needs to be sparred with $PS_BACKEND_NAME. Run: $runner --epoch \"$dir\" - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. Work through every objection (incorporate it, or rebut it in the plan), then run the same command again for the next round. ExitPlanMode opens once $PS_BACKEND_NAME returns VERDICT: AGREED. Do not edit or fake the receipt."
  fi
  deny "This plan still needs one $PS_BACKEND_NAME review pass. Run: $runner --epoch \"$dir\" - it hands $PS_BACKEND_NAME the plan, prints the objections, and records the result. Incorporate what it raises (or rebut it in the plan), then call ExitPlanMode again. Do not edit or fake the receipt."
  ;;

esac
exit 0
