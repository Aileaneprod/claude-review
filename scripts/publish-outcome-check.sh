#!/usr/bin/env bash
#
# publish-outcome-check.sh — say on the pull request itself that no review ran.
#
# Usage:
#   publish-outcome-check.sh --repo OWNER/REPO --sha HEAD_SHA \
#                            --name NAME --conclusion neutral \
#                            --title TEXT --summary TEXT \
#                            [--only-if-exists] [--state-out FILE] [--dry-run]
#
# Upserts one check run of NAME on HEAD_SHA: PATCH the one already there,
# POST otherwise. Writes one word to --state-out — `created`, `updated`,
# `absent`, `denied` or `failed` — and never fails the job.
#
# --only-if-exists updates a check run already on this SHA and creates none.
# That is how a re-run corrects itself: the first attempt published `neutral`,
# the second one reviewed the same commit successfully, and the grey check
# would otherwise sit there contradicting the summary that just landed beside
# it. A run that never published one has nothing to correct.
#
# WHY THIS EXISTS. A review that could not happen concluded the job in
# `success`, so the check went green and read exactly like a review that ran
# and found nothing. Aileaneprod/korbyx#131 was merged in that state on
# 2026-09-09: three runs, three `success` conclusions, no review posted by any
# of them. The step summary, the annotation and the notice comment all said so;
# none of them is the thing a reviewer looks at, which is the check.
#
# WHY NOT JUST CONCLUDE THE JOB `neutral`. Because a job cannot. Measured on
# theo986/claude-review run 34414488366, three jobs in one workflow:
#
#   exit 78                              -> conclusion failure
#   job-level continue-on-error + exit 1 -> conclusion failure
#   POST /check-runs conclusion=neutral  -> a check run genuinely `neutral`
#
# The neutral exit code was removed when Actions moved off HCL, and nothing
# replaced it: github.com/orgs/community/discussions/9875 is still open asking
# for it. So the job stays green — it did do its job — and the fact the job
# cannot express is published beside it as its own check run.
#
# WHAT IT COSTS. Creating a check run needs `checks: write`, which the wrapper
# does not grant today. Under the wrapper's exact permission set the API
# answers, measured on run 34414735973:
#
#   {"message":"Resource not accessible by integration","status":"403"}
#
# That is why this exits 0 on a denial and says which permission is missing:
# a repository whose wrapper predates that line keeps the behaviour it has
# now, and learns from the job summary what to add. It does not lose a review.
#
# Requires: gh (authenticated via GH_TOKEN), python3.

set -euo pipefail

repo=""
sha=""
name=""
conclusion=""
title=""
summary=""
state_out=""
dry_run=0
only_if_exists=0

die() { printf 'publish-outcome-check: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)       [ "$#" -ge 2 ] || die "--repo requires a value";       repo="$2";       shift 2 ;;
    --sha)        [ "$#" -ge 2 ] || die "--sha requires a value";        sha="$2";        shift 2 ;;
    --name)       [ "$#" -ge 2 ] || die "--name requires a value";       name="$2";       shift 2 ;;
    --conclusion) [ "$#" -ge 2 ] || die "--conclusion requires a value"; conclusion="$2"; shift 2 ;;
    --title)      [ "$#" -ge 2 ] || die "--title requires a value";      title="$2";      shift 2 ;;
    --summary)    [ "$#" -ge 2 ] || die "--summary requires a value";    summary="$2";    shift 2 ;;
    --state-out)  [ "$#" -ge 2 ] || die "--state-out requires a value";  state_out="$2";  shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    --only-if-exists) only_if_exists=1; shift ;;
    -h|--help)    sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ]       || die "--repo is required"
[ -n "$name" ]       || die "--name is required"
[ -n "$conclusion" ] || die "--conclusion is required"
[ -n "$title" ]      || die "--title is required"
[ -n "$summary" ]    || die "--summary is required"

