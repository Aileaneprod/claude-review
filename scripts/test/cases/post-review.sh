# post-review.sh — the script that decides what the author actually reads.
#
# It had no tests at all until now, which is how both of these survived:
#
#   * the summary was whatever assistant text came last, with no check that it
#     WAS a summary. The sticky comment is a PATCH, so a run ending on "I will
#     check the auth module next" replaced the previous push's real summary with
#     that sentence, and nothing in the comment said so.
#   * the fallback that adopts a summary the reviewer posted itself recognised
#     one by the literal English `| Severity | Count |` or `🔴 Blocking`.
#     Aileaneprod/korbyx — the repository this tool was built for — runs with
#     `language: français` and emits `| Severite | Nombre |` and `🔴 Bloquant`.
#     The fallback could never fire there. base.md prescribes the emoji
#     literally and the words not at all, so the emoji are the part that
#     survives translation.
#
# Both cases below fail against the code that had the bug.
#
# `gh` is replaced by an exported shell function rather than a file on PATH: no
# executable bit to set, which this repository has already been bitten by, and
# `command -v gh` finds a function.

_gh_log()      { printf '%s' "$TESTTMP/pr-gh.log"; }
_gh_comments() { printf '%s' "$TESTTMP/pr-issue-comments.json"; }

# _setup [ISSUE_COMMENTS_JSON] — default: the PR has no comments yet.
_setup() {
  export GH_LOG="$(_gh_log)"
  export GH_ISSUE_COMMENTS="$(_gh_comments)"
  : > "$GH_LOG"
  printf '%s' "${1:-[]}" > "$GH_ISSUE_COMMENTS"
  rm -f "$TESTTMP/pr-posted"

  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *--method*)              echo '{}' ;;
      *issues/*/comments*)     cat "$GH_ISSUE_COMMENTS" ;;
      *)                       echo '[]' ;;
    esac
  }
  export -f gh
}

_post() {
  "$SCRIPTS/post-review.sh" --mode post --repo o/r --pr 1 \
    --execution-file "$FIXTURES/$1" --posted-out "$TESTTMP/pr-posted"
}

# _posted FIXTURE — the witness the workflow reads to decide whether to say
# "AI review unavailable".
_posted() {
  _post "$1" >/dev/null 2>&1
  cat "$TESTTMP/pr-posted" 2>/dev/null || echo "(no witness written)"
}

_calls() { cat "$(_gh_log)"; }

# A summary as korbyx actually receives it: header translated, emoji not.
_FR_BODY='{"id": 77, "body": "Recapitulatif\n\n| Severite | Nombre |\n|---|---|\n| 🔴 Bloquant | 0 |\n| 🟠 Important | 1 |\n| 🟡 Mineur | 0 |\n"}'

# --- a completed review is posted, and says so -------------------------------

it "posts a recovered summary and records that it landed"
_setup
assert_equal "true" "$(_posted summary-french.json)" "the witness says a comment landed"
assert_contains "--method POST" "a new sticky comment was created" -- _calls

# --- the shape guard ----------------------------------------------------------

it "does not mistake the reviewer's next thought for the summary"
# The last assistant text is a plan. Posting it would overwrite a good summary
# with one sentence, on a run the action had already flagged.
_setup
assert_equal "false" "$(_posted summary-fragment.json)" "a fragment is not posted"
assert_not_contains "--method" "nothing was written to the PR" -- _calls

it "says why it refused, so the log is not a silence"
_setup
assert_contains "no counts table" "the refusal is explained" -- _post summary-fragment.json

# --- the fallback that could never fire in French -----------------------------

it "adopts a French summary the reviewer posted itself"
# No assistant text to recover, but the reviewer left its own summary as a
# comment. The old heuristic looked for '| Severity | Count |' or '🔴 Blocking';
# this body carries neither, and korbyx emits nothing else.
_setup "[$_FR_BODY]"
assert_equal "true" "$(_posted summary-absent.json)" "the French summary is recognised"
assert_contains "issues/comments/77 --method PATCH" "it adopted that very comment" -- _calls

it "stays silent when there is nothing to adopt either"
_setup
assert_equal "false" "$(_posted summary-absent.json)" "no summary, no comment"
assert_not_contains "--method" "the PR is left alone" -- _calls

# --- the witness must never read as a yes by accident ------------------------

it "writes the pessimistic answer before it can be upgraded"
# post-review.sh writes `false` on the way in, so a crash between there and the
# API call cannot leave the workflow believing a comment was posted.
_setup
rm -f "$TESTTMP/pr-posted"
"$SCRIPTS/post-review.sh" --mode post --repo o/r --pr 1 \
  --execution-file "$FIXTURES/does-not-exist.json" \
  --posted-out "$TESTTMP/pr-posted" >/dev/null 2>&1 || true
assert_equal "false" "$(cat "$TESTTMP/pr-posted" 2>/dev/null || echo MISSING)" \
  "an execution file that is not there still answers the question"
