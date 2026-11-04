#!/usr/bin/env bash
#
# post-notice.sh — own the single "this push was not reviewed" comment.
#
# Usage:
#   post-notice.sh --repo OWNER/REPO --pr N --sha HEAD_SHA --body-file FILE \
#                  [--state-out FILE] [--dry-run]
#   post-notice.sh --repo OWNER/REPO --pr N --collapse \
#                  [--state-out FILE] [--dry-run]
#
# One live notice per pull request, keyed on the push it is about:
#
#   --body-file   The notice for HEAD_SHA. A notice already on this SHA is
#                 PATCHed in place — a re-run of the same push corrects itself
#                 instead of adding a line. Notices about OTHER pushes are
#                 collapsed, and a fresh one is posted so it lands where the
#                 author will see it.
#   --collapse    Collapse every notice on the pull request and post nothing.
#                 This is what a SUCCESSFUL review calls.
#
# Writes one word to --state-out — `created`, `updated`, `collapsed`, `absent`
# or `failed` — and never fails the job. A notice is a diagnostic; losing the
# job over it would cost more than the notice is worth.
#
# WHY THIS EXISTS. The notice used to be a bare `gh pr comment`, with no
# marker (review.yml, before this script). Two consequences, both measured on
# Aileaneprod/korbyx on 2026-11-04:
#
#   * it accumulated — five notices on #746, three each on #677 and #735, one
#     per push that could not be reviewed;
#   * nothing ever retracted it. `post-review.sh` owns the summary on its own
#     marker and PATCHes it in place, and a PATCHed comment does not move from
#     its creation date. So on #735, #626, #665 and #677 a real review landed
#     between 11:55Z and 12:09Z that day, into a sticky created days earlier,
#     while the last visible comment stayed "This push was not reviewed".
#
# A coordinating session read those four pull requests and wrote in a handover
# that four reviews were missing. They were not; all four were delivered. That
# is the cost being paid here: not a lost review, a reviewer whose output
# cannot be trusted to mean what it says. The check run already corrects
# itself this way — publish-outcome-check.sh --only-if-exists, added for the
# same defect one signal across. This is the comment's half of it.
#
# WHY COLLAPSE AND NOT DELETE. Same rule post-review.sh states for duplicate
# summaries: this only ever rewrites comments we authored, and never removes
# anything. A collapsed notice is one short line; the thread keeps its history
# without three alarms standing in it.
#
# WHAT IT ADOPTS. Notices posted before this script carry no marker, so they
# can only be recognised by their text. The signature used is narrow on
# purpose: authored by one of OUR_POSTERS with account type Bot, body starting
# with the robot emoji, AND ending on "This does not block merging." — the one
# sentence all three notice bodies in review.yml share. Without the adoption
# the pull requests that are confusing people today would stay confusing.
#
# Requires: gh (authenticated via GH_TOKEN), python3.

set -euo pipefail

repo=""
pr_number=""
sha=""
body_file=""
collapse=0
state_out=""
dry_run=0

MARKER_PREFIX='<!-- claude-review:notice'

die() {
  printf 'post-notice: %s\n' "$1" >&2
  exit 1
}

# The pessimistic answer is on disk before anything can fail to overwrite it,
# so a crash cannot be read as a notice that was posted.
record_state() { [ -n "$state_out" ] && printf '%s' "$1" > "$state_out"; return 0; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      [ "$#" -ge 2 ] || die "--repo requires a value";      repo="$2";       shift 2 ;;
    --pr)        [ "$#" -ge 2 ] || die "--pr requires a value";        pr_number="$2";  shift 2 ;;
    --sha)       [ "$#" -ge 2 ] || die "--sha requires a value";       sha="$2";        shift 2 ;;
    --body-file) [ "$#" -ge 2 ] || die "--body-file requires a value"; body_file="$2";  shift 2 ;;
    --state-out) [ "$#" -ge 2 ] || die "--state-out requires a value"; state_out="$2";  shift 2 ;;
    --collapse)  collapse=1; shift ;;
    --dry-run)   dry_run=1; shift ;;
    -h|--help)   sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ]      || die "--repo is required"
