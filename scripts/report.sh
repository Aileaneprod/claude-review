#!/usr/bin/env bash
#
# report.sh — the one page that answers "can we switch the other reviewer off?"
#
# Usage:
#   report.sh --ledger DIR [--ours claude] [--theirs coderabbitai]
#             [--since PR] [--since-note TEXT] [--out FILE]
#
#   --ledger DIR   Harvested ledger (harvest-feedback.sh --out).
#   --ours NAME    Reviewer prefix that is ours. Default: claude.
#   --theirs NAME  The reviewer being compared. Default: coderabbitai.
#   --since PR     Only pull requests at or above this number. Use the freeze
#                  point: a prompt change mid-window invalidates the window.
#                  A non-numeric or empty value is an ERROR, not a no-op: this
#                  number is meant to come out of a file, and every way that
#                  extraction can fail yields an empty string. Ignoring it would
#                  restore the full window while the page still looked frozen,
#                  differing by four words and exiting 0.
#   --since-note T One line printed under the window, saying why it was reset
#                  and where the old page went. The report is written with mode
#                  "w", so a note added by hand dies at the next scheduled run;
#                  it has to come through here or the page will read
#                  "_None in this window._" as "we no longer miss anything".
#   --out FILE     Write the report here. Default: stdout.
#
# The exit criterion this serves, decided before any of it was measured:
#
#   On a large enough window of pull requests reviewed by both, ZERO
#   author-confirmed blocking findings that they raised and we did not, and our
#   precision >= 0.95 on findings the author actually judged.
#
#   "Large enough" is a real threshold, not a hedge: the report's own table
#   prints it in the target column and says whether it has been reached, so the
#   number lives in exactly one place and this text cannot drift from it.
#
# Two honesties the numbers depend on:
#
#   * Only `accepted`, `partial` and `rejected` are judged. `no_reply` and
#     `acknowledged` are reported separately and excluded from precision — a
#     finding nobody ruled on is not one anybody accepted, and counting it
#     either way flatters whoever has more unanswered findings.
#   * A "miss" here means: they found it, the author confirmed it, and we
#     posted nothing on that pull request. That is the cheap approximation.
#     It over-counts when our review ran on an earlier commit than the one
#     carrying the defect, so treat the list as candidates to read, not a
#     verdict. Narrowing it needs the reviewed SHA per run, which the workflow
#     records but this report does not yet read.
#
# Requires: python3.

set -euo pipefail

ledger_dir=""
ours="claude"
theirs="coderabbitai"
since=""
since_given=0
since_note=""
out_file=""

die() { printf 'report: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger) [ "$#" -ge 2 ] || die "--ledger requires a value"; ledger_dir="$2"; shift 2 ;;
    --ours)   [ "$#" -ge 2 ] || die "--ours requires a value";   ours="$2";       shift 2 ;;
    --theirs) [ "$#" -ge 2 ] || die "--theirs requires a value"; theirs="$2";     shift 2 ;;
    --since)  [ "$#" -ge 2 ] || die "--since requires a value";  since="$2"; since_given=1; shift 2 ;;
    --since-note) [ "$#" -ge 2 ] || die "--since-note requires a value"; since_note="$2"; shift 2 ;;
    --out)    [ "$#" -ge 2 ] || die "--out requires a value";    out_file="$2";   shift 2 ;;
    -h|--help) sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$ledger_dir" ] || die "--ledger is required"
[ -d "$ledger_dir" ] || die "no ledger at $ledger_dir"

# Fail closed. An empty or non-numeric freeze point used to be accepted and then
# silently ignored, which is the one behaviour a freeze point must never have.
if [ "$since_given" -eq 1 ]; then
  case "$since" in
    ''|*[!0-9]*|0|0*)
      printf 'report: --since needs a positive pull request number, got "%s".\n' "$since" >&2
      printf 'report:   pull requests are numbered from 1, so 0 and leading zeros are refused too.\n' >&2
      printf 'report: an empty or non-numeric value is refused rather than ignored, because\n' >&2
      printf 'report:   ignoring it restores the full window on a page that still looks frozen.\n' >&2
      exit 2 ;;
  esac
fi

LEDGER_DIR="$ledger_dir" OURS="$ours" THEIRS="$theirs" SINCE="$since" SINCE_NOTE="$since_note" OUT_FILE="$out_file" \
python3 <<'PY'
import decimal
import json
import os
import re
import sys

ledger_dir = os.environ["LEDGER_DIR"]
ours_name = os.environ["OURS"]
theirs_name = os.environ["THEIRS"]
since = os.environ.get("SINCE") or ""
since_note = os.environ.get("SINCE_NOTE") or ""

# Below this many pull requests reviewed by both, the two substantive
# criteria cannot be said to have PASSED — there is not enough of a window
# for the question to have been asked. Stated once; the table interpolates
# it rather than repeating it.
MIN_BOTH = 15


