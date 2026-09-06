# explain-failure.sh — runs on the path where the review has ALREADY failed, so
# nothing here may fail the job, and everything it prints is read by someone
# deciding whether to trust the comments on their pull request.
#
# Two of these cases exist because earlier versions were wrong in ways their own
# fixtures could not reveal:
#
#   * denial reporting read `name` off the `tool_result` block, where it never
#     exists (the name is on the `tool_use`, joined by `tool_use_id`), and then
#     treated any `is_error` as a denial — so an ordinary failed Read was
#     reported as a permissions problem. `result.permission_denials` is what the
#     CLI itself calls "the authoritative record"; use it.
#   * `posted` counted `create_inline_comment` tool_use blocks without checking
#     whether the call succeeded, so the notice could claim findings that were
#     never posted — in the code whose whole purpose is to stop the workflow
#     misreporting what it produced.

_exec() { "$SCRIPTS/explain-failure.sh" --execution-file "$FIXTURES/$1"; }

# --- denials come from the authoritative field, not from guesswork -----------

it "names denied tools from result.permission_denials"
assert_contains "Bash x2" "Bash denials are named"     -- _exec denials-authoritative.json
assert_contains "WebFetch x1" "WebFetch denial is named" -- _exec denials-authoritative.json

it "does not treat an ordinary failed tool call as a denial"
# This fixture has a failed Read (missing file) and permission_denials: [].
assert_not_contains "denied tools" "a failed Read is not reported as a denial" -- _exec no-denials-one-failed-read.json

it "says so when the count is present but the names are not"
assert_contains "names not recorded" "a bare count is reported honestly" -- _exec denials-count-only.json

# --- posted findings must be POSTED, not merely attempted --------------------

it "counts only inline comments that actually succeeded"
# Two create_inline_comment calls: the first succeeds, the second returns
# is_error. Reporting 2 tells the author to look for a comment that is not there.
assert_contains "findings posted    1" "a failed post is not counted" -- _exec posted-one-succeeded-one-failed.json

it "counts a fully successful run correctly"
assert_contains "findings posted    2" "two successful posts are counted" -- _exec posted-two-succeeded.json

# --- it must never fail the job ----------------------------------------------

it "survives a malformed execution file"
assert_status 0 "unreadable file exits 0" -- _exec malformed.json
assert_contains "unreadable" "unreadable file says why" -- _exec malformed.json

it "survives a missing execution file"
assert_status 0 "missing file exits 0" -- _exec does-not-exist.json
assert_contains "no execution file" "missing file says why" -- _exec does-not-exist.json

it "reports the credential hint on a 401"
assert_contains "setup-token" "401 suggests regenerating the token" -- _exec auth-401.json

it "reports the turn-budget hint on error_max_turns"
assert_contains "ran out of turns" "error_max_turns is explained" -- _exec denials-authoritative.json

# --- the count file the workflow reads ---------------------------------------

it "writes the posted count to --count-out"
_count() {
  local out="$TESTTMP/count"
  # Remove it first: this helper used to read whatever the previous case left
  # behind, so a run that wrote nothing at all could still be scored against a
  # stale value from the case before it.
  rm -f "$out"
  "$SCRIPTS/explain-failure.sh" --execution-file "$FIXTURES/$1" --count-out "$out" >/dev/null 2>&1
  cat "$out" 2>/dev/null || echo "(no count file written)"
}
assert_equal "1" "$(_count posted-one-succeeded-one-failed.json)" "count-out reflects successful posts only"
assert_equal "0" "$(_count malformed.json)" "count-out is 0 for an unreadable file"

# --- the record every real run carries ---------------------------------------
#
# `{"type":"system","subtype":"init","message":"Claude Code initialized"}` opens
# EVERY execution file the action writes. Its `message` is a plain string, and
# `content_blocks` did `(message.get("message") or {}).get("content")` — so the
# string survived the `or` and the `.get` raised AttributeError on the very
# first record of every run.
#
# The consequence was invisible because the workflow calls this script with
# `|| true`: the diagnostic printed its header rows, died before the count, and
# never wrote --count-out. The notice therefore read `posted=0` and said "AI
# review unavailable" on runs that had posted real findings. The "stopped early,
# N findings were posted first" branch had never once been reached in production.
#
# Every fixture above builds `message` as a dict, which is exactly the shape the
# crash needed to be absent.

it "survives the system init record that opens every real execution file"
assert_status 0 "a string-valued message field does not crash the diagnostic" -- _exec system-init-record.json
assert_contains "findings posted    1" "the count is still reached and correct" -- _exec system-init-record.json
assert_contains "Bash x1" "denials are still reported" -- _exec system-init-record.json
assert_equal "1" "$(_count system-init-record.json)" "--count-out is written despite the init record"
