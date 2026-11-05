#!/usr/bin/env bash
#
# review-cost.sh — what the reviewers cost over a window, from the records that
# say so.
#
# Usage:
#   review-cost.sh --repo OWNER/REPO --since YYYY-MM-DD [--until YYYY-MM-DD]
#                  [--workflow FILE] [--org ORG] [--no-copilot]
#
#   --repo         The reviewed repository.
#   --since        First day of the window, inclusive (UTC).
#   --until        Last day of the window, inclusive (UTC). Default: today.
#   --workflow     The wrapper's file name in that repository.
#                  Default ai-review.yml
#   --org          Organization whose Copilot usage is read. Default: the
#                  repository's owner.
#   --no-copilot   Skip the Copilot side (it needs an organization admin).
#
# WHY THIS EXISTS. A comparison trial ends on "which reviewer is worth what it
# costs", and neither cost was recorded anywhere the comparison page reads. The
# ledger keeps findings and verdicts, not money.
#
# OURS comes from the run's own execution record. review.yml uploads it as the
# artifact `claude-review-execution-<sha>-<attempt>`, and its `result` entry
# carries `total_cost_usd`. That figure is what the same tokens would cost on
# the API. On a subscription the money actually paid is the subscription, so the
# page says "API-equivalent" and never "spent". Artifacts expire (90 days by
# default); an expired one is counted and named, never read as zero.
#
# THEIRS comes from GitHub's billing API, AI credit usage per day
# (GET /organizations/{org}/settings/billing/ai_credit/usage). Two limits, both
# printed on the page rather than left to the reader:
#   * it needs an organization admin. A refused read is reported as unreadable,
#     not as a cost of zero;
#   * it counts every Copilot use the organization pays for, not only reviews.
#     The figure is a ceiling on what the reviewer cost, not its cost.
# Seat prices and Actions minutes are not in it either.
#
# EXIT STATUS. 0 when every read succeeded. 1 when any read failed: a total
# built over a read that failed is incomplete, and the page says which.
#
# Requires: gh (authenticated), python3.

set -euo pipefail

repo=""
since=""
until_day=""
workflow="ai-review.yml"
org=""
copilot=1

die() { printf 'review-cost: %s\n' "$1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)       [ "$#" -ge 2 ] || die "--repo requires a value";     repo="$2";      shift 2 ;;
    --since)      [ "$#" -ge 2 ] || die "--since requires a value";    since="$2";     shift 2 ;;
    --until)      [ "$#" -ge 2 ] || die "--until requires a value";    until_day="$2"; shift 2 ;;
    --workflow)   [ "$#" -ge 2 ] || die "--workflow requires a value"; workflow="$2";  shift 2 ;;
    --org)        [ "$#" -ge 2 ] || die "--org requires a value";      org="$2";       shift 2 ;;
    --no-copilot) copilot=0; shift ;;
    -h|--help)    awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$repo" ] || die "--repo is required"