def pct(value):
    """Two places, truncated DOWN — never rounded up toward the target.

    A real run printed `| >= 0.95 | 0.95 | FAIL |`. The value was 0.945946, and
    rounding made the cell read as meeting the criterion it had just failed.
    Truncating means the printed number never claims more than was measured:
    0.94 explains its own FAIL, and a genuine 0.951 still prints 0.95.

    Through Decimal, and not `int(value * 100)`, because that truncates the
    FLOAT rather than the value: 0.29 * 100 is 28.999999999999996, so the cell
    built to stop overstating began understating by a hundredth. 29/100, 57/100
    and 58/100 all did it. `str()` gives the shortest decimal that round-trips,
    which is the number the arithmetic meant.
    """
    if value is None:
        return "n/a"
    quantised = decimal.Decimal(str(value)).quantize(
        decimal.Decimal("0.01"), rounding=decimal.ROUND_DOWN)
    return "%.2f" % quantised
out_file = os.environ.get("OUT_FILE") or ""

JUDGED = ("accepted", "partial", "rejected")


def severity(text):
    head = (text or "")[:400]
    for emoji, label in (("🔴", "blocking"), ("🟠", "important"),
                         ("🟡", "nit"), ("🟣", "preexisting")):
        if emoji in head:
            return label
    return "unlabelled"


def verdict_of(finding):
    # A human's own correction outranks the model, which outranks keywords.
    for key in ("verdict_human", "verdict_llm", "verdict_keyword", "verdict_guess"):
        value = finding.get(key)
        if value:
            return value
    return "unknown"


def side(finding):
    reviewer = (finding.get("reviewer") or "").lower()
    if reviewer.startswith(ours_name):
        return "ours"
    if reviewer.startswith(theirs_name):
        return "theirs"
    return None


