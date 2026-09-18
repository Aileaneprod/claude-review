#!/usr/bin/env bash
#
# post-review.sh — own the single sticky summary comment on a pull request.
#
# Usage:
#   post-review.sh --mode pre  --repo OWNER/REPO --pr N --out FILE \
#                  [--live-counts-out FILE]
#   post-review.sh --mode post --repo OWNER/REPO --pr N \
#                  [--execution-file FILE] [--body-file FILE] \
#                  [--prior-live FILE] [--posted-out FILE] [--dry-run]
#
# pre   Read the existing sticky comment's finding ledger plus the review
#       threads already on the PR, and write them as markdown to --out, grouped
#       by what the reviewer should do with each. That file is fed into the
#       prompt so a re-review after a push does not repost findings the author
#       has already seen.
#
#       --live-counts-out writes {"blocking":N,"important":N,"nit":N}: how many
#       findings OF OURS are still standing — neither resolved nor stranded on
#       lines that have changed. `post` adds them to the reviewer's own counts,
#       because the sticky comment is the pull request's standing verdict and
#       not a log of the last run.
#
#       Measured here, before the reviewer runs, and deliberately not in `post`:
#       claude-code-action writes the execution file some milliseconds before it
#       flushes the buffered inline comments, so a count taken at post time can
#       miss the comments the run has just made.
#
#       The same file carries the SUPPRESSION RECORD: one {path, key, severity,
#       by} entry per finding this run tells the reviewer not to file, because
#       the other reviewer or a human posted it first. It rides --live-counts-out
#       rather than a flag of its own because review.yml already hands that one
#       file from `pre` to `post`, and the workflow is versioned separately from
#       the scripts it calls — a new flag would go dark on every consumer still
#       pinned to the old workflow.
#
#       `key` is sha256(the thread's opening comment)[:8] — byte for byte the
#       digest harvest-feedback.sh keys a finding by, and the digest inside the
#       `key` classify-verdicts.sh writes. That is the whole point: the ledger
#       and this record join without either side learning a new identifier.
#
# post  Recover the summary the reviewer produced, then upsert it as the sticky
#       comment: PATCH the one carrying the marker if it exists, POST otherwise.
#       A base64 JSON ledger of finding hashes is embedded in an HTML comment so
#       the next `pre` run can read it back.
#
#       That ledger (version 2) also carries the suppression record `pre`
#       measured, unioned with the one the previous sticky held, and for each
#       entry whether THIS summary independently called that finding blocking.
#       The sticky comment is the only durable place for it: harvest-feedback.sh
#       already reads this comment's body, so nothing new has to be fetched for
#       the record to reach the ledger and, from there, the page.
#
#       The summary is taken from the action's execution file (a JSON array of
#       SDK messages; we want the last assistant text block). If that yields
#       nothing — a crashed run, a truncated transcript — we fall back to a
#       summary the reviewer posted itself and adopt it in place.
#
#       --posted-out writes `true` or `false`: whether a comment actually
#       landed. This is the ONLY witness of that, and review.yml gates its
#       "AI review unavailable" notice on it.
#
#       That notice used to key off the reviewer step's exit code, which is a
#       different question. `claude-code-action` validates the turn count
#       AFTER the run and fails the step when it overran, even when the CLI
#       reported success — so a finished review was announced as unavailable
#       and its summary thrown away (Aileaneprod/korbyx#110, run 34058925818).
#       Two conditions derived from one signal also drift: the pair could both
#       speak, or both stay silent. One witness, consulted once.
#
# Requires: gh (authenticated via GH_TOKEN), python3.

set -euo pipefail

MARKER='<!-- claude-review:summary -->'
LEDGER_PREFIX='<!-- claude-review:ledger '
LEDGER_SUFFIX=' -->'

mode=""
repo=""
pr_number=""
out_file=""
live_counts_out=""
execution_file=""
body_file=""
prior_live=""
posted_out=""
dry_run=0

