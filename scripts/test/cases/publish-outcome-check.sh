# publish-outcome-check.sh — the only thing that changes what a reviewer SEES.
#
# Every other signal this workflow emits on the unavailable path (the step
# summary, the annotation, the notice comment) was already there while
# Aileaneprod/korbyx#131 was merged believing a review had run. So the cases
# below are about the two ways this one could fail quietly in the same manner:
#
#   * a denied API call that reads as a success, leaving the check green and
#     nobody told which permission is missing;
#   * a second check run stacked on the first, which is the defect the notice
#     comment already has and must not be copied into the check.
#
# `gh` is an exported shell function, not a file on PATH — same reason as
# post-review.sh's case file: no executable bit to lose, and `command -v gh`
# finds a function.

_SHA="0123456789abcdef0123456789abcdef01234567"

_calls() { cat "$TESTTMP/poc-gh.log"; }
_state() { cat "$TESTTMP/poc-state" 2>/dev/null || echo "(no state written)"; }

# _setup [LOOKUP_JSON] [MODE] — MODE is ok (default), deny-lookup or deny-write.
_setup() {
  export GH_LOOKUP="$TESTTMP/poc-lookup.json"
  export GH_LOG="$TESTTMP/poc-gh.log"
  export GH_MODE="${2:-ok}"
  : > "$GH_LOG"
  printf '%s' "${1:-{\"total_count\":0,\"check_runs\":[]\}}" > "$GH_LOOKUP"
  rm -f "$TESTTMP/poc-state"

  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *check-runs\?check_name*)
        if [ "$GH_MODE" = "deny-lookup" ]; then
          echo '{"message":"Resource not accessible by integration","status":"403"}'
          echo 'gh: Resource not accessible by integration (HTTP 403)' >&2
          return 1
        fi
        cat "$GH_LOOKUP"
        ;;
      *--method*)
        if [ "$GH_MODE" = "deny-write" ]; then
          echo '{"message":"Resource not accessible by integration","status":"403"}'
          echo 'gh: Resource not accessible by integration (HTTP 403)' >&2
          return 1
        fi
        echo '{"id": 999}'
        ;;
      *) echo '{}' ;;
    esac
  }
  export -f gh
}

_publish() {
  "$SCRIPTS/publish-outcome-check.sh" \
    --repo o/r --sha "$_SHA" --name 'AI review outcome' \
    --conclusion neutral --title 'The review did not happen' \
    --summary 'The reviewer did not complete.' \
    --state-out "$TESTTMP/poc-state" "$@"
}

# --- the check actually gets published ---------------------------------------

it "creates the check run when none is there yet"
_setup
_publish >/dev/null 2>&1
assert_equal "created" "$(_state)" "the witness says a check run was created"
assert_contains "--method POST" "a new check run was posted" -- _calls

# --- the stacking defect, which the notice comment already has ----------------
#
# A re-run of the same push must not leave two grey rows in the merge box. The
# check run is addressed by name on the head SHA, so the second run PATCHes.

it "updates the check run it already published on this SHA"
_setup '{"total_count":1,"check_runs":[{"id":4242,"name":"AI review outcome"}]}'
_publish >/dev/null 2>&1
assert_equal "updated" "$(_state)" "the witness says the existing check run was reused"
assert_contains "check-runs/4242 --method PATCH" "the existing check run was patched" -- _calls
assert_not_contains "--method POST" "no second check run was created" -- _calls

# --- somebody else's check run is not ours to rewrite -------------------------
#
# The name filter is a query string. If the API ever answers with a run that
# does not match, a PATCH would overwrite a check this workflow never created.

it "ignores a check run of another name on the same SHA"
_setup '{"total_count":1,"check_runs":[{"id":7,"name":"verify"}]}'
_publish >/dev/null 2>&1
assert_contains "--method POST" "an unrelated check run is left alone" -- _calls
assert_not_contains "check-runs/7 --method PATCH" "verify was not overwritten" -- _calls

# --- a denial must be loud, and must not read as a success --------------------
#
# Measured on theo986/claude-review run 34414735973: under the permission set
# templates/wrapper.yml grants today, POST /check-runs answers
# "Resource not accessible by integration" (403). A repository that has not
# added `checks: write` keeps exactly the behaviour it has now, so the denial
# has to be the thing that says why — not an empty log.

it "reports a denied write as denied, and names the permission"
_setup '{"total_count":0,"check_runs":[]}' deny-write
assert_contains "checks: write" "the missing permission is named" -- _publish
assert_equal "denied" "$(_state)" "the witness distinguishes denied from created"

it "reports a denied lookup as denied too"
_setup '{"total_count":0,"check_runs":[]}' deny-lookup
assert_contains "checks: write" "the missing permission is named on the lookup path" -- _publish
assert_equal "denied" "$(_state)" "a denied lookup is not mistaken for an absent check run"

it "never fails the job, whatever the API answers"
_setup '{"total_count":0,"check_runs":[]}' deny-write
assert_status 0 "a denied write still exits 0" -- _publish
_setup '{"total_count":0,"check_runs":[]}' deny-lookup
assert_status 0 "a denied lookup still exits 0" -- _publish

# --- an absent head SHA is refused by shape, with the reason ------------------
#
# `github.event.pull_request.head.sha` is an empty string outside a
# pull_request event. Passed through, it would reach a different endpoint and
# come back 404 — an opaque answer from the one step whose job is to be plain.

it "refuses an argument that is not a commit SHA"
_setup
assert_contains "must be a commit SHA" "an empty SHA is named as the problem" -- \
  "$SCRIPTS/publish-outcome-check.sh" --repo o/r --sha "" --name n \
  --conclusion neutral --title t --summary s
assert_contains "40-character" "a truncated SHA is refused" -- \
  "$SCRIPTS/publish-outcome-check.sh" --repo o/r --sha "0123456789abcdef" --name n \
  --conclusion neutral --title t --summary s
assert_not_contains "--method" "nothing is written when the SHA is unusable" -- _calls

# --- a re-run must not leave the grey check contradicting the summary ---------
#
# The first attempt on a commit publishes `neutral`. A re-run of the SAME
# commit that reviews it successfully posts a summary beside that check. One
# commit carrying both is the defect this whole check exists to fix, so the
# summary path corrects it — and only corrects, never creates: a review that
# worked the first time has nothing to say here and stays silent.

it "corrects a check run an earlier attempt on this commit left behind"
_setup '{"total_count":1,"check_runs":[{"id":31,"name":"AI review outcome"}]}'
_publish --only-if-exists --conclusion success >/dev/null 2>&1
assert_equal "updated" "$(_state)" "the stale neutral check was corrected"
assert_contains "check-runs/31 --method PATCH" "the existing check run was patched" -- _calls

it "creates nothing when no earlier attempt published one"
_setup '{"total_count":0,"check_runs":[]}'
_publish --only-if-exists --conclusion success >/dev/null 2>&1
assert_equal "absent" "$(_state)" "absent is distinguished from created"
assert_not_contains "--method" "a review that worked the first time stays silent" -- _calls
