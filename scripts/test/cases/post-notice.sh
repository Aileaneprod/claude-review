# post-notice.sh — the notice comment stops stacking, and retracts itself.
#
# The sibling case file for publish-outcome-check.sh already names this defect
# in a comment — "the stacking defect, which the notice comment already has" —
# and then tests only the check run. These are the cases for the other half.
#
# Measured on Aileaneprod/korbyx, 2026-11-04: five notices on #746, three each
# on #677 and #735, and on #735/#626/#665/#677 a real review that landed into
# a sticky created days earlier while the last visible comment still read
# "This push was not reviewed". A handover written from those four pull
# requests concluded four reviews were missing. All four had been delivered.
#
# `gh` is an exported shell function, not a file on PATH — same reason as the
# sibling cases: no executable bit to lose, and `command -v gh` finds it.

_SHA="0123456789abcdef0123456789abcdef01234567"
_OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"

_calls() { cat "$TESTTMP/pn-gh.log"; }
_state() { cat "$TESTTMP/pn-state" 2>/dev/null || echo "(no state written)"; }

# _setup SCENARIO — seeds the comment list the stubbed `gh` will answer with.
_setup() {
  export GH_LOOKUP="$TESTTMP/pn-lookup.json"
  export GH_LOG="$TESTTMP/pn-gh.log"
  : > "$GH_LOG"
  rm -f "$TESTTMP/pn-state"

  python3 - "$GH_LOOKUP" "${1:-empty}" "$_SHA" "$_OTHER_SHA" <<'PY'
import json
import sys

path, scenario, sha, other_sha = sys.argv[1:5]

ROBOT = "\U0001F916"
TAIL = "This does not block merging."
BOT = {"login": "github-actions[bot]", "type": "Bot"}
HUMAN = {"login": "firas", "type": "User"}


def notice(cid, for_sha):
    return {"id": cid, "user": BOT, "created_at": "2026-11-01T00:00:00Z",
            "body": "<!-- claude-review:notice sha=%s -->\n%s A thing. %s"
                    % (for_sha, ROBOT, TAIL)}


def legacy(cid, when):
    return {"id": cid, "user": BOT, "created_at": when,
            "body": "%s This push was not reviewed: the subscription hit its "
                    "usage limit. %s" % (ROBOT, TAIL)}


def stub(cid, when):
    """A notice an earlier run already collapsed."""
    return {"id": cid, "user": BOT, "created_at": when,
            "body": "<!-- claude-review:notice -->" + "\n"
                    + "_Superseded - see the current notice at the end of "
                      "this pull request._"}


def summary(cid):
    return {"id": cid, "user": BOT, "created_at": "2026-10-01T00:00:00Z",
            "body": "<!-- claude-review:summary -->\nWalkthrough — the real "
                    "review of this pull request."}


def human(cid):
    return {"id": cid, "user": HUMAN, "created_at": "2026-10-02T00:00:00Z",
            "body": "%s I agree, this does not block merging. %s"
                    % (ROBOT, TAIL)}


sets = {
    "empty": [],
    "same-sha": [notice(11, sha)],
    "other-sha": [notice(22, other_sha)],
    "legacy-pile": [legacy(31, "2026-11-03T12:50:04Z"),
                    legacy(32, "2026-11-04T07:42:15Z")],
    # Everything that must survive untouched, in one list.
    "bystanders": [summary(41), human(42)],
    "legacy-plus-summary": [summary(51), legacy(52, "2026-11-04T07:42:15Z")],
    "stubs-only": [stub(61, "2026-11-03T12:50:04Z"),
                   stub(62, "2026-11-03T15:09:25Z")],
    "stubs-plus-live": [stub(71, "2026-11-03T12:50:04Z"), notice(72, sha)],
    "stub-plus-summary": [summary(81), stub(82, "2026-11-03T12:50:04Z")],
}

# `gh api --paginate --slurp` answers with an array of PAGES.
with open(path, "w", encoding="utf-8") as handle:
    json.dump([sets[scenario]], handle)
PY

  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *--method*) echo '{}' ;;
      *) cat "$GH_LOOKUP" ;;
    esac
  }
  export -f gh
}