die() {
  printf 'post-review: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)           [ "$#" -ge 2 ] || die "--mode requires a value";           mode="$2";           shift 2 ;;
    --repo)           [ "$#" -ge 2 ] || die "--repo requires a value";           repo="$2";           shift 2 ;;
    --pr)             [ "$#" -ge 2 ] || die "--pr requires a value";             pr_number="$2";      shift 2 ;;
    --out)            [ "$#" -ge 2 ] || die "--out requires a value";            out_file="$2";       shift 2 ;;
    --live-counts-out) [ "$#" -ge 2 ] || die "--live-counts-out requires a value"; live_counts_out="$2"; shift 2 ;;
    --prior-live)     [ "$#" -ge 2 ] || die "--prior-live requires a value";     prior_live="$2";     shift 2 ;;
    --execution-file) [ "$#" -ge 2 ] || die "--execution-file requires a value"; execution_file="$2"; shift 2 ;;
    --body-file)      [ "$#" -ge 2 ] || die "--body-file requires a value";      body_file="$2";      shift 2 ;;
    --posted-out)     [ "$#" -ge 2 ] || die "--posted-out requires a value";     posted_out="$2";     shift 2 ;;
    --dry-run)        dry_run=1; shift ;;
    -h|--help)        sed -n '2,71p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[ -n "$mode" ]      || die "--mode is required (pre|post)"
[ -n "$repo" ]      || die "--repo is required"
[ -n "$pr_number" ] || die "--pr is required"

command -v gh >/dev/null 2>&1      || die "gh is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# Every exit from here on has already answered "did a comment land?" with
# `false`. Only the code that watched the API call succeed upgrades it, so a
# crash, a `die`, or a path nobody anticipated cannot be read as a yes.
record_posted() { [ -n "$posted_out" ] && printf '%s' "$1" > "$posted_out"; return 0; }
record_posted false

# `gh api --paginate --slurp` returns an array of pages; flatten one level so
# downstream code always sees a flat list of objects.
fetch_json() {
  local endpoint="$1" dest="$2"
  if ! gh api "$endpoint" --paginate --slurp >"${dest}.raw" 2>"${dest}.err"; then
    printf 'post-review: warning: could not fetch %s\n' "$endpoint" >&2
    sed 's/^/post-review:   /' "${dest}.err" >&2 || true
    printf '[]\n' >"$dest"
    return 0
  fi
  python3 - "${dest}.raw" "$dest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

flat = []
if isinstance(data, list):
    for item in data:
        if isinstance(item, list):
            flat.extend(item)
        else:
            flat.append(item)
elif isinstance(data, dict):
    flat.append(data)

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(flat, handle)
PY
}

# Review threads carry the two facts REST does not: whether the author resolved
# the thread, and whether the lines it hangs on still exist in the diff. Without
# them "already posted" is the only thing we can know about a finding, and a
# resolved one would go on being counted forever.
#
# Only the opening comment of each thread is read. It is the finding; the
# replies are the conversation about it.
#
# shellcheck disable=SC2016
# Single-quoted on purpose: $owner, $name, $pr and $after are GraphQL variables
# bound by the flags below and must reach the server unexpanded.
THREADS_QUERY='
query($owner:String!, $name:String!, $pr:Int!, $after:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$pr) {
      reviewThreads(first:100, after:$after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          path
          line
          comments(first:1) {
            nodes { author { login __typename } body }
          }
        }
      }
    }
  }
}'

# Ten pages of a hundred. The busiest pull request this has run against carried
# 28 review comments, so this is a bound and not a live constraint — but an
# unbounded loop against a paginated API is not something to leave to chance.
THREAD_PAGE_LIMIT=10

