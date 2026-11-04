# rereview-open-prs.sh — a tool that spends quota, so the cases are about the
# ways it could spend it on nothing.
#
# Three of them are real enough to have been written the wrong way first:
#
#   * replaying without being asked. The default has to be a report; a run of
#     this against a repository with a dozen stale pull requests would
#     otherwise cost a dozen reviews before anyone read a line of output.
#   * replaying a pull request that HAS a review. `success` on the outcome
#     check is a run that already corrected itself; re-reviewing it buys a
#     second copy of a summary already on the pull request.
#   * replaying the wrong run. Several workflows run on one commit, and on the
#     pull request this script was written for the AI review happened to hold
#     the highest run id — so "take the latest run on this SHA" passed by luck
#     and would have re-run `ci.yml` on the next repository along. The fixture
#     below puts ci.yml's id above the reviewer's so that mistake goes red.
#
# `gh` is an exported shell function, not a file on PATH — same reason as the
# other case files: nothing to lose an executable bit, and the script calls
# `gh` by name.

_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
_C="cccccccccccccccccccccccccccccccccccccccc"
_D="dddddddddddddddddddddddddddddddddddddddd"

_log() { cat "$TESTTMP/rrp-gh.log" 2>/dev/null; }

# _checks SHA CONCLUSION
_checks() {
  printf '{"total_count":1,"check_runs":[{"id":7,"name":"AI review outcome","conclusion":"%s"}]}\n' \
    "$2" > "$TESTTMP/rrp/checks-$1.json"
}

# _runs SHA RUN_ID STATUS — always alongside a ci.yml run with a HIGHER id.
_runs() {
  printf '{"workflow_runs":[{"id":999999,"path":".github/workflows/ci.yml","run_attempt":1,"status":"completed"},{"id":%s,"path":".github/workflows/ai-review.yml","run_attempt":1,"status":"%s"}]}\n' \
    "$2" "$3" > "$TESTTMP/rrp/runs-$1.json"
}

