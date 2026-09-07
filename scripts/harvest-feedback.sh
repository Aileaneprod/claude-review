#!/usr/bin/env bash
#
# harvest-feedback.sh — record what actually happened to each review finding.
#
# Usage:
#   harvest-feedback.sh --repo OWNER/REPO --pr N [--out DIR]
#
#   --repo OWNER/REPO  Repository whose pull request to harvest.
#   --pr N             Pull request number.
#   --out DIR          Where to write the ledger. Default: ../feedback
#   --threads-file F   Read the GraphQL response from F instead of calling the
#                      API. --rest-file F does the same for the REST call. Both
#                      exist so the tests can exercise the verdict reader
#                      against recorded replies; nothing in CI passes them.
#
# Writes feedback/<owner>/<repo>/<pr>.json: one record per review thread, with
# the finding, the author's reply verbatim, whether the thread was resolved,
# whether the code underneath changed, and — critically — the commit the finding
# was made against.
#
# WHY THE COMMIT MATTERS. A finding that was correct is indistinguishable from
# one that was wrong once the author has fixed it: the contradiction you would
# look for is exactly what the fix removed. Judging a past finding against the
# branch tip therefore scores correct findings as false positives. This script
# records `original_commit_id` so that never happens. That is not a theoretical
# concern — it is how a true positive on Aileaneprod/korbyx#13 was mis-scored.
#
# This script only COLLECTS. It never edits prompts. Turning records into
# lessons is propose-learnings.sh, whose output a human reviews and merges.
#
# Requires: gh (authenticated), python3.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

repo=""
pr_number=""
out_dir="${script_dir}/../feedback"
threads_file=""
rest_file=""

die() {
  printf 'harvest-feedback: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a value"; repo="$2";      shift 2 ;;
    --pr)   [ "$#" -ge 2 ] || die "--pr requires a value";   pr_number="$2"; shift 2 ;;
    --out)  [ "$#" -ge 2 ] || die "--out requires a value";  out_dir="$2";   shift 2 ;;
    --threads-file) [ "$#" -ge 2 ] || die "--threads-file requires a value"; threads_file="$2"; shift 2 ;;
    --rest-file)    [ "$#" -ge 2 ] || die "--rest-file requires a value";    rest_file="$2";    shift 2 ;;
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ]      || die "--repo is required"
[ -n "$pr_number" ] || die "--pr is required"
[ -n "$threads_file" ] || command -v gh >/dev/null 2>&1 || die "gh is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

owner="${repo%%/*}"
name="${repo##*/}"
[ -n "$owner" ] && [ -n "$name" ] || die "--repo must be OWNER/REPO"

work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# Threads carry the conversation and the resolution state; only GraphQL exposes
# isResolved and isOutdated.
#
# shellcheck disable=SC2016
# The query is deliberately single-quoted: $owner, $name and $pr are GraphQL
# variables bound by -F, and must reach the server unexpanded. Letting the shell
# interpolate them would send an empty, invalid query.
if [ -n "$threads_file" ]; then
  cp -- "$threads_file" "${work_dir}/threads.json"
else
gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
query($owner:String!, $name:String!, $pr:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$pr) {
      title
      state
      comments(first:100) {
        totalCount
        nodes { author { login } body createdAt }
      }
      reviewThreads(first:100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          comments(first:50) {
            nodes { databaseId author { login } body createdAt }
          }
        }
      }
    }
  }
}' >"${work_dir}/threads.json" 2>"${work_dir}/threads.err" \
  || { sed 's/^/harvest-feedback:   /' "${work_dir}/threads.err" >&2; die "GraphQL query failed"; }
fi

# REST carries original_commit_id — the SHA the comment was anchored to, which
# GraphQL does not expose on review threads.
if [ -n "$rest_file" ]; then
  cp -- "$rest_file" "${work_dir}/rest.json"
else
  gh api "repos/${repo}/pulls/${pr_number}/comments" --paginate --slurp \
    >"${work_dir}/rest.json" 2>/dev/null || printf '[]' >"${work_dir}/rest.json"
fi

mkdir -p "${out_dir}/${owner}/${name}"