fetch_threads() {
  local dest="$1" owner name cursor="" page=0 complete=true dir
  owner="${repo%%/*}"
  name="${repo##*/}"
  dir="${dest}.d"
  rm -rf "$dir"
  mkdir -p "$dir"

  while [ "$page" -lt "$THREAD_PAGE_LIMIT" ]; do
    page=$((page + 1))
    local args=(api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number")
    if [ -z "$cursor" ]; then
      # `gh help api`: the literal values true, false, null and integers get
      # converted to their JSON types. A cursor goes through -f instead, so the
      # same conversion can never reinterpret one that happens to read as a
      # number.
      args+=(-F after=null)
    else
      args+=(-f after="$cursor")
    fi
    args+=(-f query="$THREADS_QUERY")

    if ! gh "${args[@]}" >"${dir}/${page}.json" 2>"${dest}.err"; then
      printf 'post-review: warning: could not read review threads, page %d\n' "$page" >&2
      sed 's/^/post-review:   /' "${dest}.err" >&2 || true
      rm -f "${dir}/${page}.json"
      complete=false
      break
    fi

    cursor="$(python3 -c '
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
info = ((((document.get("data") or {}).get("repository") or {})
         .get("pullRequest") or {}).get("reviewThreads") or {}).get("pageInfo") or {}
print((info.get("endCursor") or "") if info.get("hasNextPage") else "")
' "${dir}/${page}.json")"
    [ -n "$cursor" ] || break
  done

  if [ -n "$cursor" ]; then
    printf 'post-review: warning: stopped after %d pages of review threads\n' \
      "$THREAD_PAGE_LIMIT" >&2
    complete=false
  fi

  # One normalised document, so nothing downstream has to know this was paged:
  # {"complete": bool, "nodes": [...]}. `complete` is false when a page failed
  # or the limit was hit, and the summary says so rather than quietly publishing
  # a count taken from part of the pull request.
  python3 - "$dir" "$dest" "$complete" <<'PY'
import glob
import json
import os
import sys

directory, out_path, complete = sys.argv[1:4]

nodes = []
for path in sorted(glob.glob(os.path.join(directory, "*.json")),
                   key=lambda p: int(os.path.basename(p).split(".")[0])):
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        complete = "false"
        continue
    container = ((((document.get("data") or {}).get("repository") or {})
                  .get("pullRequest") or {}).get("reviewThreads") or {})
    nodes.extend(container.get("nodes") or [])

with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump({"complete": complete == "true", "nodes": nodes}, handle)
PY
}

# ---------------------------------------------------------------------------
# pre — hand the already-seen findings to the prompt
# ---------------------------------------------------------------------------
if [ "$mode" = "pre" ]; then
  [ -n "$out_file" ] || die "--out is required in pre mode"

  fetch_json "repos/${repo}/issues/${pr_number}/comments" "${work_dir}/issue.json"
  fetch_threads "${work_dir}/threads.json"

  python3 - "${work_dir}/issue.json" "${work_dir}/threads.json" "$out_file" \
            "$live_counts_out" "$MARKER" "$LEDGER_PREFIX" "$LEDGER_SUFFIX" <<'PY'
import base64
import hashlib
import json
import sys

(issue_path, threads_path, out_path, counts_path,
 marker, led_pre, led_suf) = sys.argv[1:8]

# The logins our reviewer posts under. The GitHub App comments as `claude`; a
# repository running with use_github_app: false gets the same comments from
# `github-actions`. GraphQL spells both WITHOUT the `[bot]` suffix that REST
# appends, so the suffix is stripped rather than matched — a guard written
# against one spelling and fixtured against the other is dead on arrival, and
# this repository has already shipped one of those.
OUR_POSTERS = ("claude", "github-actions")

SEVERITIES = (("🔴", "blocking"), ("🟠", "important"), ("🟡", "nit"))

DECORATION = ("🔴", "🟠", "🟡", "🟣", "**", "Blocking", "Important",
              "Nit", "Pre-existing", "—", "-", ":")


def load(path, empty):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return empty
    return value if isinstance(value, type(empty)) else empty


def posted_by_us(author):
    author = author or {}
    # A human whose login happens to be `claude` is not the reviewer.
    if author.get("__typename") != "Bot":
        return False
    login = (author.get("login") or "").lower()
    if login.endswith("[bot]"):
        login = login[:-len("[bot]")]
    return login in OUR_POSTERS


def first_line(text):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            for token in DECORATION:
                line = line.replace(token, " ")
            return " ".join(line.split())
    return ""


def severity_of(text):
    for line in (text or "").splitlines():
        if not line.strip():
            continue
        # Only the opening line: a body that quotes another severity further
        # down must not change what this finding counts as.
        for emoji, name in SEVERITIES:
            if emoji in line:
                return name
        return None
    return None


def where(path, line):
    if not path:
        return "?"
    return "%s:%s" % (path, line) if line else path


ours_live, ours_resolved, ours_outdated, theirs, vanished = [], [], [], [], []
counts = dict((name, 0) for _, name in SEVERITIES)
seen = set()

# What the block below TELLS THE REVIEWER NOT TO RAISE, written down so the
# number built on top of it can say so.
#
# report.sh publishes one exit criterion — author-confirmed blocking findings
# the other reviewer raised and we did not — and the `theirs` section of this
# very file is an instruction not to raise them. Left unrecorded, that metric
# partly measures our own instruction, and it degrades on its own as the other
# reviewer gets faster at posting.
#
# Measured on the korbyx ledger (231 harvested pull requests, read-only):
#   * 26 pull requests carried at least one finding of theirs BEFORE our first
#     sticky summary — 55 findings, 16 blocking, 9 of those author-confirmed;
#   * on the 120 pull requests where both reviewers spoke, 330 of their findings
#     and 53 of their blocking ones were on the pull request while some re-review
#     of ours was being told not to repeat them. That is the range this record
#     replaces with a fact.
# Three of those are already known by name: korbyx#155 (our only delivered
# review had the finding in this list), #19 and #166.
#
# `key` is the digest harvest-feedback.sh keys a finding by — sha256 of the
# thread's opening comment, first 8 hex — so a consumer can join this record to
# the harvested finding without either side learning a new identifier. `by` is
# kept because a human's thread is suppressed here too, and a human is not the
# other reviewer.
suppressed = []

threads = load(threads_path, {})
complete = bool(threads.get("complete", True))

for thread in threads.get("nodes") or []:
    opener = ((thread.get("comments") or {}).get("nodes") or [None])[0]
    if not opener:
        continue
    title = first_line(opener.get("body"))
    if not title:
        continue
    path, line = thread.get("path"), thread.get("line")
    # Keyed WITHOUT the line, and that is the point. `reviewThreads.line` is the
    # position in the CURRENT diff: GitHub re-anchors it when a later commit
    # shifts the code and drops it to null once the thread is outdated.
    # harvest-feedback.sh reaches the same conclusion from measurement — on
    # korbyx, 4 of 17 live threads already differ from `original_line` — and
    # keys its findings (path, digest of the text) for exactly this reason.
    # Keyed by line, a ledger entry stops matching its own thread the moment the
    # file moves, and gets listed a second time as a finding that has vanished.
    seen.add((path, title))
    entry = "- `%s` — %s" % (where(path, line), title)
    if not posted_by_us(opener.get("author")):
        theirs.append(entry)
        body = opener.get("body") or ""
        suppressed.append({
            "path": path,
            "key": hashlib.sha256(body.encode("utf-8")).hexdigest()[:8],
            # THEIR label, read through our emoji table. CodeRabbit opens with
            # `_🔒 Security & Privacy_ | _🔴 Critical_ | …`, so the 16 blocking
            # ones in the measurement above were found exactly this way. None
            # means they did not label it in a way we can read, not that it is
            # harmless.
            "severity": severity_of(body),
            "by": ((opener.get("author") or {}).get("login") or "").lower(),
        })
    elif thread.get("isResolved"):
        ours_resolved.append(entry)
    elif thread.get("isOutdated"):
        ours_outdated.append(entry)
    else:
        ours_live.append(entry)
        severity = severity_of(opener.get("body"))
        if severity:
            counts[severity] += 1

# Findings a previous run recorded in the sticky comment's ledger that no thread
# above accounts for — deleted, lost to a force-push, or simply unread because
# the GraphQL call failed. Either way there is no way to know whether they still
# stand, so they are listed to stop a repeat and counted by nobody. The heading
# says "not among the current threads" and not "the comment is gone", because on
# a failed read the second would be a lie.
for comment in load(issue_path, []):
    body = comment.get("body") or ""
    if marker not in body or led_pre not in body:
        continue
    chunk = body.split(led_pre, 1)[1].split(led_suf, 1)[0].strip()
    try:
        payload = json.loads(base64.b64decode(chunk).decode("utf-8"))
    except Exception:
        continue
    for item in payload.get("findings", []):
        key = (item.get("path"), item.get("title"))
        if key in seen:
            continue
        seen.add(key)
        vanished.append("- `%s` — %s" % (where(item.get("path"), item.get("line")),
                                         item.get("title") or ""))

SECTIONS = (
    ("Still standing, and posted by you. The counts table already includes "
     "these — do not post them again, and do not count them again either",
     ours_live),
    ("Posted by you, and since resolved. Do not post again; they are settled",
     ours_resolved),
    ("Posted by you, on lines the diff has since changed. Do not repeat as "
     "written — raise it again only if the new code still has the problem",
     ours_outdated),
    # The inline comment stays suppressed — two threads saying the same thing
    # is a real cost to the author, on every pull request, and that is why this
    # instruction exists. What changes is that silence is no longer the only
    # thing we can say. If the reviewer checks one of these itself and thinks it
    # blocking, it says so in the summary, and `post` records that against the
    # finding's key. The form asked for is a line carrying 🔴 and the path,
    # because those two survive translation and the words do not: korbyx runs
    # with `language: français` and this repository has already shipped one
    # guard that matched English prose and could never fire there.
    ("Posted by the other reviewer or by a human. Do not post an inline comment "
     "on any of them — the author has read them, and they are not yours to "
     "count. If you check one against the code yourself and independently judge "
     "it blocking, say so in your summary, on a line carrying 🔴 and the file "
     "path in backticks. Write that line only for a problem you verified in the "
     "code; saying nothing is read as having no opinion", theirs),
    ("Recorded by an earlier run and not among the pull request's current "
     "threads. Do not repeat them", vanished),
)

blocks = []
for heading, items in SECTIONS:
    if items:
        blocks.append("**%s:**\n\n%s" % (heading, "\n".join(sorted(items))))
text = "\n\n".join(blocks)

with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(text + ("\n" if text else ""))

if counts_path:
    payload = dict(counts)
    payload["complete"] = complete
    # Always present, even empty: a consumer must be able to tell "this run
    # suppressed nothing" from "this run predates the record", and an absent key
    # says only the second.
    payload["suppressed"] = suppressed
    with open(counts_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=1, sort_keys=True)
        handle.write("\n")

sys.stderr.write(
    "post-review: %d prior finding(s) loaded; %d still standing and ours "
    "(%d blocking, %d important, %d nit); %d not ours and suppressed "
    "(%d blocking); read %s\n"
    % (len(seen), len(ours_live), counts["blocking"], counts["important"],
       counts["nit"], len(suppressed),
       sum(1 for item in suppressed if item["severity"] == "blocking"),
       "complete" if complete else "INCOMPLETE"))
PY
  exit 0
fi

# ---------------------------------------------------------------------------
# post — upsert the sticky summary
# ---------------------------------------------------------------------------
if [ "$mode" != "post" ]; then
  die "unknown mode: $mode (expected pre or post)"
fi

summary_file="${work_dir}/summary.md"
: >"$summary_file"

if [ -n "$body_file" ] && [ -f "$body_file" ]; then
  cp "$body_file" "$summary_file"
elif [ -n "$execution_file" ] && [ -f "$execution_file" ]; then
  # The execution file is a single pretty-printed JSON array of SDK messages.
  python3 - "$execution_file" "$summary_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        messages = json.load(handle)
except (OSError, ValueError) as exc:
    sys.stderr.write("post-review: could not read execution file: %s\n" % exc)
    messages = []

if not isinstance(messages, list):
    messages = []

texts = []
for message in messages:
    if not isinstance(message, dict) or message.get("type") != "assistant":
        continue
    content = (message.get("message") or {}).get("content") or []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            chunk = (block.get("text") or "").strip()
            if chunk:
                texts.append(chunk)

with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as handle:
    handle.write(texts[-1] if texts else "")
PY
fi

fetch_json "repos/${repo}/issues/${pr_number}/comments" "${work_dir}/issue.json"
fetch_json "repos/${repo}/pulls/${pr_number}/comments" "${work_dir}/review.json"

# Build the final comment body: summary + marker + ledger. Emits the target
# comment id (or "new") on stdout so the shell knows which call to make.
python3 - "$summary_file" "${work_dir}/issue.json" "${work_dir}/review.json" \
          "${work_dir}/body.md" "${work_dir}/plan.json" \
          "$MARKER" "$LEDGER_PREFIX" "$LEDGER_SUFFIX" "$prior_live" <<'PY'
import base64
import hashlib
import json
import os
import re
import sys

(summary_path, issue_path, review_path, body_path, plan_path,
 marker, led_pre, led_suf, prior_live_path) = sys.argv[1:10]


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return []


def first_line(text):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            for token in ("🔴", "🟠", "🟡", "🟣", "**", "Blocking", "Important",
                          "Nit", "Pre-existing", "—", "-", ":"):
                line = line.replace(token, " ")
            return " ".join(line.split())
    return ""


with open(summary_path, encoding="utf-8") as handle:
    summary = handle.read().strip()


# The reviewer counts what IT found on this run — base.md tells it not to repost
# what an earlier run already raised, and it does not tally those either. But
# this comment is edited in place, so the count it carries is the pull request's
# standing verdict, not a log of the last push. Left alone, a 🟡 raised on push
# one is announced by a summary that push two overwrites with `🟡 0`, and the
# finding goes to merge with nothing on the pull request saying it exists
# (Aileaneprod/korbyx#162, #163, #164 — all three on 2026-09-11).
#
# So the still-standing findings measured in `pre` are added back here. `pre`
# runs before the reviewer, so its numbers cannot include anything this run
# posted, and nothing is counted twice.
COUNT_ROW = re.compile(r"^(\s*\|[^|]*\|\s*)(\d+)(\s*\|.*)$")
PRIOR_SEVERITIES = (("🔴", "blocking"), ("🟠", "important"), ("🟡", "nit"))

prior_live = {}
if prior_live_path and os.path.isfile(prior_live_path):
    try:
        with open(prior_live_path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            prior_live = loaded
    except (OSError, ValueError) as exc:
        sys.stderr.write("post-review: could not read the standing counts: %s\n" % exc)


prior_complete = bool(prior_live.get("complete", True))


def carried(key):
    try:
        return max(0, int(prior_live.get(key) or 0))
    except (TypeError, ValueError):
        return 0


# Said on the page, not in a log. A count taken from part of the pull request
# is not a standing verdict, and publishing one as if it were is the same defect
# this whole change exists to remove — only quieter, because it would happen on
# the days the API had a bad minute. Not posting at all was the alternative, and
# it is worse: a completed review would be announced as unavailable.
INCOMPLETE_NOTE = ("_The findings already on this pull request could not all be "
                   "read this time, so the counts above may be low._")


def with_standing(text):
    """Add the still-standing earlier findings to the counts table of `text`.

    Applied once, at the very end, to whichever text becomes the summary. The
    recovered text and the adopted fallback are two different strings arriving
    at two different points, and adjusting only the first leaves a crashed run —
    the case the fallback exists for — publishing the wrong verdict.
    """
    if not text or (prior_complete
                    and not any(carried(key) for _, key in PRIOR_SEVERITIES)):
        return text
    rewritten = []
    added = dict((key, 0) for _, key in PRIOR_SEVERITIES)
    last_row = -1
    for line in text.splitlines():
        for emoji, key in PRIOR_SEVERITIES:
            if emoji not in line:
                continue
            match = COUNT_ROW.match(line)
            if match:
                last_row = len(rewritten)
                extra = carried(key)
                if extra:
                    line = "%s%d%s" % (match.group(1),
                                       int(match.group(2)) + extra, match.group(3))
                    added[key] += extra
            break
        rewritten.append(line)
    if not prior_complete and last_row >= 0:
        rewritten[last_row + 1:last_row + 1] = ["", INCOMPLETE_NOTE]
    sys.stderr.write(
        "post-review: carried %d blocking, %d important, %d nit still standing "
        "from earlier runs into the counts table%s\n"
        % (added["blocking"], added["important"], added["nit"],
           "" if prior_complete else "; the read was incomplete and the summary says so"))
    return "\n".join(rewritten)

issue_comments = load(issue_path)
review_comments = load(review_path)

existing = [c for c in issue_comments if marker in (c.get("body") or "")]
existing.sort(key=lambda c: c.get("id") or 0)

# Does this text look like the review summary, or like the reviewer talking?
#
# base.md mandates a counts table carrying all three severity emoji, "even when
# all counts are zero", and tells the reviewer to use those exact emoji
# everywhere. The emoji are therefore the one part of the format that survives
# translation — which matters, because Aileaneprod/korbyx runs with
# `language: français` and its table reads `| Severite | Nombre |`. The old test
# looked for the literal English `| Severity | Count |`, so on the repository
# this tool was built for it could never match; the ledger holds no file
# containing that string, while the emoji appear throughout.
#
# The check earns its place upstream too. The summary is whatever assistant text
# came last, and the sticky comment is a PATCH: it REPLACES the previous body.
# A run that ends on "Let me check the auth module next" would overwrite a good
# summary from the previous push with that sentence, and nothing in the comment
# would tell the reader it is not this push's review. Refusing to post leaves
# the old summary standing and lets the "unavailable" notice speak instead,
# which is the honest pair.
SEVERITY_EMOJI = ("🔴", "🟠", "🟡")


def looks_like_summary(text):
    # In the TABLE, not merely somewhere in the text. "J'ai releve des points
    # 🔴, 🟠 et 🟡 ; je continue" carries all three and is exactly the
    # kind of sentence a run ends on mid-thought. Requiring each one inside a
    # markdown row keeps the check structural, and structure survives
    # translation where a header string does not.
    rows = [line.strip() for line in (text or "").splitlines()
            if line.strip().startswith("|")]
    return all(any(emoji in row for row in rows) for emoji in SEVERITY_EMOJI)


if summary and not looks_like_summary(summary):
    sys.stderr.write(
        "post-review: the recovered text carries no counts table, so it is not"
        " the summary; leaving any existing one in place\n")
    summary = ""

adopted = None
if not summary:
    # Fallback: the reviewer posted its own summary despite being told not to.
    # Recognise it by the counts table and adopt that comment in place.
    for comment in reversed(issue_comments):
        body = comment.get("body") or ""
        if marker in body:
            continue
        if looks_like_summary(body):
            summary = body.strip()
            adopted = comment.get("id")
            break

if not summary:
    sys.stderr.write("post-review: no summary found; nothing to post\n")
    with open(plan_path, "w", encoding="utf-8") as handle:
        json.dump({"action": "none"}, handle)
    sys.exit(0)

# Strip any marker/ledger the adopted body already carried, so we never nest.
if marker in summary:
    summary = summary.replace(marker, "").strip()
if led_pre in summary:
    head, _, rest = summary.partition(led_pre)
    _, _, tail = rest.partition(led_suf)
    summary = (head + tail).strip()

# Last, so it reaches the recovered text and the adopted fallback alike.
summary = with_standing(summary)

# Which files WE have an inline finding on. It changes nothing about the ledger
# below; it is read once, to refuse an ambiguous concurrence.
#
# REST spells the account with the `[bot]` suffix GraphQL omits (`claude[bot]`
# against `claude`), and `type` is the property a human account cannot hold —
# `gh api users/claude` returns a real human created 2009-05-07. Measured on
# korbyx#92 and #139, and restated here because this heredoc is a separate
# program from the one in `pre`.
OUR_POSTERS = ("claude", "github-actions")


def posted_by_us(user):
    user = user or {}
    if user.get("type") != "Bot":
        return False
    login = (user.get("login") or "").lower()
    if login.endswith("[bot]"):
        login = login[:-len("[bot]")]
    return login in OUR_POSTERS


findings = []
seen = set()
our_paths = set()
for comment in review_comments:
    # A reply is the conversation about a finding, not a finding. REST returns
    # every review comment flat, and on a busy pull request the replies are the
    # majority — 18 of the 28 on Aileaneprod/korbyx#164. Recording them as
    # findings made the ledger mostly noise, and `pre` now reports anything in
    # the ledger with no thread behind it as a finding whose comment has gone,
    # which for a reply is simply untrue.
    if comment.get("in_reply_to_id") is not None:
        continue
    path = comment.get("path")
    line = comment.get("line") or comment.get("original_line")
    title = first_line(comment.get("body"))
    if not path or not title:
        continue
    if posted_by_us(comment.get("user")):
        our_paths.add(path)
    digest = hashlib.sha256(
        ("%s|%s|%s" % (path, line, title)).encode("utf-8")
    ).hexdigest()
    if digest in seen:
        continue
    seen.add(digest)
    findings.append({"path": path, "line": line, "title": title, "hash": digest})

# --- what we told this run's reviewer not to file ---------------------------
#
# `pre` measured it (see the comment on `suppressed` there) and handed it over in
# the counts file. It is written into the sticky comment because that is the one
# artefact of ours that survives on the pull request, and harvest-feedback.sh
# already reads this comment's body to answer "were we here at all" — so the
# record reaches the ledger without a new API call or a new contract.
#
# Nothing downstream consumes it yet. That is deliberate: report.sh is the page
# that must change, and the number it publishes cannot be split into a bucket
# that does not exist in the data first.

# One sticky comment holds every run's record, so the list is unioned rather
# than replaced. Two runs differ: a later one can read fewer threads (the read
# is allowed to come back incomplete) or none at all when the `pre` step, which
# is continue-on-error, failed — and on korbyx#155 the ONLY delivered review of
# the commit that mattered is the one whose list holds the finding. A snapshot
# would drop exactly that evidence on the next push.
#
# The cost is that a thread deleted since stays recorded. The claim made is "at
# some run, the reviewer was told not to file this", which stays true.
SUPPRESSED_LIMIT = 100


def clean_suppressed(entries):
    """Keep the well-formed entries of a suppression list, whatever wrote it."""
    out = []
    for item in entries if isinstance(entries, list) else []:
        if not isinstance(item, dict) or not item.get("path") or not item.get("key"):
            continue
        out.append({"path": item["path"], "key": item["key"],
                    "severity": item.get("severity"), "by": item.get("by"),
                    "concurred": bool(item.get("concurred"))})
    return out


def ledger_of(body):
    if led_pre not in (body or ""):
        return {}
    chunk = body.split(led_pre, 1)[1].split(led_suf, 1)[0].strip()
    try:
        return json.loads(base64.b64decode(chunk).decode("utf-8"))
    except Exception:
        return {}


# Did the reviewer say, in its own summary, that one of the suppressed findings
# is blocking? That sentence is the only signal that separates "we would have
# caught it" from "we were told not to raise it", and the instruction in `pre`
# asks for it in the one form that survives `language: français`: a line
# carrying 🔴 and the path.
#
# What this CANNOT do, and the record must not be read as doing:
#   * it cannot tell an independent judgement from agreement with a finding the
#     prompt has just shown the reviewer. Nothing observable can.
#   * absence of the line is not "we would have missed it". It is no opinion,
#     and a consumer that counts it either way is inventing data.
# So the match is deliberately strict and errs toward recording nothing: the
# full path, on a line that also carries 🔴, and never on a file where we filed
# an inline finding of our own — there the line is at least as likely to be
# about ours, and a concurrence credited to us by accident flatters exactly the
# number this record exists to keep honest.
def concurring_paths(text, entries):
    hits = set()
    for line in (text or "").splitlines():
        if "🔴" not in line:
            continue
        for item in entries:
            if item["path"] not in our_paths and item["path"] in line:
                hits.add(item["path"])
    return hits


suppressed = clean_suppressed(prior_live.get("suppressed"))
known = dict(((item["path"], item["key"]), item) for item in suppressed)
for item in clean_suppressed(ledger_of(existing[0].get("body") if existing else "")
                             .get("suppressed")):
    slot = known.get((item["path"], item["key"]))
    if slot is None:
        if len(suppressed) >= SUPPRESSED_LIMIT:
            continue
        known[(item["path"], item["key"])] = item
        suppressed.append(item)
    else:
        # Once stated, a concurrence is not withdrawn by a later run that stayed
        # silent about it; silence is not a retraction, it is no opinion.
        slot["concurred"] = slot["concurred"] or item["concurred"]
        if slot["severity"] is None:
            slot["severity"] = item["severity"]

agreed = concurring_paths(summary, suppressed)
for item in suppressed:
    if item["path"] in agreed:
        item["concurred"] = True

if suppressed:
    sys.stderr.write(
        "post-review: %d finding(s) of theirs were suppressed for this pull "
        "request, %d of them blocking; the summary independently calls %d "
        "blocking\n"
        % (len(suppressed),
           sum(1 for item in suppressed if item["severity"] == "blocking"),
           sum(1 for item in suppressed if item["concurred"])))

# Version 2 adds `suppressed`. `pre` reads `findings` only and does not look at
# the version, so an old sticky and a new one are both readable; the number is
# there for whatever reads this next, which must be able to tell an empty list
# from a ledger written before anyone was recording.
ledger = base64.b64encode(
    json.dumps({"version": 2, "findings": findings, "suppressed": suppressed},
               sort_keys=True).encode("utf-8")
).decode("ascii")

body = "%s\n%s\n\n%s%s%s\n" % (marker, summary, led_pre, ledger, led_suf)

with open(body_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(body)

if existing:
    target = existing[0]["id"]
    superseded = [c["id"] for c in existing[1:]]
elif adopted is not None:
    target = adopted
    superseded = []
else:
    target = None
    superseded = []

with open(plan_path, "w", encoding="utf-8") as handle:
    json.dump({
        "action": "patch" if target is not None else "create",
        "id": target,
        "superseded": superseded,
        "findings": len(findings),
    }, handle)

sys.stderr.write(
    "post-review: %s sticky comment, %d finding(s) in ledger\n"
    % ("updating" if target is not None else "creating", len(findings))
)
PY

action="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["action"])' "${work_dir}/plan.json")"

if [ "$action" = "none" ]; then
  exit 0
fi

# Build the API payload as JSON so the body survives quoting, newlines, and
# backticks untouched.
python3 - "${work_dir}/body.md" "${work_dir}/payload.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = handle.read()

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"body": body}, handle)
PY

if [ "$dry_run" -eq 1 ]; then
  printf 'post-review: dry run — would %s the sticky comment:\n' "$action" >&2
  cat "${work_dir}/body.md"
  exit 0
fi

if [ "$action" = "patch" ]; then
  comment_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${work_dir}/plan.json")"
  gh api "repos/${repo}/issues/comments/${comment_id}" \
    --method PATCH --input "${work_dir}/payload.json" >/dev/null
  record_posted true
  printf 'post-review: updated sticky comment %s\n' "$comment_id" >&2
else
  gh api "repos/${repo}/issues/${pr_number}/comments" \
    --method POST --input "${work_dir}/payload.json" >/dev/null
  record_posted true
  printf 'post-review: created sticky comment\n' >&2
fi

# Collapse any stray duplicate summaries rather than deleting them — this only
# rewrites comments this tool authored, and never removes anything.
superseded="$(python3 -c '
import json, sys
plan = json.load(open(sys.argv[1]))
print(" ".join(str(i) for i in plan.get("superseded", [])))
' "${work_dir}/plan.json")"

if [ -n "$superseded" ]; then
  printf '{"body":"%s\\n_Superseded — see the current review summary on this PR._"}\n' \
    "$MARKER" >"${work_dir}/superseded.json"
  for stale_id in $superseded; do
    gh api "repos/${repo}/issues/comments/${stale_id}" \
      --method PATCH --input "${work_dir}/superseded.json" >/dev/null || true
    printf 'post-review: collapsed duplicate summary %s\n' "$stale_id" >&2
  done
fi