[ -n "$pr_number" ] || die "--pr is required"

if [ "$collapse" -eq 1 ]; then
  [ -z "$body_file" ] || die "--collapse and --body-file are mutually exclusive"
else
  [ -n "$body_file" ] || die "--body-file is required unless --collapse is given"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  [ -n "$sha" ]       || die "--sha is required unless --collapse is given"
fi

record_state failed

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# A notice we cannot read the thread for is a notice we cannot place. Say so
# and leave the pull request as it is rather than guessing.
if ! gh api "repos/${repo}/issues/${pr_number}/comments" --paginate --slurp \
     >"${work_dir}/pages.json" 2>"${work_dir}/err"; then
  printf 'post-notice: warning: could not list comments on %s#%s\n' "$repo" "$pr_number" >&2
  sed 's/^/post-notice:   /' "${work_dir}/err" >&2 || true
  exit 0
fi

python3 - "${work_dir}/pages.json" "${work_dir}/plan.json" "$MARKER_PREFIX" \
         "${sha:-}" "$collapse" <<'PY'
import json
import sys

pages_path, plan_path, marker_prefix, sha, collapse_flag = sys.argv[1:6]
collapse_all = collapse_flag == "1"

with open(pages_path, encoding="utf-8") as handle:
    data = json.load(handle)

# `--paginate --slurp` yields an array of pages; flatten one level so the rest
# of this always sees a flat list of comment objects.
comments = []
if isinstance(data, list):
    for item in data:
        if isinstance(item, list):
            comments.extend(x for x in item if isinstance(x, dict))
        elif isinstance(item, dict):
            comments.append(item)

OUR_POSTERS = ("claude", "github-actions")

# The one sentence every notice body in review.yml ends on. See WHAT IT ADOPTS.
LEGACY_TAIL = "This does not block merging."
LEGACY_OPEN = "\U0001F916"  # the robot emoji every notice body starts with


def ours(comment):
    user = comment.get("user") or {}
    if user.get("type") != "Bot":
        return False
    login = (user.get("login") or "").lower()
    if login.endswith("[bot]"):
        login = login[: -len("[bot]")]
    return login in OUR_POSTERS


def is_notice(comment):
    if not ours(comment):
        return False
    body = comment.get("body") or ""
    if body.lstrip().startswith(marker_prefix):
        return True
    stripped = body.strip()
    return stripped.startswith(LEGACY_OPEN) and stripped.endswith(LEGACY_TAIL)


def about_this_push(comment):
    """Does this notice already carry our marker for THIS head SHA?

    Only a marked notice can say which push it belongs to. An adopted legacy
    notice carries no SHA, so it is never matched here and is collapsed
    instead — which is the honest reading: we do not know what push it was
    about, so we do not claim it was this one.
    """
    if not sha:
        return False
    body = (comment.get("body") or "").lstrip()
    if not body.startswith(marker_prefix):
        return False
    head = body.split("-->", 1)[0]
    return ("sha=" + sha) in head


def is_stub(comment):
    """A notice this script already collapsed; nothing left to rewrite.

    A live notice carries ` sha=` after the prefix; a stub carries ` -->`.
    Without this the stubs come back into `notices` on every later run, which
    costs one PATCH per stub per unreviewed push — the count growing with the
    pile, on a script written to stop a pile growing — and makes `--collapse`
    on a pull request holding only stubs report `collapsed` where `absent` is
    correct, contradicting what state_for() below promises.
    """
    body = (comment.get("body") or "").lstrip()
    return body.startswith(marker_prefix + " -->")


notices = [c for c in comments if is_notice(c) and not is_stub(c)]
notices.sort(key=lambda c: (c.get("created_at") or "", c.get("id") or 0))

if collapse_all:
    plan = {"action": "collapse", "id": None,
            "collapse": [c["id"] for c in notices]}
else:
    same = [c for c in notices if about_this_push(c)]
    if same:
        # Newest wins: if an earlier attempt somehow left two on this SHA, the
        # one we keep is the one the author saw last.
        target = same[-1]["id"]
        plan = {"action": "patch", "id": target,
                "collapse": [c["id"] for c in notices if c["id"] != target]}
    else:
        plan = {"action": "create", "id": None,
                "collapse": [c["id"] for c in notices]}

