#!/usr/bin/env bash
#
# rereview-open-prs.sh — replay the reviews an outage swallowed.
#
# Usage:
#   rereview-open-prs.sh --repo OWNER/REPO [--rerun] [--limit N]
#                        [--workflow PATH] [--check NAME]
#
#   --rerun        Replay the runs. Without it this only reports.
#   --limit N      Replay at most N of them. Default: all.
#   --workflow P   The wrapper's path in the target repo.
#                  Default .github/workflows/ai-review.yml
#   --check NAME   Outcome check to read. Default "AI review outcome" —
#                  OUTCOME_CHECK_NAME in review.yml.
#
# Finds every OPEN pull request whose head commit carries that check concluded
# `neutral` — the mark review.yml leaves on a push it could not review — and,
# with --rerun, replays the workflow run that left it.
#
# WHY THIS EXISTS. On 2026-09-17 the subscription behind
# CLAUDE_CODE_OAUTH_TOKEN reached its limit. Four Aileaneprod/korbyx pull
# requests (228-231) came back `api_error_status 429`, `terminal_reason
# api_error`, and went unreviewed. Nothing brings those back once quota
# returns: the wrapper listens to `pull_request` events only, so a review
# arrives on the NEXT push — and a branch whose work is finished never pushes
# again. The four sat there until a person happened to look.
#
# WHY THE CHECK AND NOT THE RUN'S CONCLUSION. The run concludes `success`
# either way. The reviewer step is `continue-on-error` on purpose — a reviewer
# that fails must never block a merge — so an exhausted quota and a clean
# review wear the same green tick. `neutral` on the outcome check is the only
# machine-readable record that a push went unreviewed, which is the whole
# reason publish-outcome-check.sh exists.
#
# The corollary: a repository whose wrapper lacks `checks: write` publishes no
# such check, so its misses are invisible here. That is worth saying out loud
# rather than reporting a confident zero — so the wrapper is read first, and a
# missing permission named.
#
# WHY REPLAY AND NOT PUSH. `gh run rerun` replays the original event against
# the same commit: nothing added to someone else's branch, nobody watching the
# pull request notified, and it picks up claude-review@v1 as it stands now.
# The alternatives — an empty commit, or close-and-reopen — both write to
# something that is not ours to write to.
#
# WHY IT REPORTS BY DEFAULT. Quota is the scarce resource in this design and
# every line of the list costs a full review. Read the list, then pass --rerun.
#
# EXIT STATUS. 0 when every open pull request was inspected, whatever that
# turned up. 1 when one or more of them could not be — an answer assembled out
# of a read that failed is incomplete, and a scheduled caller has the status
# and nothing else to tell it so.
#
# Requires: gh (authenticated), python3.

set -euo pipefail

repo=""
rerun=0
limit=0
workflow=".github/workflows/ai-review.yml"
check_name="AI review outcome"

die() { printf 'rereview-open-prs: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)     [ "$#" -ge 2 ] || die "--repo requires a value";     repo="$2";       shift 2 ;;
    --limit)    [ "$#" -ge 2 ] || die "--limit requires a value";    limit="$2";      shift 2 ;;
    --workflow) [ "$#" -ge 2 ] || die "--workflow requires a value"; workflow="$2";   shift 2 ;;
    --check)    [ "$#" -ge 2 ] || die "--check requires a value";    check_name="$2"; shift 2 ;;
    --rerun)    rerun=1; shift ;;
    -h|--help)  sed -n '2,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ] || die "--repo is required"