case "$repo" in
  */*) ;;
  *) die "--repo must be OWNER/REPO, got: $repo" ;;
esac
[ -n "$since" ] || die "--since is required"
[ -n "$org" ] || org="${repo%%/*}"

# Dates are checked, and the day list built, by python: a shape test alone
# would let 2026-02-31 through and produce a window nobody asked for.
days="$(python3 - "$since" "$until_day" <<'PY'
import datetime, sys
since, until = sys.argv[1], sys.argv[2]
try:
    start = datetime.date.fromisoformat(since)
    end = datetime.date.fromisoformat(until) if until else datetime.datetime.now(datetime.timezone.utc).date()
except ValueError as exc:
    sys.stderr.write("review-cost: not a date: %s\n" % exc)
    raise SystemExit(2)
if end < start:
    sys.stderr.write("review-cost: --until is before --since\n")
    raise SystemExit(2)
day = start
while day <= end:
    print(day.isoformat())
    day += datetime.timedelta(days=1)
PY
)" || exit 2
# python on Windows ends its lines with \r\n, and a stray \r turns "01" into a
# number bash cannot read in the day arithmetic below.
days="$(printf '%s\n' "$days" | tr -d '\r')"
first_day="$(printf '%s\n' "$days" | head -n 1)"
last_day="$(printf '%s\n' "$days" | tail -n 1)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/zips" "$work/copilot"
: > "$work/failed"
: > "$work/expired"
: > "$work/no-record"

# --- ours: one execution record per reviewed run ------------------------------

if ! gh api --paginate \
    "repos/${repo}/actions/workflows/${workflow}/runs?created=${first_day}..${last_day}&per_page=100" \
    --jq '.workflow_runs[].id' > "$work/runs" 2>/dev/null; then
  printf 'runs of %s in %s\n' "$workflow" "$repo" >> "$work/failed"
fi

while IFS= read -r run_id; do
  [ -n "$run_id" ] || continue
  if ! gh api "repos/${repo}/actions/runs/${run_id}/artifacts" \
      --jq '.artifacts[] | select(.name | startswith("claude-review-execution-")) | "\(.id) \(.expired)"' \
      > "$work/art-$run_id" 2>/dev/null < /dev/null; then
    printf 'artifacts of run %s\n' "$run_id" >> "$work/failed"
    continue
  fi
  # A run with no execution record reviewed nothing: a draft, a skip, a
  # guard that stopped it. Counted, so the number of reviews is not inflated.
  [ -s "$work/art-$run_id" ] || { printf '%s\n' "$run_id" >> "$work/no-record"; continue; }
  while read -r art_id expired; do
    if [ "$expired" = "true" ]; then
      printf '%s\n' "$run_id" >> "$work/expired"
      continue
    fi
    if ! gh api "repos/${repo}/actions/artifacts/${art_id}/zip" > "$work/zips/${run_id}-${art_id}.zip" 2>/dev/null < /dev/null; then
      printf 'artifact %s of run %s\n' "$art_id" "$run_id" >> "$work/failed"
      rm -f "$work/zips/${run_id}-${art_id}.zip"
    fi
  done < "$work/art-$run_id"
done < "$work/runs"

# --- theirs: Copilot AI credits, one read per day ------------------------------

copilot_state="skipped"
if [ "$copilot" -eq 1 ]; then
  copilot_state="read"
  while IFS= read -r day; do
    y="${day%%-*}"; rest="${day#*-}"; m="${rest%%-*}"; d="${rest#*-}"
    m="${m#0}"; d="${d#0}"
    if ! gh api "organizations/${org}/settings/billing/ai_credit/usage?year=${y}&month=${m}&day=${d}" \
        > "$work/copilot/$day.json" 2>/dev/null < /dev/null; then
      rm -f "$work/copilot/$day.json"
      printf 'Copilot usage of %s on %s\n' "$org" "$day" >> "$work/failed"
      copilot_state="unreadable"
    fi
  done <<EOF
$days
EOF
fi

WORK="$work" REPO="$repo" ORG="$org" WORKFLOW="$workflow" FIRST="$first_day" LAST="$last_day" \
COPILOT_STATE="$copilot_state" python3 <<'PY'
import glob
import io
import json
import os
import zipfile

work = os.environ["WORK"]


def lines(name):
    with open(os.path.join(work, name), encoding="utf-8") as fh:
        return [ln.strip() for ln in fh if ln.strip()]


reviews, unreadable_records = [], []
for path in sorted(glob.glob(os.path.join(work, "zips", "*.zip"))):
    run_id = os.path.basename(path).split("-")[0]
    cost = None
    try:
        with zipfile.ZipFile(path) as zf:
            for name in zf.namelist():
                if not name.endswith(".json"):
                    continue
                data = json.load(io.TextIOWrapper(zf.open(name), encoding="utf-8"))
                for entry in data if isinstance(data, list) else []:
                    if isinstance(entry, dict) and entry.get("type") == "result":
                        value = entry.get("total_cost_usd")
                        if isinstance(value, (int, float)):
                            cost = (cost or 0.0) + value
    except (zipfile.BadZipFile, ValueError, OSError):
        cost = None
    if cost is None:
        unreadable_records.append(run_id)
    else:
        reviews.append(cost)

failed, expired, no_record = lines("failed"), lines("expired"), lines("no-record")

w = print
w("# What the reviewers cost, %s to %s" % (os.environ["FIRST"], os.environ["LAST"]))
w("")
w("Repository `%s`, workflow `%s`. Days are UTC, both ends included." % (os.environ["REPO"], os.environ["WORKFLOW"]))
w("")
w("## Ours: claude-review")
w("")
w("| | |")
w("|---|---|")
w("| reviews with a readable execution record | %d |" % len(reviews))
w("| API-equivalent cost, total | $%.2f |" % sum(reviews))
w("| API-equivalent cost, per review | %s |"
  % ("$%.2f" % (sum(reviews) / len(reviews)) if reviews else "no data"))
w("| runs with no execution record (nothing reviewed) | %d |" % len(no_record))
w("| records expired before this read | %d |" % len(expired))
w("| records present but unreadable | %d |" % len(unreadable_records))
w("")
w("API-equivalent is what these tokens would cost on the API (`total_cost_usd`). On a")
w("subscription, the money actually paid is the subscription, whatever this says.")
if expired:
    w("")
    w("**%d record(s) had expired, so the total above is short by their cost.** Runs: %s."
      % (len(expired), ", ".join(expired[:20]) + (" …" if len(expired) > 20 else "")))
w("")

state = os.environ["COPILOT_STATE"]
w("## Theirs: GitHub Copilot")
w("")
if state == "skipped":
    w("Not read (`--no-copilot`).")
elif state == "unreadable":
    w("**Unreadable.** At least one day of AI credit usage could not be read for `%s`; the"
      " endpoint needs an organization admin. No total is printed, because a partial one"
      " would read as the cost." % os.environ["ORG"])
else:
    # Gross AND net. The credits a seat includes are applied as a discount, so
    # on 2026-11-05 the code review used 699 credits ($6.99 at list price) and
    # was billed $0.00. Printing the net alone would say the reviewer is free.
    by_model, total = {}, [0.0, 0.0, 0.0]
    for path in sorted(glob.glob(os.path.join(work, "copilot", "*.json"))):
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        for item in doc.get("usageItems") or []:
            if "copilot" not in str(item.get("product") or "").lower():
                continue
            row = (float(item.get("grossQuantity") or 0), float(item.get("grossAmount") or 0),
                   float(item.get("netAmount") or 0))
            got = by_model.setdefault(item.get("model") or "(no model)", [0.0, 0.0, 0.0])
            for i, value in enumerate(row):
                got[i] += value
                total[i] += value
    w("| model | AI credits used | at list price | billed, after included credits |")
    w("|---|---|---|---|")
    for model in sorted(by_model):
        g = by_model[model]
        w("| %s | %.0f | $%.2f | $%.2f |" % (model, g[0], g[1], g[2]))
    w("| **total** | **%.0f** | **$%.2f** | **$%.2f** |" % tuple(total))
    w("")
    w("This is every Copilot use the organization was billed for over these days, not only")
    w("its reviews: a ceiling on what the reviewer cost. `billed` is after the credits the")
    w("seats include; the seats themselves and Actions minutes are not in it.")
w("")

if failed:
    w("## Reads that failed")
    w("")
    w("The totals above leave these out:")
    w("")
    for item in failed:
        w("- %s" % item)
    raise SystemExit(1)
PY