_body() { printf '%s' "$1" > "$TESTTMP/pn-body.md"; printf '%s' "$TESTTMP/pn-body.md"; }

_post() {
  _body "🤖 This push was not reviewed: quota. This does not block merging." >/dev/null
  "$SCRIPTS/post-notice.sh" --repo o/r --pr 1 --sha "$_SHA" \
    --body-file "$TESTTMP/pn-body.md" --state-out "$TESTTMP/pn-state" "$@"
}

_collapse() {
  "$SCRIPTS/post-notice.sh" --repo o/r --pr 1 --collapse \
    --state-out "$TESTTMP/pn-state" "$@"
}

# --- the notice still gets posted --------------------------------------------

it "posts a notice when the pull request has none"
_setup empty
_post >/dev/null 2>&1
assert_equal "created" "$(_state)" "the witness says a notice was posted"
assert_contains "issues/1/comments --method POST" "a notice was created" -- _calls

# --- a re-run of the SAME push corrects itself instead of stacking -----------
#
# This is the behaviour publish-outcome-check.sh gained as --only-if-exists.
# The notice is addressed by its marker plus the head SHA it was written for.

it "updates the notice it already posted for this push"
_setup same-sha
_post >/dev/null 2>&1
assert_equal "updated" "$(_state)" "the existing notice was reused"
assert_contains "issues/comments/11 --method PATCH" "the notice for this SHA was patched" -- _calls
assert_not_contains "--method POST" "no second notice was created" -- _calls

# --- a notice about ANOTHER push is collapsed, and a fresh one posted --------
#
# Patching it in place would be worse than stacking: a PATCHed comment keeps
# its creation date, so a live failure would be announced halfway up a long
# thread where the author will not see it. Collapse the old, post the new.

it "collapses a notice about another push and posts a visible one"
_setup other-sha
_post >/dev/null 2>&1
assert_equal "created" "$(_state)" "the new push got its own notice"
assert_contains "issues/comments/22 --method PATCH" "the stale notice was collapsed" -- _calls
assert_contains "issues/1/comments --method POST" "a fresh notice was posted" -- _calls

# --- a successful review retracts the notice --------------------------------
#
# The defect that cost a handover its conclusion: nothing ever took the notice
# back once a review landed.

it "collapses every notice and posts nothing when a review succeeded"
_setup legacy-pile
_collapse >/dev/null 2>&1
assert_equal "collapsed" "$(_state)" "the witness says the notices were retracted"
assert_contains "issues/comments/31 --method PATCH" "the first notice was collapsed" -- _calls
assert_contains "issues/comments/32 --method PATCH" "the second notice was collapsed" -- _calls
assert_not_contains "--method POST" "collapsing posts nothing" -- _calls

# A PATCH that fails leaves that notice live. Saying `collapsed` would report
# a retraction that never happened (Copilot, 2026-11-04, on #40).
it "keeps failed when a notice could not be collapsed, and still exits 0"
_setup legacy-pile
gh() {
  echo "$*" >> "$GH_LOG"
  case "$*" in
    *comments/32*--method*) return 1 ;;
    *--method*) echo '{}' ;;
    *) cat "$GH_LOOKUP" ;;
  esac
}
export -f gh
_collapse >/dev/null 2>&1
assert_equal "0" "$?" "a notice is a diagnostic: the job does not fail"
assert_equal "failed" "$(_state)" "the witness does not claim a retraction"
assert_contains "issues/comments/31 --method PATCH" "the other notice was still collapsed" -- _calls

# --- notices posted before this script existed are adopted ------------------
#
# They carry no marker, so only their text can find them. Without this the
# pull requests that are confusing people today would stay confusing.