# _setup [WRAPPER_PERMS] — "checks" (default) or "no-checks".
_setup() {
  export GH_LOG="$TESTTMP/rrp-gh.log"
  export GH_FIX="$TESTTMP/rrp"
  export GH_BREAK="${2:-}"
  mkdir -p "$GH_FIX"
  : > "$GH_LOG"

  if [ "${1:-checks}" = "no-checks" ]; then
    printf 'jobs:\n  review:\n    permissions:\n      pull-requests: write\n' > "$GH_FIX/wrapper.yml"
  else
    printf 'jobs:\n  review:\n    permissions:\n      pull-requests: write\n      checks: write\n' > "$GH_FIX/wrapper.yml"
  fi

  # 228 unreviewed and replayable; 229 reviewed; 230 unreviewed but its run is
  # still going; 231 unreviewed and replayable.
  printf '[[{"number":228,"head":{"sha":"%s","ref":"branch-a"}},{"number":229,"head":{"sha":"%s","ref":"branch-b"}},{"number":230,"head":{"sha":"%s","ref":"branch-c"}},{"number":231,"head":{"sha":"%s","ref":"branch-d"}}]]\n' \
    "$_A" "$_B" "$_C" "$_D" > "$GH_FIX/pulls.json"

  _checks "$_A" neutral; _runs "$_A" 111 completed
  _checks "$_B" success; _runs "$_B" 222 completed
  _checks "$_C" neutral; _runs "$_C" 333 in_progress
  _checks "$_D" neutral; _runs "$_D" 444 completed

  gh() {
    echo "$*" >> "$GH_LOG"
    local sha
    case "$*" in
      *contents/*)
        # GH_WRAPPER_ERR lets a case make the wrapper read fail with the exact
        # stderr the API produces, which is the only thing telling a refused
        # credential from a missing file.
        if [ -n "${GH_WRAPPER_ERR:-}" ]; then
          printf '%s
' "$GH_WRAPPER_ERR" >&2
          return 1
        fi
        cat "$GH_FIX/wrapper.yml" ;;
      *pulls\?state=open*)
        cat "$GH_FIX/pulls.json" ;;
      *check-runs*)
        sha="$(printf '%s' "$*" | sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p')"
        # GH_BREAK lets one case make a single read fail the way the API does:
        # a non-zero status, or a body nothing can parse.
        [ "${GH_BREAK:-}" = "refuse-$sha" ] && return 1
        cat "$GH_FIX/checks-${sha}.json" ;;
      *actions/runs\?head_sha=*)
        sha="$(printf '%s' "$*" | sed -n 's|.*head_sha=\([0-9a-f]*\).*|\1|p')"
        [ "${GH_BREAK:-}" = "refuse-runs-$sha" ] && return 1
        cat "$GH_FIX/runs-${sha}.json" ;;
      *"run rerun"*)
        # GH_RERUN_FAIL turns every replay down the way GitHub does when the
        # run is too old to re-run, or the token lacks `actions: write`. It is
        # the only way to reach the path where every read succeeded and nothing
        # was replayed.
        if [ -n "${GH_RERUN_FAIL:-}" ]; then
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

_report() { "$SCRIPTS/rereview-open-prs.sh" --repo o/r "$@" 2>&1; }

# --- arguments ---------------------------------------------------------------

it "refuses a repository it cannot address"
assert_contains "--repo is required" "says which argument is missing" -- \
  "$SCRIPTS/rereview-open-prs.sh"
assert_contains "OWNER/REPO" "rejects a bare repository name" -- \
  "$SCRIPTS/rereview-open-prs.sh" --repo korbyx

# --- what it reports ---------------------------------------------------------

_setup

it "lists the pull requests whose head commit went unreviewed"
assert_contains "PR 228" "names the unreviewed pull request" -- _report
assert_contains "run 111" "names the run that left the neutral check" -- _report

it "leaves a reviewed pull request alone"
assert_not_contains "PR 229" "a success outcome check is not a miss" -- _report

it "leaves a run that is still going"
assert_contains "left alone" "says why the in-flight run is skipped" -- _report
# The skip line names the run, so the needle has to be the shape of a TARGET
# line — `run <id> (attempt <n>)` — not the id on its own.
assert_not_contains "run 333 (attempt" "does not list it as replayable" -- _report

it "reads the run from the wrapper's path, not the highest id on the commit"
assert_not_contains "999999" "ignores ci.yml, which runs on the same commit" -- _report

# --- what it does ------------------------------------------------------------

it "replays nothing until asked"
_setup
_report >/dev/null
assert_not_contains "run rerun" "no replay without --rerun" -- _log
assert_contains "Pass --rerun" "tells the reader how to act on the list" -- _report

it "replays exactly the runs it listed"
_setup
_report --rerun >/dev/null
assert_contains "run rerun 111" "replays the reviewer's run" -- _log
assert_contains "run rerun 444" "replays every one of them" -- _log
assert_not_contains "run rerun 999999" "never replays another workflow" -- _log
assert_not_contains "run rerun 222" "never replays a reviewed pull request" -- _log

it "stops at --limit"
_setup
_report --rerun --limit 1 >/dev/null
assert_equal "1" "$(_log | grep -c 'run rerun' || true)" "replays one run and no more"

# --- the blind spot it has to admit to ---------------------------------------
#
# Without `checks: write` the wrapper publishes no outcome check at all, so
# every pull request looks reviewed. Reporting that as a clean bill of health
# is the one answer this must never give.

it "says when the repository cannot tell it the truth"
_setup no-checks
assert_contains "checks: write" "names the missing permission" -- _report
assert_contains "floor, not a count" "refuses to present zero as a clean sweep" -- _report

# A wrapper that merely MENTIONS the permission is not a wrapper that grants
# it. `grep 'checks: *write'` matched a commented-out line and the sentence
# docs/SETUP.md tells people to paste — and then went quiet about the exact
# blind spot it is there to announce, which is worse than not looking.
it "is not satisfied by a wrapper that only mentions the permission"
_setup no-checks
printf 'jobs:\n  review:\n    permissions:\n      # add `checks: write` here\n      #checks: write\n' \
  > "$GH_FIX/wrapper.yml"
assert_contains "floor, not a count" "a commented permission still warns" -- _report

# --- a read that failed is not a pull request with a review ------------------
#
# Every one of these turned an inspection failure into a clean bill of health,
# which is the same defect the `checks: write` preflight exists to prevent —
# and the clean-sweep line is the sentence a maintainer acts on by doing
# nothing at all.

_setup_one() {
  _setup "${1:-checks}" "${2:-}"
  # One reviewed pull request and one whose check runs cannot be read. Without
  # the second, there is nothing to hide behind a clean sweep.
  printf '[[{"number":228,"head":{"sha":"%s","ref":"branch-a"}},{"number":229,"head":{"sha":"%s","ref":"branch-b"}}]]\n' \
    "$_A" "$_B" > "$GH_FIX/pulls.json"
}

it "never calls it a clean sweep when a check run could not be read"
_setup_one checks "refuse-$_A"
assert_not_contains "carries a review" "no clean bill of health on a failed read" -- _report
assert_contains "could not be fully inspected" "says how many it could not look at" -- _report
assert_status 1 "and carries that in the exit status, for a caller reading no output" -- \
  "$SCRIPTS/rereview-open-prs.sh" --repo o/r

# The run lookup is the third read on this path, and it was the one left out:
# it warned, moved on, and let the status stay 0 while the two identical
# branches above exited 1. "None of them replayable" is then a claim about a
# read that failed. Our own reviewer caught this on #16 after the first two
# were fixed — the same defect, one branch further down.
it "counts a pull request whose workflow runs could not be listed"
_setup_one checks "refuse-runs-$_A"
assert_contains "could not list its workflow runs" "says what it could not read" -- _report
assert_contains "could not be fully inspected" "counts it against the answer" -- _report
assert_status 1 "and exits 1, like the two reads before it" -- \
  "$SCRIPTS/rereview-open-prs.sh" --repo o/r

it "keeps 'no run here' apart from 'I could not read the runs'"
_setup_one
printf 'not json at all\n' > "$GH_FIX/runs-$_A.json"
assert_contains "came back unreadable" "an unparseable body is not an absent run" -- _report
# The honest empty answer stays exit 0: nothing failed, there is simply no run.
_setup_one
printf '{"workflow_runs":[]}\n' > "$GH_FIX/runs-$_A.json"
assert_status 0 "a genuine absence of runs is a complete answer" -- \
  "$SCRIPTS/rereview-open-prs.sh" --repo o/r

it "never calls it a clean sweep when the check runs came back unreadable"
_setup_one
printf 'not json at all\n' > "$GH_FIX/checks-$_A.json"
assert_not_contains "carries a review" "an unparseable body is not an absent check" -- _report
assert_contains "NOT inspected" "names the pull request it could not inspect" -- _report

it "refuses to read an unparseable pull request list as an empty one"
_setup
printf 'not json at all\n' > "$GH_FIX/pulls.json"
assert_not_contains "no open pull requests" "silence from a failed parse is not an empty repository" -- _report
assert_status 1 "stops instead" -- "$SCRIPTS/rereview-open-prs.sh" --repo o/r

# --- the query has to ask the question it was given --------------------------

it "percent-encodes the whole check name, not only its spaces"
_setup
_report --check 'weird & name?' >/dev/null
assert_contains "weird%20%26%20name%3F" "encodes & and ? too" -- _log

# --- a refused credential is not a missing wrapper ----------------------------
#
# Both arrive at the same `gh api .../contents/...` failure, and until this
# branch both left with "is this repository wired to claude-review?" — the
# wrong hypothesis for the likelier cause, sending the reader to check a file
# that is fine.
#
# Likelier because of how the guard upstream works: catch-up.yml tests
# `[ -z "$REREVIEW_GITHUB_TOKEN" ]`, which catches a token that is UNSET. An
# EXPIRED one is still set, so the sweep runs and every call fails here — and
# a fine-grained token expires within a year, so this is the ordinary end of
# every credential this workflow is given. docs/SETUP.md promised the run
# would name the secret to replace; raised by our own reviewer on #18.

it "names the secret when GitHub refuses the credential"
_setup
GH_WRAPPER_ERR='gh: Bad credentials (HTTP 401)' _report >"$TESTTMP/rop-401" 2>&1 || true
assert_contains "REREVIEW_GITHUB_TOKEN" \
  "the message names the secret to replace" -- cat "$TESTTMP/rop-401"
assert_contains "expired, revoked, or not authorised" \
  "and says what is wrong with it" -- cat "$TESTTMP/rop-401"
assert_not_contains "wired to claude-review" \
  "and does not send the reader to check a wrapper that is fine" -- cat "$TESTTMP/rop-401"
# Run by hand, `gh` is not using that secret at all, so the message has to say
# where the credential comes from then too. Raised by CodeRabbit on #18.
assert_contains "gh auth status" \
  "and tells a person at a terminal which credential was refused" -- cat "$TESTTMP/rop-401"

# A 403 is not always the credential: GitHub answers an exhausted rate limit
# with a 403 too, and telling the reader to replace a secret that works sends
# them the wrong way. Raised by both other reviewers on #18.
it "says wait, not replace the secret, when the rate limit is exhausted"
_setup
GH_WRAPPER_ERR='gh: API rate limit exceeded for user ID 1. (HTTP 403)' _report >"$TESTTMP/rop-rate" 2>&1 || true
assert_contains "wait for the limit to reset" \
  "the message gives the remedy that fits" -- cat "$TESTTMP/rop-rate"
assert_not_contains "expired, revoked" \
  "and does not call a working credential expired" -- cat "$TESTTMP/rop-rate"

it "still says missing wrapper when the wrapper is missing"
_setup
GH_WRAPPER_ERR='gh: Not Found (HTTP 404)' _report >"$TESTTMP/rop-404" 2>&1 || true
assert_contains "wired to claude-review" \
  "a genuine 404 keeps the hypothesis that fits it" -- cat "$TESTTMP/rop-404"
assert_not_contains "REREVIEW_GITHUB_TOKEN" \
  "and does not blame a credential that worked" -- cat "$TESTTMP/rop-404"

# --- replays that were all refused are not a clean pass -----------------------
#
# Raised by a cross-model audit on 2026-11-04. Every read succeeding and every
# `gh run rerun` being turned down left `unknown` at zero, so this script
# printed "replayed 0 of N." and exited 0 — and the scheduled parent recorded
# the repository as clean while nothing had been replayed. The premise of this
# tool is that nobody is watching, so the status is the only channel that
# reaches a person.

it "exits non-zero when every replay was refused"
_setup
assert_status 1 "a repository whose replays were all refused did not come back clean" \
  -- env GH_RERUN_FAIL=1 "$SCRIPTS/rereview-open-prs.sh" --repo o/r --rerun --limit 2

it "names each refusal so the reason reaches the log"
_setup
GH_RERUN_FAIL=1 "$SCRIPTS/rereview-open-prs.sh" --repo o/r --rerun --limit 2 \
  >"$TESTTMP/rop-refused" 2>&1 || true
assert_contains "refused the replay" "the refusal is printed, not swallowed" \
  -- cat "$TESTTMP/rop-refused"

it "still exits zero when the replays went through"
_setup
assert_status 0 "a clean replay keeps the clean status" \
  -- "$SCRIPTS/rereview-open-prs.sh" --repo o/r --rerun --limit 2
