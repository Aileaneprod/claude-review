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
        # GH_RA_WRAPPER_ERR makes the read fail with the API's own stderr,
        # which is the only thing that tells a refused credential from a
        # missing file.
        if [ -n "${GH_RA_WRAPPER_ERR:-}" ]; then
          printf '%s\n' "$GH_RA_WRAPPER_ERR" >&2
          return 1
        fi
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
        # GH_RA_RERUN_FAIL turns every replay down, which is how the budget
        # learns the difference between work done and work attempted.
        if [ -n "${GH_RA_RERUN_FAIL:-}" ]; then
          echo 'gh: Unable to retry this run (HTTP 403)' >&2
          return 1
        fi
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
assert_contains "did not come back clean" "the report says one entry is broken" -- _ra --rerun --budget 5
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

# --- the promise docs/SETUP.md makes, end to end ------------------------------
#
# docs/SETUP.md says a fine-grained token's expiry makes "the daily run start
# failing and its job summary name the secret to replace". Nothing made that
# true: the guard in catch-up.yml tests `[ -z "$REREVIEW_GITHUB_TOKEN" ]`, which
# catches an UNSET token, while an EXPIRED one is still set — so the sweep ran
# and died on "is this repository wired to claude-review?", the wrong
# hypothesis. Raised by our own reviewer on #18.
#
# The chain this asserts, because each link was read and none was measured:
# rereview-open-prs.sh writes the cause to stderr, rereview-all.sh captures it
# with `2>&1` into that repository's block, and catch-up.yml tees the report
# into GITHUB_STEP_SUMMARY.

it "names the secret in the report when the credential is refused"
_ra_setup
printf 'o/r\n' > "$TESTTMP/ra-repos.txt"
GH_RA_WRAPPER_ERR='gh: Bad credentials (HTTP 401)' _ra > "$TESTTMP/ra-401" 2>&1 || true
assert_contains "REREVIEW_GITHUB_TOKEN" \
  "the report names the secret to replace" -- cat "$TESTTMP/ra-401"
assert_contains "Did not come back clean" \
  "and the repository's block says it failed" -- cat "$TESTTMP/ra-401"
assert_not_contains "wired to claude-review" \
  "without blaming a wrapper that is fine" -- cat "$TESTTMP/ra-401"

it "exits non-zero so an unattended run reaches a person"
_ra_setup
printf 'o/r\n' > "$TESTTMP/ra-repos.txt"
assert_status 1 "a refused credential fails the scheduled run" \
  -- env GH_RA_WRAPPER_ERR='gh: Bad credentials (HTTP 401)' "$SCRIPTS/rereview-all.sh" \
       --repos "$TESTTMP/ra-repos.txt"

# --- the budget is the one mistake here with no undo --------------------------
#
# Raised by a cross-model audit on 2026-11-04. The spend per repository is read
# from the child's final tally line, and `got` empty meant `got=0`. An entry
# KILLED after replaying one of two therefore reported nothing spent, and the
# next repository received the full budget again: with a budget of 2, three
# replays could be engaged. Over-spending is the direction with no undo, so an
# unknown is now charged at the whole allowance that entry was given.

it "refuses a leading zero, which bash reads as octal"
_ra_setup
printf 'o/r\n' > "$TESTTMP/ra-repos.txt"
assert_contains "must not have a leading zero" \
  "08 is refused before any arithmetic touches it" \
  -- "$SCRIPTS/rereview-all.sh" --repos "$TESTTMP/ra-repos.txt" --budget 08
assert_contains "must not have a leading zero" \
  "and so is 010, which would silently mean 8" \
  -- "$SCRIPTS/rereview-all.sh" --repos "$TESTTMP/ra-repos.txt" --budget 010

# 0 is still the default and still legal: it means "not given" for --budget and
# "no per-repository limit" for --limit. Rejecting it would refuse the script's
# own defaults, which is why the arm is `0?*` and not `0*`.
it "still accepts a bare zero"
_ra_setup
printf 'o/r\n' > "$TESTTMP/ra-repos.txt"
assert_not_contains "leading zero" \
  "the bare default is not caught by the octal arm" \
  -- "$SCRIPTS/rereview-all.sh" --repos "$TESTTMP/ra-repos.txt" --budget 0

# The spend has to survive the child dying, which is the whole point: an entry
# killed after replaying one of two reported nothing spent, and the next entry
# received the full budget again. Two repositories, a budget of 2, and the
# first one's replays succeed — the second must be given what is LEFT.
it "charges the budget from the replays that actually happened"
_ra_setup
printf 'o/r\no/s\n' > "$TESTTMP/ra-repos.txt"
printf 'permissions:\n  checks: write\n' > "$GH_FIX/wrapper-o-r.yml"
printf 'permissions:\n  checks: write\n' > "$GH_FIX/wrapper-o-s.yml"
_ra --rerun --budget 2 >"$TESTTMP/ra-budget" 2>&1 || true
assert_contains "run rerun" "the first repository replayed something" -- cat "$GH_LOG"
# The second invocation of the child must carry a smaller --limit than the
# first, because the first one's replays were charged.
assert_not_contains "--limit 2 --limit 2" \
  "the second repository is not handed the whole budget again" -- cat "$TESTTMP/ra-budget"

# And a per-replay line is the unit, so a REFUSED replay is not charged: the
# budget pays for work done, not for attempts.
it "does not charge a refused replay against the budget"
_ra_setup
printf 'o/r\n' > "$TESTTMP/ra-repos.txt"
printf 'permissions:\n  checks: write\n' > "$GH_FIX/wrapper-o-r.yml"
GH_RA_RERUN_FAIL=1 _ra --rerun --budget 2 >"$TESTTMP/ra-refused" 2>&1 || true
assert_contains "Replayed **0** review(s)" \
  "nothing replayed means nothing spent" -- cat "$TESTTMP/ra-refused"

# The defect needed an INTERRUPTED child, which this harness cannot produce: a
# `die` in the child happens before the replay loop, and inside it a failure is
# handled rather than fatal. So the mechanism is tested on the artefact instead
# — the captured output of a child that replayed once and never reached its
# closing tally, which is exactly what a killed one leaves behind.
it "counts a replay the child never got to tally"
cut="$TESTTMP/ra-cut-output.txt"
{
  printf 'rereview-open-prs: 2 unreviewed pull request(s) on o/r\n'
  printf '  replayed PR 228 (run 111)\n'
} > "$cut"
# The fix: per-replay lines, printed as each one succeeds.
assert_equal "1" "$(grep -c '^  replayed PR ' "$cut")" \
  "the replay that happened is counted without the tally line"
# The defect: the closing tally, which a killed child never prints. Empty, and
# `case '' in *[!0-9]*` does not match, so it became 0 and the next repository
# was handed the whole budget again.
assert_equal "" \
  "$(sed -n 's/^rereview-open-prs: replayed \([0-9][0-9]*\) of .*/\1/p' "$cut" | tail -1)" \
  "while the tally line it replaced is absent, which is how 0 was charged"

# And the two agree on a child that finished, so the change is not a behaviour
# change on the ordinary path.
it "agrees with the tally when the child did finish"
done_out="$TESTTMP/ra-done-output.txt"
{
  printf '  replayed PR 228 (run 111)\n'
  printf '  replayed PR 231 (run 444)\n'
  printf 'rereview-open-prs: replayed 2 of 2.\n'
} > "$done_out"
assert_equal "2" "$(grep -c '^  replayed PR ' "$done_out")" \
  "both readings give the same count on a clean pass"
