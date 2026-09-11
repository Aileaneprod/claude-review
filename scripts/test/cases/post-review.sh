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

# _setup [ISSUE_COMMENTS_JSON] [THREADS_FIXTURE] — default: an empty pull
# request. THREADS_FIXTURE names a file in fixtures/ holding a GraphQL
# reviewThreads response; without one the PR carries no review threads.
_setup() {
  export GH_LOG="$(_gh_log)"
  export GH_ISSUE_COMMENTS="$(_gh_comments)"
  export GH_THREADS="$TESTTMP/pr-threads.json"
  export GH_REVIEW_COMMENTS="$TESTTMP/pr-review-comments.json"
  : > "$GH_LOG"
  printf '%s' "${1:-[]}" > "$GH_ISSUE_COMMENTS"
  if [ -n "${2:-}" ]; then
    cp "$FIXTURES/$2" "$GH_THREADS"
  else
    printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' > "$GH_THREADS"
  fi
  if [ -n "${3:-}" ]; then
    cp "$FIXTURES/$3" "$GH_REVIEW_COMMENTS"
  else
    printf '%s' '[]' > "$GH_REVIEW_COMMENTS"
  fi
  rm -f "$TESTTMP/pr-posted" "$TESTTMP/prior-live.json" "$TESTTMP/prior.md"

  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *graphql*)               cat "$GH_THREADS" ;;
      *--method*)              echo '{}' ;;
      *issues/*/comments*)     cat "$GH_ISSUE_COMMENTS" ;;
      *pulls/*/comments*)      cat "$GH_REVIEW_COMMENTS" ;;
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

# --- the emoji have to be in the table -------------------------------------

it "does not accept a sentence that merely names the three severities"
# Raised on the pull request that introduced the check: three emoji anywhere in
# the text passed it, and "J'ai releve des points 🔴, 🟠 et 🟡 ; je continue"
# is exactly the kind of sentence a run ends on. The counts table is a table.
_setup
assert_equal "false" "$(_posted summary-emoji-prose.json)" "prose is not a counts table"
assert_not_contains "--method" "the previous summary is left standing" -- _calls

# --- the counts table is the PR's standing verdict, not this run's log --------
#
# Aileaneprod/korbyx#162, merged 2026-09-11. The first run posted a 🟡; the
# second was told not to repost it (base.md, "Do not post a finding that already
# appears in this list") and reported `🟡 0`. The sticky comment is PATCHed in
# place, so the count that had announced the finding was overwritten, and the
# pull request merged showing a reviewer who had found nothing. Checked on the
# thread: neither resolved nor outdated. Same shape on #163 and #164.
#
# The still-live findings are measured in `pre`, BEFORE the reviewer runs, and
# deliberately not here: claude-code-action writes the execution file some
# milliseconds before it flushes the buffered inline comments, so a count taken
# at `post` time can miss the comments this very run has just made.

_prior() { printf '%s' "$1" > "$TESTTMP/prior-live.json"; }

_body() {
  "$SCRIPTS/post-review.sh" --mode post --repo o/r --pr 1 \
    --execution-file "$FIXTURES/$1" --prior-live "$TESTTMP/prior-live.json" \
    --dry-run 2>/dev/null
}

_body_bare() {
  "$SCRIPTS/post-review.sh" --mode post --repo o/r --pr 1 \
    --execution-file "$FIXTURES/$1" --dry-run 2>/dev/null
}

it "adds a finding that is still live from an earlier run to the count it posts"
_setup
_prior '{"blocking": 0, "important": 0, "nit": 1}'
assert_contains "🟡 Mineur | 1" "the earlier nit reaches the standing verdict" -- _body summary-french.json

it "leaves the severity this run counted for itself alone"
_setup
_prior '{"blocking": 0, "important": 0, "nit": 1}'
assert_contains "🟠 Important | 1" "the reviewer's own count is not disturbed" -- _body summary-french.json

it "adds to a severity the reviewer also counted, rather than replacing it"
# The only case where the arithmetic can be told from an overwrite: this run
# raised one 🟠 and one of ours from an earlier push is still standing.
_setup
_prior '{"blocking": 0, "important": 1, "nit": 0}'
assert_contains "🟠 Important | 2" "one from this run plus one still standing" -- _body summary-french.json