prs = {}
repos_seen = set()
for root, _dirs, files in os.walk(ledger_dir):
    for name in sorted(files):
        if not name.endswith(".json") or name == "gold.json":
            continue
        try:
            with open(os.path.join(root, name), encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            continue
        if "findings" not in doc:
            continue
        number = doc.get("pr")
        repos_seen.add(doc.get("repo"))
        if since and isinstance(number, int) and number < int(since):
            continue
        prs[(doc.get("repo"), number)] = doc

rows, totals = [], {}
for key in ("ours", "theirs"):
    totals[key] = {v: 0 for v in ("accepted", "partial", "rejected",
                                  "acknowledged", "no_reply", "unknown")}
    totals[key]["blocking_accepted"] = 0

missed = []
both_reviewed = 0

for (repo, number), doc in sorted(prs.items(), key=lambda kv: (kv[0][0] or "", kv[0][1] or 0)):
    counts = {"ours": {}, "theirs": {}}

    # Presence, not productivity. `reviewed_by_ours` is written by
    # harvest-feedback.sh from the sticky summary our reviewer posts on every
    # completed run, so a review that read the diff and had nothing to file is
    # no longer indistinguishable from one that never ran.
    #
    # That distinction is what the miss heuristic below turns on, and getting it
    # wrong punished the reviewer for the behaviour its own prompt calls "a
    # valid, frequent, and good outcome". On Aileaneprod/korbyx#92 our reviewer
    # ran three times and posted a reasoned 0/0/0 summary; the ledger held zero
    # findings from us, so any blocking finding of theirs there counted as ours
    # to answer for.
    #
    # `or` and not `=`: a document harvested before the field existed has no
    # opinion, and falls back to the old inference rather than asserting we were
    # absent. Re-harvesting upgrades it; nothing regresses in the meantime.
    present = {"ours": bool(doc.get("reviewed_by_ours")), "theirs": False}
    pr_missed = []
    for finding in doc["findings"]:
        which = side(finding)
        if which is None:
            continue
        present[which] = True
        verdict = verdict_of(finding)
        counts[which][verdict] = counts[which].get(verdict, 0) + 1
        if verdict in totals[which]:
            totals[which][verdict] += 1
        if severity(finding.get("finding")) == "blocking" and verdict in ("accepted", "partial"):
            totals[which]["blocking_accepted"] += 1
            if which == "theirs":
                pr_missed.append(finding)

    if present["ours"] and present["theirs"]:
        both_reviewed += 1
    # Only count a blocking finding of theirs as missed when we said nothing at
    # all on that pull request.
    if pr_missed and not present["ours"]:
        for finding in pr_missed:
            missed.append((repo, number, finding.get("path"), finding.get("line"),
                           (finding.get("finding") or "")[:0]))

    rows.append((repo, number, doc.get("title") or "", counts, present))


def precision(bucket):
    judged = sum(bucket[v] for v in JUDGED)
    if not judged:
        return None, 0
    return (bucket["accepted"] + 0.5 * bucket["partial"]) / judged, judged


out = []
w = out.append

ours_p, ours_judged = precision(totals["ours"])
theirs_p, theirs_judged = precision(totals["theirs"])

# A bare pull request number is repo-blind, and the filter above compares only
# `doc["pr"]` even though the line under it keys the result by (repo, number).
# With two repositories in the ledger a freeze point of 114 admits an old review
# numbered 400 in one of them and drops a pull request opened today numbered 3
# in the other — wrong in both directions, and silent in both.
#
# Refused rather than fixed: making the window repo-aware means deciding what a
# freeze point even means when two repositories are measured together, and that
# is a question about the measurement, not about this filter. One repository is
# the only case where a bare number carries a meaning, so it is the only case
# allowed.
if since and len(repos_seen) > 1:
    sys.stderr.write(
        "report: --since is a bare pull request number and this ledger holds "
        "more than one repository (%s).\n"
        % ", ".join(sorted(str(r) for r in repos_seen)))
    sys.stderr.write(
        "report:   the filter compares numbers only, so it would admit old pull "
        "requests from one\n"
        "report:   repository and drop new ones from another. Narrow --ledger to "
        "a single repository.\n")
    raise SystemExit(2)

w("# Can we switch %s off?" % theirs_name)
w("")
w("Window: %d pull request(s)%s, %d reviewed by both."
  % (len(prs), " from #%s" % since if since else "", both_reviewed))
if since_note:
    w("")
    w("> %s" % since_note)
w("")
# PASS is a claim that a criterion was MET. It requires a window big enough to
# have tested it; "not yet" is what an unasked question deserves.
#
# FAIL is deliberately NOT gated the same way, and the asymmetry is the point: a
# blocking finding we missed is a positive observation and counts from the first
# one, while zero of them over three pull requests is the absence of evidence,
# not evidence of absence. Freezing the window to start a clean measurement made
# this urgent — on an empty window the old table printed
#
#     | Blocking findings only they caught | 0 | 0 | PASS |
#
# which is the criterion that decides, reading green because nothing had been
# measured at all. This file's own header says a column that is quietly wrong is
# worse than no column, because it will be believed.
enough = both_reviewed >= MIN_BOTH


def verdict(failed, ok):
    if failed:
        # A FAIL earned on three pull requests and one earned on thirty read
        # identically in a table, and only one of them is a measurement. FAIL
        # is deliberately not gated by window size — a miss we saw is a miss —
        # but it must not borrow the authority of a window it did not have.
        return "FAIL" if enough else "FAIL (thin window)"
    return "PASS" if (ok and enough) else "not yet"


w("| Exit criterion | Target | Now | |")
w("|---|---|---|---|")
w("| Blocking findings only they caught | 0 | %d | %s |"
  % (len(missed), verdict(bool(missed), True)))
w("| Our precision on judged findings | >= 0.95 | %s | %s |"
  % (pct(ours_p),
     verdict(ours_p is not None and ours_p < 0.95, ours_p is not None)))
w("| Pull requests reviewed by both | >= %d | %d | %s |"
  % (MIN_BOTH, both_reviewed, "PASS" if enough else "not yet"))
w("")

w("## Both reviewers, side by side")
w("")
w("| | %s | %s |" % (ours_name, theirs_name))
w("|---|---|---|")
for label, key in (("accepted", "accepted"), ("partial", "partial"),
                   ("rejected", "rejected"), ("acknowledged", "acknowledged"),
                   ("no reply", "no_reply"), ("unclassified", "unknown")):
    w("| %s | %d | %d |" % (label, totals["ours"][key], totals["theirs"][key]))
w("| **precision** | **%s** | **%s** |" % (pct(ours_p), pct(theirs_p)))
w("| judged (the denominator) | %d | %d |" % (ours_judged, theirs_judged))
w("| blocking, author-confirmed | %d | %d |"
  % (totals["ours"]["blocking_accepted"], totals["theirs"]["blocking_accepted"]))
w("")
w("Precision counts `accepted` plus half credit for `partial`, over findings the")
w("author actually judged. `no reply` and `acknowledged` are excluded, not")
w("counted as wrong — a finding nobody ruled on is not one anybody accepted.")
w("")

w("## Blocking findings only they caught")
w("")
if not missed:
    w("_None in this window._")
else:
    w("Each is a blocking finding the author confirmed, on a pull request where we")
    w("said nothing. Read them before trusting the number: this over-counts when our")
    w("review ran on an earlier commit than the one carrying the defect.")
    w("")
    for repo, number, path, line, _ in missed:
        w("- %s#%s `%s:%s`" % (repo, number, path, line))
w("")

w("## Per pull request")
w("")
w("| PR | title | ours (a/p/r) | theirs (a/p/r) | both |")
w("|---|---|---|---|---|")
for repo, number, title, counts, present in rows:
    def cell(which):
        c = counts[which]
        if not c:
            return "—"
        return "%d/%d/%d" % (c.get("accepted", 0), c.get("partial", 0), c.get("rejected", 0))
    w("| #%s | %s | %s | %s | %s |"
      % (number, (title or "")[:52].replace("|", "\\|"), cell("ours"), cell("theirs"),
         "yes" if (present["ours"] and present["theirs"]) else ""))

text = "\n".join(out) + "\n"
if out_file:
    with open(out_file, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    sys.stderr.write("report: wrote %s (%d bytes)\n" % (out_file, len(text.encode("utf-8"))))
else:
    sys.stdout.write(text)
PY
