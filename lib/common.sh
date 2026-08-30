#!/usr/bin/env bash
# Shared contract between the hook and the runner. Everything both sides must agree on lives here
# exactly once: the backend, the question wording, the option labels, the state paths.

# --- backend -----------------------------------------------------------------
# THE SWAP POINT for a different vendor is ps_backend_run() in bin/plan-sparring-review.
PS_BACKEND_NAME="${PLAN_SPARRING_BACKEND_NAME:-Codex}"
PS_BACKEND_BIN="${PLAN_SPARRING_BIN:-codex}"
PS_MODEL="${PLAN_SPARRING_MODEL:-gpt-5.6-sol}"
# medium, not xhigh: field testing showed xhigh rounds running 4-10 minutes each and an
# adversarial reviewer never running out of edge cases. Raise it for genuinely large plans.
PS_EFFORT="${PLAN_SPARRING_EFFORT:-medium}"
PS_TIMEOUT="${PLAN_SPARRING_TIMEOUT:-600}"
# After this many rounds without agreement the gate stops demanding more and asks the user.
PS_MAX_ROUNDS="${PLAN_SPARRING_MAX_ROUNDS:-3}"

# --- the question and its labels ---------------------------------------------
# Every question the plugin asks - including the one after a failure - uses PS_QUESTION verbatim.
# Only the header differs. A fallback question with its own wording would not be recognised here
# and the user's escape would silently do nothing.
PS_QUESTION="How should this plan be produced?"
PS_LABEL_SPAR="Spar with ${PS_BACKEND_NAME}"
PS_LABEL_PASS="One review pass"
PS_LABEL_DIRECT="Straight from Claude"
PS_LABEL_ACCEPT="Present it as it stands"   # offered once the rounds run out
PS_LABEL_RETRY="Retry"          # keeps the current route; ignored when resolving it

# --- state -------------------------------------------------------------------
umask 077
PS_ROOT="${TMPDIR:-/tmp}/plan-sparring"

ps_sid() { printf '%s' "${1:-nosid}" | tr -cd 'A-Za-z0-9._-' | cut -c1-64; }
ps_mode_file() { printf '%s/mode-%s' "$PS_ROOT" "$(ps_sid "$1")"; }
ps_epoch_dir() { printf '%s/ep-%s' "$PS_ROOT" "$(ps_sid "$1")"; }
ps_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

# The || fallback must test the OUTPUT, not the exit status: od on empty input succeeds, so a
# missing /dev/urandom would silently yield an empty epoch id - and an empty id would match an
# empty receipt field, opening the gate.
ps_token() {
  local t
  t=$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ -n "$t" ] || t="$$-$(date +%s)"
  printf '%s' "$t"
}

# $1 transcript path, $2 byte offset
ps_records_since() {
  local tp="$1" off="${2:-0}" size
  [ -f "$tp" ] || return 0
  size=$(wc -c < "$tp" 2>/dev/null | tr -d ' '); [ -n "$size" ] || size=0
  # A truncated or replaced transcript would leave a stale offset past the end of the file and
  # hide every later answer: the gate would deny forever with no way out.
  if [ "$off" -gt "$size" ] 2>/dev/null; then off=0; fi
  tail -c "+$((off + 1))" "$tp" 2>/dev/null
}

# Which route did the user pick?
#   - only answers AFTER the epoch offset count, so an earlier round cannot authorise this one
#   - the answer must belong to an actual AskUserQuestion tool call carrying our question, so a
#     tool that merely PRINTS the answer string cannot choose the route
#   - labels are compared for equality, not substring
#   - "Retry" answers are skipped, so the last real route survives a failure dialogue
# $1 transcript, $2 offset -> spar | pass | direct | accept | (empty)
ps_route() {
  local recs ids id ans line label out=""
  recs=$(ps_records_since "$1" "$2")
  [ -n "$recs" ] || return 0
  ids=$(printf '%s\n' "$recs" | jq -Rr --arg q "$PS_QUESTION" '
      fromjson? // empty | .message.content[]?
      | select(.type == "tool_use" and .name == "AskUserQuestion")
      | select((.input | tostring) | contains($q)) | .id' 2>/dev/null)
  [ -n "$ids" ] || return 0

  for id in $ids; do
    ans=$(printf '%s\n' "$recs" | jq -Rr --arg id "$id" '
        fromjson? // empty | .message.content[]?
        | select(.type == "tool_result" and .tool_use_id == $id)
        | .. | strings' 2>/dev/null | grep -o "${PS_QUESTION}\"=\"[^\"]*\"")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      label=${line#*\"=\"}; label=${label%\"}
      case "$label" in
        "$PS_LABEL_DIRECT") out=direct ;;
        "$PS_LABEL_ACCEPT") out=accept ;;
        "$PS_LABEL_PASS")   out=pass ;;
        "$PS_LABEL_SPAR")   out=spar ;;
        *) : ;;   # "Retry", "Cancel planning", free text: leave the current route alone
      esac
    done <<< "$ans"
  done
  printf '%s' "$out"
}
