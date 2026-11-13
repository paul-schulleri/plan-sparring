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

# --- accounts ----------------------------------------------------------------
# One login per home directory: the CLI keeps and refreshes its own tokens in there, so choosing
# an account is choosing a directory and nothing else - there is no secret for this plugin to hold.
# One entry per line, "Name=directory". Empty (the default) means the plugin never touches the
# CLI's home and the account question is not asked at all, which is what someone with a single
# login wants. The directory name is the ONLY vendor-specific part; which variable carries it
# lives in ps_backend_run(), with the rest of the protocol.
PS_ACCOUNTS="${PLAN_SPARRING_ACCOUNTS:-}"

# The configured accounts as "name<TAB>home" lines. Anything malformed is DROPPED rather than
# guessed at: a half-understood entry would put a label in front of the user that the gate then
# cannot resolve, and the round would deny with nothing to act on.
#  - a name with a double quote in it could not be read back out of the transcript, where the
#    answer arrives as "question"="label";
#  - a control character in either field would travel into a systemMessage;
#  - a repeated name makes the user's answer ambiguous, so only its first entry survives.
ps_accounts() {
  printf '%s\n' "$PS_ACCOUNTS" | awk '
    { i = index($0, "=") ; if (i < 2) next
      name = substr($0, 1, i - 1); home = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", home)
      if (name == "" || home == "") next
      if (name ~ /"/ || name ~ /[[:cntrl:]]/ || home ~ /[[:cntrl:]]/) next
      if (seen[name]++) next
      print name "\t" home }'
}
ps_account_names() { ps_accounts | cut -f1; }
ps_account_count() { ps_accounts | grep -c . ; }
# The home for a name, or nothing and a non-zero status when the name is not configured - the
# caller has to be able to tell "not configured" from "configured as the empty string".
ps_account_home() {
  ps_accounts | awk -F'\t' -v n="$1" '$1 == n { print $2; found = 1; exit } END { exit !found }'
}

# --- the question and its labels ---------------------------------------------
# Every question the plugin asks - including the one after a failure - uses PS_QUESTION verbatim.
# Only the header differs. A fallback question with its own wording would not be recognised here
# and the user's escape would silently do nothing.
PS_QUESTION="How should this plan be produced?"
# Asked alongside PS_QUESTION whenever more than one account is configured. Deliberately free of
# PS_BACKEND_NAME: both questions are matched with `grep -o` below, so a backend named "C++" or
# "gpt.5" would turn the anchor into a regex that matches the wrong thing - or nothing at all.
PS_QUESTION_ACCOUNT="Which account should review this plan?"
PS_LABEL_SPAR="Spar with ${PS_BACKEND_NAME}"
PS_LABEL_PASS="One review pass"
PS_LABEL_DIRECT="Straight from Claude"
PS_LABEL_ACCEPT="Present it as it stands"   # offered once the rounds run out
PS_LABEL_MORE="Keep sparring"               # grants another budget when the rounds run out
PS_LABEL_RETRY="Retry"          # keeps the current route; ignored when resolving it
# Auto mode's only way out at a halt besides more rounds: the user ends the phase with #manualplan.
# There is no "go ahead as it stands" there - an answer cannot be bound to the draft it was for.
PS_LABEL_STOP_AUTO="Stop auto mode"

# --- state -------------------------------------------------------------------
umask 077
# macOS hands out TMPDIR with a trailing slash. Kept, it put "//" into every path this plugin prints,
# and a path Claude is told to write never matched the normalised one the Write tool reports.
PS_ROOT="${TMPDIR:-/tmp}"; PS_ROOT="${PS_ROOT%/}/plan-sparring"

ps_sid() { printf '%s' "${1:-nosid}" | tr -cd 'A-Za-z0-9._-' | cut -c1-64; }
ps_mode_file() { printf '%s/mode-%s' "$PS_ROOT" "$(ps_sid "$1")"; }
ps_epoch_dir() { printf '%s/ep-%s' "$PS_ROOT" "$(ps_sid "$1")"; }
# Auto mode's plan phase. Its own directory, not the epoch: the epoch belongs to plan mode and is
# wiped on every entry into it, and the phase must survive the user toggling modes.
ps_auto_dir() { printf '%s/auto-%s' "$PS_ROOT" "$(ps_sid "$1")"; }
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
  size=$(wc -c 2>/dev/null < "$tp" | tr -d ' '); [ -n "$size" ] || size=0
  # A truncated or replaced transcript would leave a stale offset past the end of the file and
  # hide every later answer: the gate would deny forever with no way out.
  if [ "$off" -gt "$size" ] 2>/dev/null; then off=0; fi
  tail -c "+$((off + 1))" "$tp" 2>/dev/null
}