case "$repo" in */*) ;; *) die "--repo must be OWNER/REPO (got '${repo}')" ;; esac
case "$limit" in *[!0-9]*) die "--limit must be a whole number (got '${limit}')" ;; esac

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Read the wrapper before anything else. Two different nothings look identical
# from the check runs alone — "every open pull request was reviewed" and "this
# repository cannot publish the check that would tell me otherwise" — and only
# the wrapper tells them apart.
if ! gh api "repos/${repo}/contents/${workflow}" -H "Accept: application/vnd.github.raw" \
     > "${work_dir}/wrapper.yml" 2>"${work_dir}/wrapper.err"; then
  die "no wrapper at ${workflow} on ${repo} — is this repository wired to claude-review? ($(head -1 "${work_dir}/wrapper.err" 2>/dev/null))"
fi
# Anchored, and a `#` before it disqualifies the line. `grep 'checks: *write'`
# was satisfied by a wrapper that merely MENTIONS the permission — a commented
# line, or the sentence docs/SETUP.md tells people to paste — and then stayed
# quiet about the exact blind spot it exists to announce.
if ! grep -Eq '^[[:space:]]*checks:[[:space:]]*write[[:space:]]*(#.*)?$' \
     "${work_dir}/wrapper.yml"; then
  printf 'rereview-open-prs: WARNING — %s does not grant `checks: write`, so review.yml\n' "$workflow" >&2
  printf '  cannot publish "%s" and an unreviewed push leaves no trace this can read.\n' "$check_name" >&2
  printf '  Whatever it reports below is a floor, not a count.\n' >&2
fi

gh api "repos/${repo}/pulls?state=open&per_page=100" --paginate --slurp \
  > "${work_dir}/pulls.json" 2>"${work_dir}/pulls.err" \
  || die "could not list open pull requests: $(head -1 "${work_dir}/pulls.err" 2>/dev/null)"

# `--slurp` returns an array of pages; flatten one level — the same shape
# post-review.sh reads.
pulls="$(python3 - "${work_dir}/pulls.json" <<'PY'
import json
import sys

# Exit 1, not 0. Swallowing an unreadable payload here prints nothing, and
# nothing is indistinguishable from "this repository has no open pull
# requests" — a clean answer, stated with confidence, out of a read that
# failed.
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        pages = json.load(handle)
except (OSError, ValueError) as error:
    sys.stderr.write("%s\n" % error)
    raise SystemExit(1)

for page in pages if isinstance(pages, list) else []:
    for pull in page if isinstance(page, list) else [page]:
        if not isinstance(pull, dict):
            continue
        head = pull.get("head") or {}
        sha, number = head.get("sha"), pull.get("number")
        if sha and number:
            print("%s\t%s\t%s" % (number, sha, head.get("ref") or "?"))
PY
)" || die "could not read the open pull requests of ${repo} — the API answered something this cannot parse"

if [ -z "$pulls" ]; then
  printf 'rereview-open-prs: %s has no open pull requests.\n' "$repo"
  exit 0
fi

# --- which of them went unreviewed -------------------------------------------

# The whole name, not only its spaces: a --check carrying `&`, `#` or `?`
# rewrites the query string and the answer comes back for a different question.
# (publish-outcome-check.sh encodes spaces alone; it is only ever handed
# OUTCOME_CHECK_NAME, where the difference cannot show.)
encoded_check="$(python3 -c \
  'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' \
  "$check_name")"
targets=""
unreviewed=0
unknown=0

# One exit, so that no branch of this can forget what an uninspected pull
# request does to the answer. A caller that reads no output at all — a
# scheduled one — has only the status to go on.
finish() { [ "$unknown" -eq 0 ] || exit 1; exit 0; }

while IFS="	" read -r number sha ref; do
  [ -n "$number" ] || continue

  if ! gh api "repos/${repo}/commits/${sha}/check-runs?check_name=${encoded_check}" \
       > "${work_dir}/checks.json" 2>/dev/null; then
    unknown=$((unknown + 1))
    printf '  PR %-5s could not read its check runs — NOT inspected\n' "$number" >&2
    continue
  fi

  # `neutral` only. A `success` on this check is a run that already corrected
  # itself (publish-outcome-check.sh --only-if-exists), and reviewing it again
  # spends quota to confirm what the pull request already says.
  conclusion="$(python3 - "${work_dir}/checks.json" "$check_name" <<'PY'
import json
import sys

# Same rule as the pull request list above: an answer that cannot be read
# exits 1, rather than passing for "no neutral check here, so this one was
# reviewed".
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)

runs = payload.get("check_runs") if isinstance(payload, dict) else None
latest = None
for run in runs or []:
    if not isinstance(run, dict) or run.get("name") != sys.argv[2]:
        continue
    if latest is None or (run.get("id") or 0) > (latest.get("id") or 0):
        latest = run
if latest:
    print(latest.get("conclusion") or "")
PY
)" || {
    unknown=$((unknown + 1))
    printf '  PR %-5s %s — its check runs came back unreadable, NOT inspected\n' \
      "$number" "$ref" >&2
    continue
  }
  [ "$conclusion" = "neutral" ] || continue
  unreviewed=$((unreviewed + 1))

  # A check run is created through the API and carries no link back to the
  # workflow run that asked for it, so the run is found the other way round:
  # the runs on this commit, filtered to the wrapper's own path.
  # A failure here counts like the two above it. This branch used to warn and
  # move on with the count untouched, on the reasoning that the pull request
  # had been inspected — it is known unreviewed, and only its run was missing.
  # But what the caller is told, "none of them replayable", is then a claim
  # built on a read that failed, and the status stayed 0 while the two
  # identical branches above exited 1. One more way to say a thing is fine when
  # it was never looked at.
  if ! gh api "repos/${repo}/actions/runs?head_sha=${sha}&per_page=100" \
       > "${work_dir}/runs.json" 2>/dev/null; then
    unknown=$((unknown + 1))
    printf '  PR %-5s %s — could not list its workflow runs\n' "$number" "$ref" >&2
    continue
  fi

  run_line="$(python3 - "${work_dir}/runs.json" "$workflow" <<'PY'
import json
import sys

# Exit 1, so that "I could not read this" stays distinguishable from "there is
# genuinely no run here" — which is a real answer, reached by looking, and the
# one case on this path that deserves to leave the status at 0.
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)

runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
latest = None
for run in runs or []:
    if not isinstance(run, dict) or run.get("path") != sys.argv[2]:
        continue
    if latest is None or (run.get("id") or 0) > (latest.get("id") or 0):
        latest = run
if latest:
    print("%s\t%s\t%s" % (latest.get("id"), latest.get("run_attempt") or 1,
                          latest.get("status") or "?"))
PY
)" || {
    unknown=$((unknown + 1))
    printf '  PR %-5s %s — its workflow runs came back unreadable\n' "$number" "$ref" >&2
    continue
  }

  if [ -z "$run_line" ]; then
    printf '  PR %-5s %s — unreviewed, but no %s run on %s to replay\n' \
      "$number" "$ref" "$workflow" "$(printf '%s' "$sha" | cut -c1-7)" >&2
    continue
  fi

  run_id="$(printf '%s' "$run_line" | cut -f1)"
  attempt="$(printf '%s' "$run_line" | cut -f2)"
  status="$(printf '%s' "$run_line" | cut -f3)"

  # A run still going is already answering the question. Replaying it now would
  # either be refused or race the attempt in flight for the same sticky comment.
  if [ "$status" != "completed" ]; then
    printf '  PR %-5s %s — run %s is %s already, left alone\n' \
      "$number" "$ref" "$run_id" "$status" >&2
    continue
  fi

  printf '  PR %-5s %s  run %s (attempt %s)  %s\n' \
    "$number" "$(printf '%s' "$sha" | cut -c1-7)" "$run_id" "$attempt" "$ref"
  targets="${targets}${number} ${run_id}
"
done <<EOF
$pulls
EOF

count="$(printf '%s' "$targets" | grep -c . || true)"

# A pull request this could not inspect is not a pull request with a review,
# and the clean-sweep line below is the one sentence that must never be printed
# on incomplete information — it is the sentence a maintainer acts on by doing
# nothing.
if [ "$unknown" -gt 0 ]; then
  printf 'rereview-open-prs: %s open pull request(s) could not be fully inspected. What follows is incomplete.\n' \
    "$unknown" >&2
fi

if [ "$count" -eq 0 ]; then
  if [ "$unreviewed" -gt 0 ]; then
    printf 'rereview-open-prs: %s unreviewed pull request(s), none of them replayable.\n' "$unreviewed"
  elif [ "$unknown" -eq 0 ]; then
    printf 'rereview-open-prs: every open pull request on %s carries a review.\n' "$repo"
  fi
  finish
fi

if [ "$rerun" -eq 0 ]; then
  printf '\nrereview-open-prs: %s pull request(s) went unreviewed. Pass --rerun to replay them.\n' "$count"
  finish
fi

# --- replay ------------------------------------------------------------------

replayed=0
while read -r number run_id; do
  [ -n "$run_id" ] || continue
  if [ "$limit" -gt 0 ] && [ "$replayed" -ge "$limit" ]; then
    printf 'rereview-open-prs: stopped at --limit %s.\n' "$limit"
    break
  fi
  if gh run rerun "$run_id" --repo "$repo" >/dev/null 2>"${work_dir}/rerun.err"; then
    replayed=$((replayed + 1))
    printf '  replayed PR %s (run %s)\n' "$number" "$run_id"
  else
    printf '  PR %s (run %s) refused the replay: %s\n' \
      "$number" "$run_id" "$(head -1 "${work_dir}/rerun.err" 2>/dev/null)" >&2
  fi
done <<EOF
$targets
EOF

printf '\nrereview-open-prs: replayed %s of %s.\n' "$replayed" "$count"
finish