it "keeps a zero at zero when nothing earlier is still live"
_setup
_prior '{"blocking": 0, "important": 0, "nit": 0}'
assert_contains "🟡 Mineur | 0" "nothing is invented" -- _body summary-french.json

it "adds them to a summary it adopts, not only to one it recovers"
# The adoption path runs when the execution file yielded nothing — a crashed or
# truncated run. That is exactly when the pull request most needs its standing
# verdict to be right, and the adopted text arrives after the recovered one has
# already been adjusted, so it is a separate chance to get this wrong.
_setup "[$_FR_BODY]"
_prior '{"blocking": 0, "important": 0, "nit": 1}'
assert_contains "🟡 Mineur | 1" "an adopted summary is corrected too" -- _body summary-absent.json

it "posts the reviewer's table untouched when the pre step left no measurement"
# The pre step is continue-on-error in review.yml, so the file can be absent.
# A missing measurement must not zero the table, and must not crash the post.
_setup
assert_contains "🟠 Important | 1" "a missing file changes nothing" -- _body_bare summary-french.json

# --- what `pre` measures, and for whom ---------------------------------------

_pre() {
  "$SCRIPTS/post-review.sh" --mode pre --repo o/r --pr 1 \
    --out "$TESTTMP/prior.md" --live-counts-out "$TESTTMP/prior-live.json" \
    >/dev/null 2>&1
  cat "$TESTTMP/prior.md" 2>/dev/null
}

_pre_counts() {
  "$SCRIPTS/post-review.sh" --mode pre --repo o/r --pr 1 \
    --out "$TESTTMP/prior.md" --live-counts-out "$TESTTMP/prior-live.json" \
    >/dev/null 2>&1
  cat "$TESTTMP/prior-live.json" 2>/dev/null || echo "(no counts written)"
}

it "counts a finding of ours that is still live"
_setup "[]" threads-prior-mixed.json
assert_contains '"nit": 1' "the live nit is measured, the outdated one is not" -- _pre_counts

it "does not count a finding of ours the author has resolved"
_setup "[]" threads-prior-mixed.json
assert_contains '"important": 0' "a resolved finding is not a standing one" -- _pre_counts

it "counts no blocking finding when neither 🔴 on the pull request is ours"
# Two decoys, one per mechanism: CodeRabbit is a bot but not us, and a human
# whose login happens to be `claude` is not a bot at all. Either filter failing
# alone puts a 1 here.
_setup "[]" threads-prior-mixed.json
assert_contains '"blocking": 0' "neither decoy is counted as ours" -- _pre_counts

# --- the ledger records findings, and a reply is not one ---------------------

_ledger() {
  _body_bare "$1" | python3 -c '
import base64, json, re, sys
body = sys.stdin.read()
match = re.search(r"claude-review:ledger ([A-Za-z0-9+/=]+)", body)
if not match:
    print("(no ledger block)")
else:
    payload = json.loads(base64.b64decode(match.group(1)).decode("utf-8"))
    print(json.dumps(payload, ensure_ascii=False))
'
}

it "keeps a reply out of the finding ledger it embeds"
# REST returns every review comment flat, replies included, and on a busy pull
# request they are the majority — 18 of the 28 on Aileaneprod/korbyx#164. A
# reply banked as a finding is one `pre` will later announce as a finding whose
# comment has disappeared, which of a reply is simply untrue.
_setup "[]" "" review-comments-with-reply.json
assert_not_contains "on y reviendra" "the reply is not a finding" -- _ledger summary-french.json

it "keeps the finding the reply hangs off"
_setup "[]" "" review-comments-with-reply.json
assert_contains "analytic-units.ts" "the finding itself is still recorded" -- _ledger summary-french.json

it "still lists every prior finding whoever posted it, so none gets reposted"
# The dedup list is deliberately wider than the count: we must not repeat
# CodeRabbit's finding either, even though it is not ours to tally.
_setup "[]" threads-prior-mixed.json
assert_contains "isolation.ts:88" "their finding stays in the do-not-repost list" -- _pre