it "adopts an unmarked notice by its text"
_setup legacy-pile
_post >/dev/null 2>&1
assert_contains "issues/comments/31 --method PATCH" "a legacy notice was collapsed" -- _calls
assert_contains "issues/1/comments --method POST" "and the current notice was posted" -- _calls

# --- what it must never touch ------------------------------------------------
#
# The text signature is deliberately narrow. The review summary is also ours
# and also a bot comment; rewriting it would delete the review itself.

it "never rewrites the sticky summary or a human's comment"
_setup bystanders
_post >/dev/null 2>&1
assert_not_contains "issues/comments/41" "the sticky summary was left alone" -- _calls
assert_not_contains "issues/comments/42" "the human's comment was left alone" -- _calls
assert_contains "issues/1/comments --method POST" "the notice was still posted" -- _calls

it "collapses the legacy notice without touching the summary beside it"
_setup legacy-plus-summary
_collapse >/dev/null 2>&1
assert_contains "issues/comments/52 --method PATCH" "the legacy notice was collapsed" -- _calls
assert_not_contains "issues/comments/51" "the summary was not collapsed with it" -- _calls

# --- it never fails the job --------------------------------------------------
#
# A notice is a diagnostic. Losing the run over one would cost more than the
# notice is worth, so an unreadable thread exits 0 and says so.

it "exits 0 when the comment list cannot be read"
_setup empty
gh() { echo "$*" >> "$GH_LOG"; echo 'gh: Bad credentials (HTTP 401)' >&2; return 1; }
export -f gh
assert_status 0 "an unreadable thread does not fail the job" -- _post

# --- a pull request that never had a notice -----------------------------------
#
# The common case: a review succeeds on a pull request nothing ever failed on.
# `collapsed` there would say a notice was retracted when none existed, and
# the witness is read by the workflow.

it "says absent when there is no notice to retract"
_setup empty
_collapse >/dev/null 2>&1
assert_equal "absent" "$(_state)" "nothing was retracted, and the witness says so"
assert_not_contains "--method" "no write was attempted at all" -- _calls

# --- a stub is not a notice ---------------------------------------------------
#
# Raised by the other reviewer on this change's own pull request (#40). The
# collapsed stub keeps the marker, so `is_notice` matched it and every later
# run put it back in the collapse list: one PATCH per stub per unreviewed push,
# the count growing with the pile — on the script written to stop a pile
# growing. And `--collapse` on a pull request holding only stubs reported
# `collapsed` where `absent` is correct.

it "reports absent when only already-collapsed stubs remain"
_setup stubs-only
_collapse >/dev/null 2>&1
assert_equal "absent" "$(_state)" "stubs are not notices to retract"
assert_not_contains "--method" "and nothing is rewritten" -- _calls

it "does not re-collapse a stub when posting a new notice"
_setup stubs-only
_post >/dev/null 2>&1
assert_equal "created" "$(_state)" "the new notice is still posted"
assert_not_contains "issues/comments/61 --method PATCH" "the first stub is left alone" -- _calls
assert_not_contains "issues/comments/62 --method PATCH" "and so is the second" -- _calls

it "still updates the live notice sitting beside a stub"
_setup stubs-plus-live
_post >/dev/null 2>&1
assert_equal "updated" "$(_state)" "the live notice for this push was reused"
assert_contains "issues/comments/72 --method PATCH" "the live notice was patched" -- _calls
assert_not_contains "issues/comments/71 --method PATCH" "the stub beside it was not" -- _calls

# Both the stub and the sticky summary open on `<!-- claude-review:`, and
# is_stub() tests the NOTICE prefix plus " -->". That the summary does not
# match is the kind of thing to prove rather than reason about: rewriting it
# would delete the review itself.
it "tells a stub from the sticky summary beside it"
_setup stub-plus-summary
_collapse >/dev/null 2>&1
assert_equal "absent" "$(_state)" "neither of them is a notice to retract"
assert_not_contains "issues/comments/81" "the summary is untouched" -- _calls
assert_not_contains "issues/comments/82" "and so is the stub" -- _calls
