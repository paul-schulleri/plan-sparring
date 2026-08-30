#!/usr/bin/env bash
# Shared contract between the hook and the runner. Everything that both sides must agree on
# lives here exactly once: the backend, the question wording, the option labels, the state paths.

# --- backend -----------------------------------------------------------------
# THE SWAP POINT for a different vendor is ps_backend_run() in bin/plan-sparring-review.
# Only the name and the binary live here.
PS_BACKEND_NAME="${PLAN_SPARRING_BACKEND_NAME:-Codex}"
PS_BACKEND_BIN="${PLAN_SPARRING_BIN:-codex}"
PS_MODEL="${PLAN_SPARRING_MODEL:-gpt-5.6-sol}"
PS_EFFORT="${PLAN_SPARRING_EFFORT:-xhigh}"
PS_TIMEOUT="${PLAN_SPARRING_TIMEOUT:-600}"

# --- the question and its labels ---------------------------------------------
# The gate greps the transcript for these exact strings, so the hook must instruct Claude to
# use them verbatim. Change them here and both sides follow.
PS_QUESTION="How should this plan be produced?"
PS_LABEL_SPAR="Spar with ${PS_BACKEND_NAME}"
PS_LABEL_PASS="One review pass"
PS_LABEL_DIRECT="Straight from Claude"

# --- state -------------------------------------------------------------------
# Everything lives under one temp root and is deleted when an epoch closes. The plan text
# is in there, hence umask 077.
umask 077
PS_ROOT="${TMPDIR:-/tmp}/plan-sparring"

ps_sid() { printf '%s' "${1:-nosid}" | tr -cd 'A-Za-z0-9._-' | cut -c1-64; }
ps_mode_file() { printf '%s/mode-%s' "$PS_ROOT" "$(ps_sid "$1")"; }
ps_epoch_dir() { printf '%s/ep-%s' "$PS_ROOT" "$(ps_sid "$1")"; }

ps_token() { head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || printf '%s' "$$"; }

# Decode a JSONL transcript from a byte offset, tolerating a truncated first line.
# $1 transcript path, $2 byte offset
ps_records_since() {
  local tp="$1" off="${2:-0}"
  [ -f "$tp" ] || return 0
  tail -c "+$((off + 1))" "$tp" 2>/dev/null
}

# Which route did the user pick? Reads ONLY tool_result blocks after the epoch offset, so a
# stale answer from an earlier planning round cannot authorise this one. Last answer wins.
# $1 transcript, $2 offset -> prints: spar | pass | direct | (empty)
ps_route() {
  local answers
  answers=$(ps_records_since "$1" "$2" | jq -Rr '
      fromjson? // empty
      | .message.content[]?
      | select(.type == "tool_result")
      | .. | strings
    ' 2>/dev/null | grep -o "${PS_QUESTION}\"=\"[^\"]*\"" | tail -1)
  case "$answers" in
    *"$PS_LABEL_DIRECT"*) printf 'direct' ;;
    *"$PS_LABEL_PASS"*)   printf 'pass' ;;
    *"$PS_LABEL_SPAR"*)   printf 'spar' ;;
    *)                    printf '' ;;
  esac
}
