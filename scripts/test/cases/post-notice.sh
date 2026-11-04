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