# A 40-hex SHA, not merely non-empty. `github.event.pull_request.head.sha` is
# empty outside a pull_request event, and the API answers an empty ref with a
# 404 on a DIFFERENT endpoint — a confusing failure for a step whose whole job
# is to be unconfusing. Refuse it here, by shape, where the reason can be said.
case "$sha" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
  *) die "--sha must be a commit SHA (got '${sha}')" ;;
esac
[ "${#sha}" -eq 40 ] || die "--sha must be a 40-character commit SHA (got ${#sha} characters)"

state="failed"
finish() {
  printf '%s' "$state" > "${state_out:-/dev/null}"
  exit 0
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Denial and absence are different answers and must not share a branch: a 403
# means "add the permission", a 200 with no match means "nothing to update".
# `gh api` exits non-zero on both, so the body is read rather than the code.
lookup_status=0
gh api "repos/${repo}/commits/${sha}/check-runs?check_name=$(printf '%s' "$name" | sed 's/ /%20/g')" \
  > "${work_dir}/existing.json" 2> "${work_dir}/existing.err" || lookup_status=$?

if [ "$lookup_status" -ne 0 ]; then
  if grep -q 'Resource not accessible by integration' "${work_dir}/existing.err" \
     "${work_dir}/existing.json" 2>/dev/null; then
    state="denied"
    printf 'publish-outcome-check: refused by the token — the calling workflow needs `checks: write`.\n' >&2
  else
    printf 'publish-outcome-check: could not read existing check runs: %s\n' \
      "$(head -1 "${work_dir}/existing.err" 2>/dev/null)" >&2
  fi
  finish
fi

existing_id="$(python3 - "${work_dir}/existing.json" "$name" <<'PY'
import json
import sys

path, wanted = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)

runs = payload.get("check_runs") if isinstance(payload, dict) else None
for run in runs or []:
    # The name filter is applied server-side, but a check run this workflow did
    # not create must never be overwritten: re-check it here rather than trust
    # a query string to be the only guard on a PATCH.
    if isinstance(run, dict) and run.get("name") == wanted and run.get("id"):
        print(run["id"])
        break
PY
)"

python3 - "${work_dir}/payload.json" "$name" "$sha" "$conclusion" "$title" "$summary" <<'PY'
import json
import sys

out, name, sha, conclusion, title, summary = sys.argv[1:7]
body = {
    "name": name,
    "head_sha": sha,
    "status": "completed",
    "conclusion": conclusion,
    "output": {"title": title, "summary": summary},
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(body, handle)
PY

if [ -n "$existing_id" ]; then
  endpoint="repos/${repo}/check-runs/${existing_id}"
  method="PATCH"
  done_state="updated"
elif [ "$only_if_exists" -eq 1 ]; then
  state="absent"
  finish
else
  endpoint="repos/${repo}/check-runs"
  method="POST"
  done_state="created"
fi

if [ "$dry_run" -eq 1 ]; then
  printf 'publish-outcome-check: dry run — would %s %s\n' "$method" "$endpoint" >&2
  state="$done_state"
  finish
fi

write_status=0
gh api "$endpoint" --method "$method" --input "${work_dir}/payload.json" \
  > "${work_dir}/write.json" 2> "${work_dir}/write.err" || write_status=$?

if [ "$write_status" -ne 0 ]; then
  if grep -q 'Resource not accessible by integration' "${work_dir}/write.err" \
     "${work_dir}/write.json" 2>/dev/null; then
    state="denied"
    printf 'publish-outcome-check: refused by the token — the calling workflow needs `checks: write`.\n' >&2
  else
    printf 'publish-outcome-check: %s %s failed: %s\n' "$method" "$endpoint" \
      "$(head -1 "${work_dir}/write.err" 2>/dev/null)" >&2
  fi
  finish
fi

state="$done_state"
printf 'publish-outcome-check: %s check run "%s" as %s\n' "$state" "$name" "$conclusion" >&2
finish