with open(plan_path, "w", encoding="utf-8") as handle:
    json.dump(plan, handle)

sys.stderr.write(
    "post-notice: %s; %d existing notice(s), %d to collapse\n"
    % (plan["action"], len(notices), len(plan["collapse"])))
PY

action="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["action"])' "${work_dir}/plan.json")"

# Build every payload as JSON so bodies survive quoting, newlines and emoji.
if [ "$action" != "collapse" ]; then
  python3 - "$body_file" "${work_dir}/payload.json" "$MARKER_PREFIX" "$sha" <<'PY'
import json
import sys

body_path, payload_path, marker_prefix, sha = sys.argv[1:5]

with open(body_path, encoding="utf-8") as handle:
    body = handle.read().strip()

marker = "%s sha=%s -->" % (marker_prefix, sha)

with open(payload_path, "w", encoding="utf-8") as handle:
    json.dump({"body": marker + "\n" + body}, handle)
PY
fi

python3 - "${work_dir}/collapsed.json" "$MARKER_PREFIX" "$action" <<'PY'
import json
import sys

payload_path, marker_prefix, action = sys.argv[1:4]

# Two different truths, and saying the wrong one is worse than saying nothing.
# After a success the review exists and the reader should go find it; when a
# notice is merely superseded by a newer notice, no review has landed.
if action == "collapse":
    tail = ("_Superseded — this push was reviewed after all. "
            "See the review summary on this pull request._")
else:
    tail = ("_Superseded — see the current notice at the end of this "
            "pull request._")

with open(payload_path, "w", encoding="utf-8") as handle:
    json.dump({"body": marker_prefix + " -->\n" + tail}, handle)
PY

collapse_ids="$(python3 -c '
import json, sys
print(" ".join(str(i) for i in json.load(open(sys.argv[1]))["collapse"]))
' "${work_dir}/plan.json")"

# The witness speaks the vocabulary the header documents, not the plan's own
# verbs. `absent` is a collapse with nothing to collapse — a successful review
# on a pull request that never had a notice, which is the common case and must
# not read like a notice was retracted.
state_for() {
  case "$1" in
    create)   printf created ;;
    patch)    printf updated ;;
    collapse) [ -n "$collapse_ids" ] && printf collapsed || printf absent ;;
  esac
}

if [ "$dry_run" -eq 1 ]; then
  printf 'post-notice: dry run — would %s\n' "$action" >&2
  if [ "$action" != "collapse" ]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' \
      "${work_dir}/payload.json"
  fi
  record_state "$(state_for "$action")"
  exit 0
fi

# Collapse first. If the create below fails, the thread is left with collapsed
# stubs and no alarm, which is quieter than two live notices.
for stale_id in $collapse_ids; do
  gh api "repos/${repo}/issues/comments/${stale_id}" \
    --method PATCH --input "${work_dir}/collapsed.json" >/dev/null 2>&1 \
    && printf 'post-notice: collapsed notice %s\n' "$stale_id" >&2 \
    || printf 'post-notice: warning: could not collapse notice %s\n' "$stale_id" >&2
done

case "$action" in
  collapse)
    record_state "$(state_for collapse)"
    ;;
  patch)
    comment_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${work_dir}/plan.json")"
    if gh api "repos/${repo}/issues/comments/${comment_id}" \
         --method PATCH --input "${work_dir}/payload.json" >/dev/null; then
      record_state updated
      printf 'post-notice: updated notice %s for %s\n' "$comment_id" "$sha" >&2
    else
      printf 'post-notice: warning: could not update notice %s\n' "$comment_id" >&2
    fi
    ;;
  create)
    if gh api "repos/${repo}/issues/${pr_number}/comments" \
         --method POST --input "${work_dir}/payload.json" >/dev/null; then
      record_state created
      printf 'post-notice: posted notice for %s\n' "$sha" >&2
    else
      printf 'post-notice: warning: could not post the notice\n' >&2
    fi
    ;;
esac

exit 0
