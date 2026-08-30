#!/usr/bin/env bash
# plan-sparring test suite. No framework: asserts, one process, exits non-zero on the first
# failure that matters. Run it from anywhere:  bash tests/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/hooks/plan-sparring.sh"
RUNNER="$ROOT/bin/plan-sparring-review"

export TMPDIR; TMPDIR="$(mktemp -d)"
export PLAN_SPARRING_BIN="$HERE/fake-backend"
export PLAN_SPARRING_TIMEOUT=8
trap 'rm -rf "$TMPDIR"' EXIT

. "$ROOT/lib/common.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 160)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "unexpected [$3]" ;; *) ok "$1" ;; esac; }

# --- helpers -----------------------------------------------------------------
ups() { jq -nc --arg s "$1" --arg m "$2" --arg t "${3:-}" \
        '{hook_event_name:"UserPromptSubmit",session_id:$s,permission_mode:$m,transcript_path:$t}'; }
gate() { jq -nc --arg s "$1" --arg t "${2:-}" --arg p "${3:-a plan}" \
        '{hook_event_name:"PreToolUse",session_id:$s,transcript_path:$t,tool_name:"ExitPlanMode",tool_input:{plan:$p}}'; }
answer() { jq -nc --arg c "Your questions have been answered: \"$PS_QUESTION\"=\"$1\". You can now continue." \
        '{message:{content:[{type:"tool_result",content:$c}]}}'; }
decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null; }
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

echo "== UserPromptSubmit =="
o=$(ups s1 default | bash "$HOOK"); check "default mode stays silent" "$o" ""
T="$TMPDIR/t1.jsonl"; : > "$T"
o=$(ups s1 plan "$T" | bash "$HOOK")
has "entering plan mode asks the route" "$o" "$PS_QUESTION"
has "offers the spar label verbatim" "$o" "$PS_LABEL_SPAR"
[ -d "$(ps_epoch_dir s1)" ] && ok "epoch created" || bad "epoch created"
o=$(ups s1 plan "$T" | bash "$HOOK"); check "second prompt in plan mode is silent" "$o" ""
o=$(ups s1 default "$T" | bash "$HOOK"); o=$(ups s1 plan "$T" | bash "$HOOK")
has "re-entering plan mode asks again" "$o" "$PS_QUESTION"
o=$(PLAN_SPARRING_BIN=/nonexistent-cli ups s2 plan "$T" | PLAN_SPARRING_BIN=/nonexistent-cli bash "$HOOK")
has "missing backend is visible, not silent" "$o" "was not found on PATH"
hasnt "missing backend offers no route" "$o" "$PS_QUESTION"
o=$(PLAN_SPARRING_OFF=1 ups s3 plan "$T" | PLAN_SPARRING_OFF=1 bash "$HOOK"); check "opt-out silences everything" "$o" ""

echo "== gate: routes =="
o=$(gate s1 "$T" | bash "$HOOK"); check "no route -> deny" "$(printf '%s' "$o" | decision)" "deny"
has "no-route denial asks the question" "$(printf '%s' "$o" | reason)" "Plan route"

answer "$PS_LABEL_DIRECT" >> "$T"
o=$(gate s1 "$T" | bash "$HOOK"); check "straight route -> allow" "$(printf '%s' "$o" | decision)" ""
[ -d "$(ps_epoch_dir s1)" ] && bad "epoch cleaned up after allow" || ok "epoch cleaned up after allow"

# fresh epoch, then a review-pass answer
T2="$TMPDIR/t2.jsonl"; : > "$T2"; ups s4 plan "$T2" | bash "$HOOK" >/dev/null
D=$(ps_epoch_dir s4)
answer "$PS_LABEL_PASS" >> "$T2"
o=$(gate s4 "$T2" "the plan body" | bash "$HOOK")
check "review-pass without receipt -> deny" "$(printf '%s' "$o" | decision)" "deny"
has "denial names the runner" "$(printf '%s' "$o" | reason)" "plan-sparring-review --epoch"
[ -s "$D/plan.md" ] && ok "hook captured the plan text" || bad "hook captured the plan text"
check "captured plan is the real text" "$(cat "$D/plan.md")" "the plan body"

echo "== gate: stale answers =="
T3="$TMPDIR/t3.jsonl"; answer "$PS_LABEL_DIRECT" > "$T3"   # answered BEFORE the epoch opens
ups s5 plan "$T3" | bash "$HOOK" >/dev/null
o=$(gate s5 "$T3" | bash "$HOOK")
check "answer before the epoch offset does not count" "$(printf '%s' "$o" | decision)" "deny"

echo "== gate: malformed transcript =="
T4="$TMPDIR/t4.jsonl"; : > "$T4"; ups s6 plan "$T4" | bash "$HOOK" >/dev/null
cat "$HERE/fixtures/malformed.jsonl" >> "$T4"
o=$(gate s6 "$T4" | bash "$HOOK")
check "broken JSONL line does not break route parsing" "$(printf '%s' "$o" | decision)" ""