python3 - "${work_dir}/threads.json" "${work_dir}/rest.json" \
          "${out_dir}/${owner}/${name}/${pr_number}.json" "$repo" "$pr_number" <<'PY'
import json
import re
import unicodedata
import sys

threads_path, rest_path, out_path, repo, pr = sys.argv[1:6]

with open(threads_path, encoding="utf-8") as fh:
    doc = json.load(fh)
pr_node = doc["data"]["repository"]["pullRequest"]

with open(rest_path, encoding="utf-8") as fh:
    pages = json.load(fh)
rest = []
for page in pages if isinstance(pages, list) else []:
    rest.extend(page if isinstance(page, list) else [page])
commit_by_id = {c.get("id"): c.get("original_commit_id") for c in rest}

BOTS = ("claude", "coderabbitai", "copilot", "sourcery-ai", "github-actions")


def is_bot(login):
    low = (login or "").lower()
    return any(low.startswith(b) for b in BOTS) or low.endswith("[bot]")


# The author's own words are the label. Guess a verdict for convenience, but
# always keep the raw text: the guess is a hint for a human, never a decision.
#
# THE FIRST WORD DECIDES. korbyx/CONTRIBUTING.md mandates one of four words at
# the head of every reply — Retenu, Écarté, Partiel, Vu — and that rule exists
# so this guess stops depending on a substring search over a whole sentence.
# The search it replaces read "Retenu — le faux positif est sur le point
# voisin" as a rejection: the exact inversion of what the author wrote. The
# keyword lists below stay, as a fallback for the 148 replies written before
# the vocabulary existed.
#
# `Vu` maps to accepted on purpose: CONTRIBUTING.md defines it as "le constat
# est juste mais traité ailleurs", which is a true positive for precision. The
# nuance is not lost — `human_reply` keeps the reply verbatim.
FIRST_WORD = (("retenu", "accepted"), ("ecart", "rejected"), ("partiel", "partial"))

ACCEPT = ("corrigé", "corrige", "fixed", "corrected", "appliqué", "applique",
          "le constat est exact", "le constat est juste", "good catch", "done")
REJECT = ("écarté", "ecarte", "rejected", "declined", "not a", "faux positif",
          "false positive", "invalide", "no change")
PARTIAL = ("à moitié", "a moitie", "partiel", "partially", "en partie")


def first_word(text):
    """Lower-cased, accent-stripped, freed of the markdown CONTRIBUTING.md
    itself uses (**Retenu**) and of the punctuation that always follows."""
    stripped = unicodedata.normalize("NFD", (text or "").strip().lower())
    stripped = "".join(c for c in stripped if not unicodedata.combining(c))
    return re.split(r"[^a-z]+", stripped.lstrip("*_># 	-"), 1)[0]


def guess(text):
    word = first_word(text)
    for prefix, verdict in FIRST_WORD:
        if word.startswith(prefix):
            return verdict
    if word == "vu":
        return "accepted"
    low = (text or "").lower()
    if any(k in low for k in PARTIAL):
        return "partial"
    if any(k in low for k in REJECT):
        return "rejected"
    if any(k in low for k in ACCEPT):
        return "accepted"
    return "unknown"


records = []
for thread in pr_node["reviewThreads"]["nodes"]:
    comments = thread["comments"]["nodes"]
    if not comments:
        continue
    first = comments[0]
    author = (first.get("author") or {}).get("login") or "unknown"
    if not is_bot(author):
        continue  # human-initiated threads are not our findings to score

    human_replies = [
        c for c in comments[1:]
        if not is_bot((c.get("author") or {}).get("login"))
    ]
    verdict_text = human_replies[0]["body"] if human_replies else ""

    records.append({
        "reviewer": author,
        "path": thread.get("path"),
        "line": thread.get("line"),
        # The SHA the finding was anchored to. Re-check findings against THIS,
        # never against the branch tip.
        "reviewed_commit": commit_by_id.get(first.get("databaseId")),
        "finding": first.get("body", ""),
        "finding_at": first.get("createdAt"),
        "human_reply": verdict_text,
        "human_reply_at": human_replies[0]["createdAt"] if human_replies else None,
        "verdict_guess": guess(verdict_text) if verdict_text else "no_reply",
        "resolved": thread.get("isResolved"),
        "outdated": thread.get("isOutdated"),
    })