# Every label the user picked in answer to one question, oldest first, one per line.
#   - only answers AFTER the epoch offset count, so an earlier round cannot authorise this one
#   - the answer must belong to an actual AskUserQuestion tool call carrying that question, so a
#     tool that merely PRINTS the answer string cannot choose anything
# The question text is used as a grep pattern, which is why both question strings above are kept
# free of regex metacharacters.
# $1 transcript, $2 offset, $3 question
ps_answers() {
  local recs ids id ans line label
  recs=$(ps_records_since "$1" "$2")
  [ -n "$recs" ] || return 0
  ids=$(printf '%s\n' "$recs" | jq -Rr --arg q "$3" '
      fromjson? // empty | .message.content[]?
      | select(.type == "tool_use" and .name == "AskUserQuestion")
      | select((.input | tostring) | contains($q)) | .id' 2>/dev/null)
  [ -n "$ids" ] || return 0

  # Unquoted on purpose: jq printed one id per line and this splits on them. The ids are hex-and-
  # dash tool_use ids, so there is nothing here for a glob to match.
  for id in $ids; do
    ans=$(printf '%s\n' "$recs" | jq -Rr --arg id "$id" '
        fromjson? // empty | .message.content[]?
        | select(.type == "tool_result" and .tool_use_id == $id)
        | .. | strings' 2>/dev/null | grep -o "$3\"=\"[^\"]*\"")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      label=${line#*\"=\"}; label=${label%\"}
      printf '%s\n' "$label"
    done <<< "$ans"
  done
}

# Which route did the user pick?
#   - labels are compared for equality, not substring
#   - "Retry" answers are skipped, so the last real route survives a failure dialogue
#   - the extension label is counted, not just routed: each one buys another round budget
# $1 transcript, $2 offset -> two lines, the route (spar|pass|direct|accept|empty) and how many
# times the user asked to keep sparring after the budget ran out
ps_route() {
  # more=0 is load-bearing, not decoration: from bash 4.4 on, `local more` leaves the variable
  # UNSET rather than null, so under the callers' set -u every ordinary route - the ones where no
  # extension was ever granted - would die on "$more" before printing anything.
  local label out="" more=0
  while IFS= read -r label; do
    case "$label" in
      "$PS_LABEL_DIRECT") out=direct ;;
      "$PS_LABEL_ACCEPT") out=accept ;;
      "$PS_LABEL_PASS")   out=pass ;;
      "$PS_LABEL_SPAR")   out=spar ;;
      "$PS_LABEL_MORE")   out=spar; more=$((more + 1)) ;;
      *) : ;;   # "Retry", "Cancel planning", free text: leave the current route alone
    esac
  done <<< "$(ps_answers "$1" "$2" "$PS_QUESTION")"
  printf '%s\n%s\n' "$out" "$more"
}

# Which account did the user pick? The last answer that names a CONFIGURED account wins; anything
# else is ignored, exactly as an unknown route label is - a name that was configured away between
# two rounds must not select a home that no longer exists.
# $1 transcript, $2 offset -> the account name, or nothing
ps_account_pick() {
  local label out=""
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    ps_account_home "$label" >/dev/null || continue
    out="$label"
  done <<< "$(ps_answers "$1" "$2" "$PS_QUESTION_ACCOUNT")"
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
ps_receipt() {   # $1 = epoch dir -> epoch, status, outcome, input_sha256, round, headlines, account
  jq -sr 'if length == 1 then .[0] else {} end
          | [ (.epoch // ""), (.status // ""), (.outcome // ""), (.input_sha256 // ""),
              (.round // 0), ((.headlines | arrays | length) // 0), (.account // "") ]
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

# How many rounds this plan is allowed before the gate stops and asks. Each time the user chose
# to keep sparring buys one more budget, so the question comes back once per budget instead of
# once per round - the whole point of the extension label.
# PS_MAX_ROUNDS comes straight out of the environment and is not a number until it has been
# checked: `[ 3 -ge abc ]` FAILS rather than errors, which used to remove the cap altogether, and
# the same value inside $(( )) is worse than that. At least 1, so a budget of 0 cannot demand a
# decision before the first round has even run.
ps_budget() {   # $1 = how many extensions the user granted -> the round budget
  local step more
  step=$(ps_num "$PS_MAX_ROUNDS"); [ "$step" -ge 1 ] || step=1
  more=$(ps_num "${1:-0}")
  printf '%s' "$(( step * (more + 1) ))"
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
# The two marker strings are asked for by the prompt in bin/plan-sparring-review; the pair has to
# match. Left as literals on both sides on purpose - see the anchor reason above.
ps_headlines() {
  [ -s "$1" ] || return 1
  # The byte ranges below are invalid in some UTF-8 awk locales; parse them as bytes everywhere.
  LC_ALL=C awk '
    /^[[:space:]]*SUMMARY BEGIN[[:space:]]*$/ { inblock = 1; next }
    inblock && /^[[:space:]]*SUMMARY END[[:space:]]*$/ { exit }
    !inblock { next }
    { gsub(/[[:cntrl:]]/, ""); sub(/^[[:space:]]*[-*][[:space:]]*/, ""); sub(/[[:space:]]+$/, "") }
    !length { next }
    # Never end inside a character. Under byte-counting awk (LC_ALL=C above)
    # a plain cut lands mid-sequence and the digest shows a replacement character, so the
    # trailing continuation bytes go first and then a lead byte left dangling. Costs at most one
    # whole character.
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