echo "== runner =="
o=$(FAKE_MODE=agreed bash "$RUNNER" --epoch "$D" 2>&1); rc=$?
check "runner exits 0 on success" "$rc" "0"
has "runner prints the review" "$o" "Looks sound."
check "receipt outcome agreed" "$(jq -r .outcome "$D/receipt.json")" "agreed"
check "receipt bound to the epoch" "$(jq -r .epoch "$D/receipt.json")" "$(cat "$D/id")"
[ -s "$D/thread" ] && ok "thread id captured for later rounds" || bad "thread id captured"
o=$(gate s4 "$T2" | bash "$HOOK"); check "review-pass with receipt -> allow" "$(printf '%s' "$o" | decision)" ""

# spar route needs agreement, not just a receipt
T5="$TMPDIR/t5.jsonl"; : > "$T5"; ups s7 plan "$T5" | bash "$HOOK" >/dev/null
D7=$(ps_epoch_dir s7); answer "$PS_LABEL_SPAR" >> "$T5"
gate s7 "$T5" "plan seven" | bash "$HOOK" >/dev/null
FAKE_MODE=objections bash "$RUNNER" --epoch "$D7" >/dev/null 2>&1
check "objections receipt written" "$(jq -r .outcome "$D7/receipt.json")" "objections"
o=$(gate s7 "$T5" "plan seven" | bash "$HOOK")
check "spar route with objections -> still deny" "$(printf '%s' "$o" | decision)" "deny"
FAKE_MODE=agreed bash "$RUNNER" --epoch "$D7" >/dev/null 2>&1
check "second round counts up" "$(jq -r .round "$D7/receipt.json")" "2"
o=$(gate s7 "$T5" "plan seven" | bash "$HOOK")
check "spar route with agreement -> allow" "$(printf '%s' "$o" | decision)" ""

echo "== runner failures =="
T6="$TMPDIR/t6.jsonl"; : > "$T6"; ups s8 plan "$T6" | bash "$HOOK" >/dev/null
D8=$(ps_epoch_dir s8); answer "$PS_LABEL_PASS" >> "$T6"
gate s8 "$T6" "plan eight" | bash "$HOOK" >/dev/null
FAKE_MODE=fail bash "$RUNNER" --epoch "$D8" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "runner exits non-zero when the backend fails" || bad "runner exits non-zero when the backend fails"
[ -f "$D8/receipt.json" ] && bad "no receipt on failure" || ok "no receipt on failure"
FAKE_MODE=empty bash "$RUNNER" --epoch "$D8" >/dev/null 2>&1
[ -f "$D8/receipt.json" ] && bad "no receipt on empty review" || ok "no receipt on empty review"
check "failures counted" "$(cat "$D8/fails")" "2"
o=$(gate s8 "$T6" "plan eight" | bash "$HOOK")
check "repeated failure still denies" "$(printf '%s' "$o" | decision)" "deny"
has "repeated failure asks the user" "$(printf '%s' "$o" | reason)" "Retry"
has "escape offers the verbatim direct label" "$(printf '%s' "$o" | reason)" "$PS_LABEL_DIRECT"
o=$(FAKE_MODE=hang PLAN_SPARRING_TIMEOUT=4 bash "$RUNNER" --epoch "$D8" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "runner times out instead of hanging" || bad "runner times out"
has "timeout is explained" "$o" "did not answer within"

echo "== foreign receipt =="
# Clear the failure count first, otherwise the deny would come from the escape path and this
# test would pass without ever exercising the epoch binding.
echo 0 > "$D8/fails"
jq -n '{epoch:"some-other-epoch",backend:"x",model:"x",thread:"t",round:1,input_sha256:"a",output_sha256:"b",status:"ok",outcome:"agreed"}' > "$D8/receipt.json"
o=$(gate s8 "$T6" "plan eight" | bash "$HOOK")
check "receipt from another epoch is rejected" "$(printf '%s' "$o" | decision)" "deny"
has "rejection is about the missing review, not the escape" "$(printf '%s' "$o" | reason)" "still needs one"
# And the same receipt, correctly bound, opens the gate.
jq --arg e "$(cat "$D8/id")" '.epoch=$e' "$D8/receipt.json" > "$D8/r.tmp" && mv "$D8/r.tmp" "$D8/receipt.json"
o=$(gate s8 "$T6" "plan eight" | bash "$HOOK")
check "same receipt with the right epoch is accepted" "$(printf '%s' "$o" | decision)" ""

echo "== exit codes =="
for ev in UserPromptSubmit PreToolUse; do
  jq -nc --arg e "$ev" '{hook_event_name:$e,session_id:"s9"}' | bash "$HOOK" >/dev/null 2>&1
  check "$ev never exits non-zero" "$?" "0"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