# Did our reviewer read this pull request at all?
#
# Presence used to be inferred from inline comments, so a review that COMPLETED
# and had nothing to file was indistinguishable from one that never ran. That
# distinction is the whole miss heuristic: report.sh counts a blocking finding
# of theirs against us only when we "said nothing on that pull request", and a
# reviewer whose job description says silence is a valid and frequent outcome
# was therefore punished for doing exactly what it was told.
#
# Measured, not supposed: on Aileaneprod/korbyx#92 our reviewer ran three times
# and posted a reasoned 0/0/0 summary that had read the Terraform, the migration
# and the README. The ledger held nothing from us for that pull request. Five of
# the seven "blocking findings only they caught" sit on pull requests shaped
# like that one.
#
# The sticky summary is the artefact that says we were there. post-review.sh
# writes the marker below and owns that comment; nothing else emits it.
SUMMARY_MARKER = "<!-- claude-review:summary -->"

# And it has to have been posted BY us. The marker is a plain string in a public
# comment thread: anybody can type it, and the people most likely to are the ones
# discussing this tool — the pull request that introduced this check quotes the
# marker three times in its own body. A presence flag that a passer-by can set is
# not evidence, and it inflates the one number the whole ledger exists to answer.
#
# These two accounts are the only ones post-review.sh can run as: the Claude
# GitHub App when `use_github_app` is true, and the workflow's own token
# otherwise.
#
# Compared WITHOUT the `[bot]` suffix, because the two GitHub APIs disagree about
# it and this file reads the one that omits it. Measured on korbyx#92:
#
#     GraphQL  author.login = "github-actions"        __typename = Bot
#     REST     user.login   = "github-actions[bot]"   type       = Bot
#
# The first version of this guard compared against the REST spelling and rejected
# every real summary — 116 documents harvested, zero presence recorded — while
# its test passed, because the fixture had been "corrected" to the REST spelling
# at the same time. Fixture and code were wrong together, which is the failure
# this repository keeps writing down.
OUR_POSTERS = ("claude", "github-actions")


def posted_by_us(author):
    login = ((author or {}).get("login") or "").lower()
    if login.endswith("[bot]"):
        login = login[:-len("[bot]")]
    return login in OUR_POSTERS

# One page is read, and the busiest pull request on the repository this serves
# carries 16 comments — so this is a bound, not a live problem. It is reported
# anyway because the failure mode is a SILENT loss of the only evidence that our
# reviewer was present, and a number built on a partial read that nobody
# announced is the thing this whole ledger exists not to produce.
issue_comments = (pr_node.get("comments") or {})
seen_comments = issue_comments.get("nodes") or []
total_comments = issue_comments.get("totalCount")
if isinstance(total_comments, int) and total_comments > len(seen_comments):
    sys.stderr.write(
        "harvest-feedback: read only the first %d of %d comments on %s#%s; "
        "if our summary is beyond that, presence will read as absent\n"
        % (len(seen_comments), total_comments, repo, pr))

our_summary_at = None
for comment in seen_comments:
    if not isinstance(comment, dict):
        continue
    if not posted_by_us(comment.get("author")):
        continue
    if SUMMARY_MARKER in (comment.get("body") or ""):
        # The sticky is upserted in place, so there is normally exactly one.
        # Take the last if a stray duplicate survives collapsing.
        our_summary_at = comment.get("createdAt") or our_summary_at

out = {
    "repo": repo,
    "pr": int(pr),
    "title": pr_node.get("title"),
    "state": pr_node.get("state"),
    "reviewed_by_ours": our_summary_at is not None,
    "our_summary_at": our_summary_at,
    "findings": records,
}
with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

by_reviewer = {}
for r in records:
    slot = by_reviewer.setdefault(r["reviewer"], {})
    slot[r["verdict_guess"]] = slot.get(r["verdict_guess"], 0) + 1

sys.stderr.write("harvest-feedback: %s#%s -> %s\n" % (repo, pr, out_path))
for reviewer, counts in sorted(by_reviewer.items()):
    detail = ", ".join("%s=%d" % kv for kv in sorted(counts.items()))
    sys.stderr.write("  %-22s %s\n" % (reviewer, detail))
PY
