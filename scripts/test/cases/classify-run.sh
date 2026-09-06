# classify-run.sh — the one gate that decides whether the reviewer completed.
#
# It exists because `steps.claude.outcome` was asked that question for months
# and cannot answer it. `claude-code-action` validates the turn count AFTER the
# run and fails the step when `num_turns` exceeds `--max-turns`, even when the
# CLI reported success. On Aileaneprod/korbyx#110, run 34058925818, a finished
# review — subtype success, terminal_reason completed, 43 turns, $0.87 — was
# announced to the author as "AI review unavailable" and thrown away.
#
# Two properties matter more than the happy path, and both have a case here:
#
#   * every answer this script cannot establish must be `unavailable`, because
#     that is the branch that speaks to the author. `completed` is a claim that
#     a review happened, and a claim is not a default.
#   * it must never fail the job. It runs after a review that may already have
#     failed; a crash here would take the notice down with it.

# _verdict FIXTURE — the word written to --verdict-out, which is what the
# workflow reads. Asserting on stdout would let a prose change pass for a
# behaviour change.
_verdict() {
  local out="$TESTTMP/classify-verdict"
  rm -f "$out"
  "$SCRIPTS/classify-run.sh" --execution-file "$1" --verdict-out "$out" >/dev/null 2>&1
  cat "$out" 2>/dev/null || echo "(no verdict file written)"
}

_run() { "$SCRIPTS/classify-run.sh" --execution-file "$1"; }

# --- the run that motivated all of this --------------------------------------

it "calls a finished review completed, whatever the action's exit code said"
# system-init-record.json IS run 34058925818's shape: subtype success,
# is_error false, 43 turns against a ceiling of 40.
assert_equal "completed" "$(_verdict "$FIXTURES/system-init-record.json")" \
  "a successful result record is the review having happened"
assert_contains "num_turns=43" "the verdict says what it read" -- _run "$FIXTURES/system-init-record.json"

# --- everything else is unavailable ------------------------------------------

it "reads the LAST result record, not any result record"
# An early success followed by a real failure. "Contains a success record"
# passes this fixture and publishes a summary for a run that died.
assert_equal "unavailable" "$(_verdict "$FIXTURES/result-success-then-error.json")" \
  "a later failure overrides an earlier success"

it "does not read an absent is_error as a good one"
# subtype is success and the field is simply not there. `not is_error` would
# call that a pass; `is False` does not.
assert_equal "unavailable" "$(_verdict "$FIXTURES/result-no-is-error.json")" \
  "an unstated fact is not a fact"

it "treats a run with no result record as unfinished"
assert_equal "unavailable" "$(_verdict "$FIXTURES/no-result-record.json")" \
  "assistant chatter is not a completed review"

it "treats error_max_turns as unfinished"
# The distinction this whole script draws: error_max_turns is the CLI STOPPING
# at the ceiling, which is not the same as the action complaining afterwards
# about a run that finished past it.
assert_equal "unavailable" "$(_verdict "$FIXTURES/denials-authoritative.json")" \
  "stopping at the ceiling is not finishing"

it "treats an errored run as unfinished"
assert_equal "unavailable" "$(_verdict "$FIXTURES/auth-401.json")" \
  "a 401 is not a completed review"

it "treats an unreadable execution file as unfinished"
assert_equal "unavailable" "$(_verdict "$FIXTURES/malformed.json")" \
  "unparseable input cannot prove a review happened"

it "treats a missing execution file as unfinished"
assert_equal "unavailable" "$(_verdict "$FIXTURES/does-not-exist.json")" \
  "no file means the action never wrote one"

# --- it must never fail the job ----------------------------------------------

it "exits 0 on every input"
assert_status 0 "a completed run exits 0"   -- _run "$FIXTURES/system-init-record.json"
assert_status 0 "a malformed file exits 0"  -- _run "$FIXTURES/malformed.json"
assert_status 0 "a missing file exits 0"    -- _run "$FIXTURES/does-not-exist.json"

it "still answers when no --verdict-out is given"
assert_contains "unavailable" "the human-readable line stands alone" -- _run "$FIXTURES/auth-401.json"
