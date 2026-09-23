# should-fall-back.sh decides whether a review may be run a SECOND time, on
# another account's quota. Both ways of getting that wrong are expensive:
#
#   * saying no when it should say yes turns a usage limit back into an outage,
#     which is the whole thing the fallback exists to prevent;
#   * saying yes when it should say no reruns a review that had already posted
#     inline findings — a second copy of every one of them on a pull request
#     whose author has read the first — and spends a second subscription on it.
#
# The second is the one that does damage, so most of the cases below are about
# refusing. The shape of "yes" is taken from the real refusal of 2026-09-22:
# api_error_status 429, num_turns 1, total_cost_usd 0.

_SFB="$SCRIPTS/should-fall-back.sh"

# _record STATUS TURNS COST — one result record, the shape the action writes.
# Pass `absent` to leave a field out entirely.
_record() {
  python3 - "$TESTTMP/sfb.json" "$1" "$2" "$3" <<'PY'
import json
import sys

out, status, turns, cost = sys.argv[1:5]
result = {"type": "result", "subtype": "success", "is_error": True}
for key, raw in (("api_error_status", status), ("num_turns", turns), ("total_cost_usd", cost)):
    if raw == "absent":
        continue
    result[key] = json.loads(raw)
json.dump([{"type": "system", "subtype": "init"}, result], open(out, "w", encoding="utf-8"))
PY
}

# _decide [AVAILABLE] — run it on the current record, print the decision word.
_decide() {
  rm -f "$TESTTMP/sfb.out"
  "$_SFB" --execution-file "$TESTTMP/sfb.json" --decision-out "$TESTTMP/sfb.out" \
    --fallback-available "${1:-yes}" >/dev/null 2>&1
  cat "$TESTTMP/sfb.out" 2>/dev/null || printf '(no decision written)'
}

# --- yes: the refusal it exists for -------------------------------------------

it "retries a first attempt refused on quota before it did anything"
_record 429 1 0
assert_equal "yes" "$(_decide)" "429 on turn 1 at zero cost"

it "retries a rejected credential the same way"
_record 401 1 0
assert_equal "yes" "$(_decide)" "401 is another account's to cure too"
_record 403 1 0
assert_equal "yes" "$(_decide)" "and so is 403"

it "matches the real refusal recorded from production"
cp "$FIXTURES/api-429-quota.json" "$TESTTMP/sfb.json"
assert_equal "yes" "$(_decide)" "the 2026-09-22 shape, not a guess at it"
cp "$FIXTURES/auth-401.json" "$TESTTMP/sfb.json"
assert_equal "yes" "$(_decide)" "and the credential-refusal fixture the classifier is tested on"

# --- no: everything that would do damage --------------------------------------

it "never reruns a review that got past its first turn"
_record 429 12 0
assert_equal "no" "$(_decide)" "a limit hit mid-review is not retried"

it "never reruns a review that spent anything"
_record 429 1 0.07
assert_equal "no" "$(_decide)" "a cost means something was generated"

it "does not spend another account on an outage no account can fix"
_record 529 1 0
assert_equal "no" "$(_decide)" "5xx is the service, not the account"

it "does not retry a review that simply finished"
_record absent 9 0.30
assert_equal "no" "$(_decide)" "no error status, no retry"

it "treats a missing fact as something having happened"
# A field the action did not write is not evidence of zero. Reading `absent`
# as 0 turns or $0 would retry on exactly the records it cannot see into.
_record 429 absent 0
assert_equal "no" "$(_decide)" "no turn count, no proof nothing ran"
_record 429 1 absent
assert_equal "no" "$(_decide)" "no cost, no proof nothing was spent"

it "reads a boolean as no number at all"
# python counts True as the int 1 and False as 0, and `False in (0, 0.0)` is
# True. A turn count of `true` would read as one turn, a cost of `false` as
# nothing spent — both are the "nothing happened" that earns a second review.
_record 429 true 0
assert_equal "no" "$(_decide)" "true is not a turn count"
_record 429 1 false
assert_equal "no" "$(_decide)" "false is not a cost"

it "does nothing without a fallback credential to fall back to"
_record 429 1 0
assert_equal "no" "$(_decide no)" "the refusal alone is not enough"

it "says no when there is no execution file to read"
rm -f "$TESTTMP/sfb.json"
assert_equal "no" "$(_decide)" "no evidence, no second review"

it "says no when the execution file is not JSON"
printf 'not json' > "$TESTTMP/sfb.json"
assert_equal "no" "$(_decide)" "an unreadable file is not a refusal"

# --- the decision survives a crash --------------------------------------------
#
# The pessimistic word is written before anything can fail to replace it, so a
# decision step that dies can only ever leave `no`. Seed a stale `yes` and give
# it a file it cannot read: the stale answer must not survive.

it "leaves no, never a stale yes, when it cannot decide"
printf 'yes' > "$TESTTMP/sfb.out"
printf 'not json' > "$TESTTMP/sfb.json"
"$_SFB" --execution-file "$TESTTMP/sfb.json" --decision-out "$TESTTMP/sfb.out" \
  --fallback-available yes >/dev/null 2>&1
assert_equal "no" "$(cat "$TESTTMP/sfb.out")" "an earlier yes is overwritten, not inherited"

it "never fails the job"
rm -f "$TESTTMP/sfb.json"
assert_status 0 "exits 0 with no execution file" -- \
  "$_SFB" --execution-file "$TESTTMP/sfb.json" --decision-out "$TESTTMP/sfb.out" --fallback-available yes
