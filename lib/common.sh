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

# --- the receipt -------------------------------------------------------------
# One jq call, six lines, one per field. Line-based and deliberately NOT separator-based:
#  - bash collapses runs of IFS *whitespace*, so one empty field in an @tsv row shifts every
#    field after it - and a shifted epoch gets compared against the wrong string;
#  - any other separator, U+001F included, can be written into receipt.json as \uXXXX and then
#    breaks the field boundary from the inside. A forged {"epoch":"<real-id>ok"} would set
#    epoch AND status in one go and open the gate.
# -s is load-bearing too: without slurp, jq streams, so a file like `{...valid...} garbage` gets
# all six fields printed BEFORE the parse error - the caller would read the real epoch and
# status=ok out of a corrupt file. With -s nothing runs until the whole input parsed, so a broken
# file yields no output at all. `length == 1` rejects a file holding several JSON values.
# Control characters go, so neither a line break nor a terminal escape can travel from the
# receipt into a systemMessage.
# No `|| true`: the exit status is half the check, the caller has to see it.
ps_receipt() {   # $1 = epoch dir -> epoch, status, outcome, input_sha256, round, headline count
  jq -sr 'if length == 1 then .[0] else {} end
          | [ (.epoch // ""), (.status // ""), (.outcome // ""), (.input_sha256 // ""),
              (.round // 0), ((.headlines | arrays | length) // 0) ]
          | map(tostring | gsub("[[:cntrl:]]"; " ")) | .[]' "$1/receipt.json" 2>/dev/null
}

# A number out of someone else's file is not a number until it has been checked. The JSON type is
# not enough: 1.5 and 1e100 are valid JSON numbers and both are a FATAL error inside $(( )), which
# kills the caller mid-decision - that is the fail-open this exists to prevent. Plain digits are
# not enough either: 08 and 09 are invalid octal to bash ("value too great for base", also fatal)
# and 010 would quietly be 8. So filter first, then force base 10. Eight digits or more is 0 as
# well - a round counter that long is not a number, it is junk.
ps_num() {
  case "${1:-}" in ''|*[!0-9]*|????????*) printf 0; return ;; esac
  printf '%s' "$((10#$1))"
}

# --- digest helpers ----------------------------------------------------------
# Line delta between two drafts, as "+n / -m". Empty output means "not available" - the caller
# degrades the display and never fails a review over it.
# diff exits 1 for "files differ", which is success here; only >1 is an error. The status has to
# be captured directly, never through a pipe that would report the pipe's status instead. And the
# counting starts after the first @@ hunk header, because the "+++ new" file header would
# otherwise be counted as an added line.
ps_delta() {
  local old="$1" new="$2" out st plus minus
  [ -s "$old" ] && [ -s "$new" ] || return 1
  command -v diff >/dev/null 2>&1 || return 1
  out=$(diff -U0 "$old" "$new" 2>/dev/null); st=$?
  [ "$st" -le 1 ] || return 1
  plus=$(printf '%s\n' "$out" | awk '/^@@/{h=1;next} h&&/^\+/{n++} END{print n+0}')
  minus=$(printf '%s\n' "$out" | awk '/^@@/{h=1;next} h&&/^-/{n++} END{print n+0}')
  printf '+%s / -%s' "$plus" "$minus"
}

# Up to five one-line points from the reviewer's SUMMARY block, control characters stripped and
# each line bounded. No block, or an unparseable one, prints nothing - the review still counts.
# The markers are anchored to a whole line: unanchored, a reviewer that names them in prose
# ("I'll put the points between SUMMARY BEGIN and SUMMARY END") opened and closed the block on
# that one line and the real summary below it was never read.
ps_headlines() {
  [ -s "$1" ] || return 1
  awk '
    /^[[:space:]]*SUMMARY BEGIN[[:space:]]*$/ { inblock = 1; next }
    inblock && /^[[:space:]]*SUMMARY END[[:space:]]*$/ { exit }
    !inblock { next }
    { gsub(/[[:cntrl:]]/, ""); sub(/^[[:space:]]*[-*][[:space:]]*/, ""); sub(/[[:space:]]+$/, "") }
    !length { next }
    # Never end inside a character. Under a byte-counting awk (LC_CTYPE=C, the usual case here)
    # a plain cut lands mid-sequence and the digest shows a replacement character, so the
    # trailing continuation bytes go first and then a lead byte left dangling. Costs at most one
    # whole character; a UTF-8-aware awk counts characters and neither sub matches.
    length > 110 {
      $0 = substr($0, 1, 110)
      sub(/[\200-\277]*$/, "", $0); sub(/[\300-\377]$/, "", $0)
      $0 = $0 "…"
    }
    { print; if (++n == 5) exit }
  ' "$1" 2>/dev/null
}

# The redirect has to come after 2>/dev/null: the other way round, a missing file makes the shell
# report the failed redirect on the real stderr and the suppression does nothing.
ps_lines() { wc -l 2>/dev/null < "$1" | tr -d ' '; }
