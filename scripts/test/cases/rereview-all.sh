# rereview-all.sh — the pass that nobody watches, so the cases are about the
# ways it could spend quota, hide something, or stop early without saying so.
#
# The sibling case file covers what happens inside ONE repository. Everything
# here is a property that only exists once there is a list:
#
#   * the budget is the pass's, not the repository's. Three repositories each
#     allowed five is fifteen reviews. The fixture gives every repository two
#     replayable pull requests and a budget of three, so a driver that passes
#     the per-repository limit straight through replays four and goes red.
#   * a repository the budget never reached has to be NAMED. An unannounced
#     skip in an unattended summary reads exactly like "nothing to do here",
#     which is the failure this whole tool exists to correct.
#   * one bad entry cannot end the pass. rereview-open-prs.sh exits non-zero
#     for a repository with no wrapper — correct for a person at a terminal,
#     fatal for entry one of three at 06:17.
#   * the `checks: write` blind spot has to be in the REPORT. The child says it
#     on stderr; unattended, stderr is the thing nobody reads.
#
# `gh` is an exported shell function, so the real rereview-open-prs.sh runs
# underneath: these cases exercise the pair, not a mock of one.

_RA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_RA_D="dddddddddddddddddddddddddddddddddddddddd"

_ra_log()    { cat "$TESTTMP/ra-gh.log" 2>/dev/null; }
_ra_reruns() { grep -c 'run rerun' "$TESTTMP/ra-gh.log" 2>/dev/null || true; }
_ra()        { "$SCRIPTS/rereview-all.sh" --repos "$TESTTMP/ra-repos.txt" "$@" 2>&1; }

# Only the hoisted block, so that naming a repository INSIDE it is what the
# assertion pins. A needle taken from the whole report would also match the
# `#### o/blind` heading of the section the hoist exists to stay above.
_ra_hoisted() { _ra "$@" | grep '^- '; }

# _ra_wrapper REPO [no-checks] — give a repository a wrapper. A repository
# without one is a repository this cannot check at all.
_ra_wrapper() {
  local slug
  slug="$(printf '%s' "$1" | tr '/' '-')"
  if [ "${2:-checks}" = "no-checks" ]; then
    printf 'jobs:\n  review:\n    permissions:\n      pull-requests: write\n' \
      > "$GH_FIX/wrapper-${slug}.yml"
  else
    printf 'jobs:\n  review:\n    permissions:\n      pull-requests: write\n      checks: write\n' \
      > "$GH_FIX/wrapper-${slug}.yml"
  fi
}

# _ra_list REPO... — the roster file, in order.
_ra_list() {
  : > "$TESTTMP/ra-repos.txt"
  local r
  for r in "$@"; do printf '%s\n' "$r" >> "$TESTTMP/ra-repos.txt"; done
}

# Every repository looks the same from the API: two open pull requests, both
# unreviewed, both replayable. What differs between the cases is the budget.
_ra_setup() {
  export GH_LOG="$TESTTMP/ra-gh.log"
  export GH_FIX="$TESTTMP/ra"
  rm -rf "$GH_FIX"
  mkdir -p "$GH_FIX"
  : > "$GH_LOG"

  printf '[[{"number":228,"head":{"sha":"%s","ref":"branch-a"}},{"number":231,"head":{"sha":"%s","ref":"branch-d"}}]]\n' \
    "$_RA_A" "$_RA_D" > "$GH_FIX/pulls.json"

  local sha
  for sha in "$_RA_A" "$_RA_D"; do
    printf '{"total_count":1,"check_runs":[{"id":7,"name":"AI review outcome","conclusion":"neutral"}]}\n' \
      > "$GH_FIX/checks-${sha}.json"
  done
  printf '{"workflow_runs":[{"id":111,"path":".github/workflows/ai-review.yml","run_attempt":1,"status":"completed"}]}\n' \
    > "$GH_FIX/runs-${_RA_A}.json"
  printf '{"workflow_runs":[{"id":444,"path":".github/workflows/ai-review.yml","run_attempt":1,"status":"completed"}]}\n' \
    > "$GH_FIX/runs-${_RA_D}.json"

  gh() {
    echo "$*" >> "$GH_LOG"
    local slug sha
    case "$*" in
      *contents/*)
        slug="$(printf '%s' "$*" | sed -n 's|.*repos/\([^/]*\)/\([^/]*\)/contents/.*|\1-\2|p')"
        [ -f "$GH_FIX/wrapper-${slug}.yml" ] || return 1
        cat "$GH_FIX/wrapper-${slug}.yml" ;;
      *pulls\?state=open*)
        cat "$GH_FIX/pulls.json" ;;
      *check-runs*)
        sha="$(printf '%s' "$*" | sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p')"
        cat "$GH_FIX/checks-${sha}.json" ;;
      *actions/runs\?head_sha=*)
        sha="$(printf '%s' "$*" | sed -n 's|.*head_sha=\([0-9a-f]*\).*|\1|p')"
        cat "$GH_FIX/runs-${sha}.json" ;;
      *"run rerun"*)
        return 0 ;;
      *)
        echo '{}' ;;
    esac
  }
  export -f gh
}

# --- spending nothing by accident --------------------------------------------

_ra_setup
_ra_wrapper o/one
_ra_list o/one

it "will not replay a list without being told what it may spend"
assert_status 1 "refuses --rerun on its own" -- _ra --rerun
assert_contains "needs --budget" "says which number is missing" -- _ra --rerun

it "replays nothing until asked"
_ra >/dev/null
assert_equal "0" "$(_ra_reruns)" "no replay without --rerun"
assert_contains "Report only" "says so at the top of the report" -- _ra

# --- the budget belongs to the pass, not to a repository ---------------------

it "stops the whole pass at the budget, not each repository at it"
_ra_setup
_ra_wrapper o/one; _ra_wrapper o/two; _ra_wrapper o/three
_ra_list o/one o/two o/three
_ra --rerun --budget 3 --limit 5 >/dev/null
assert_equal "3" "$(_ra_reruns)" "six replayable pull requests, three replayed"

it "names the repository the budget never reached"
assert_contains "Not reached" "the report says one was left out" -- _ra --rerun --budget 3 --limit 5
assert_not_contains "o/three" "and it was never even read" -- _ra_log

it "still bounds one repository when the budget is roomy"
_ra_setup
_ra_wrapper o/one; _ra_wrapper o/two; _ra_wrapper o/three
_ra_list o/one o/two o/three
_ra --rerun --budget 10 --limit 1 >/dev/null
assert_equal "3" "$(_ra_reruns)" "one replay per repository, not two"

# --- one repository is not the pass ------------------------------------------
#
# o/gone has no wrapper, so rereview-open-prs.sh exits 1 on it. The pass has to
# carry on to o/one and then fail the run: nobody is watching this, and a name
# in the roster that cannot be read is a stale roster reporting a reassuring
# zero. The failed run is the only channel that reaches a person.

it "survives a repository it cannot check, and fails the run for it"
_ra_setup
_ra_wrapper o/one
_ra_list o/gone o/one
assert_contains "o/one" "the repositories after it are still swept" -- _ra --rerun --budget 5
assert_contains "could not be checked" "the report says one entry is broken" -- _ra --rerun --budget 5
assert_status 1 "a broken roster entry fails the run" -- _ra --rerun --budget 5

# --- the blind spot has to survive the trip to the summary -------------------
#
# Without `checks: write` the wrapper publishes no outcome check, so every pull
# request on that repository looks reviewed. The child warns on stderr. If the
# driver only funnels that into a fenced block halfway down a multi-repository
# report, the one warning that must not be missed is the one that is.

it "hoists the blind spot above the report instead of burying it"
_ra_setup
_ra_wrapper o/blind no-checks
_ra_list o/blind
assert_contains "Blind spot" "the report opens with it" -- _ra
assert_contains "o/blind" "and the hoisted line names the repository" -- _ra_hoisted

# --- the roster is input, and it is edited during an outage ------------------
#
# Only ONE thing here is worth a case. A line that is not OWNER/REPO-shaped is
# already refused by rereview-open-prs.sh a moment later, so a case about it
# passes whether or not this script checks anything. A THIRD field is the one
# malformation nothing downstream can see: it parses, it runs, and whatever the
# author meant by it is silently dropped from a roster whose entire value is
# being complete.

it "refuses a roster line it would otherwise half-read"
_ra_setup
_ra_wrapper o/one
printf 'o/one .github/workflows/ai-review.yml and-then-some\n' > "$TESTTMP/ra-repos.txt"
assert_status 1 "a third field is not quietly ignored" -- _ra --budget 5
assert_equal "" "$(_ra_log)" "and the roster is read before anything is called"
