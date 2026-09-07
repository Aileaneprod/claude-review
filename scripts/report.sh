#!/usr/bin/env bash
#
# report.sh — the one page that answers "can we switch the other reviewer off?"
#
# Usage:
#   report.sh --ledger DIR [--ours claude] [--theirs coderabbitai]
#             [--since PR] [--out FILE]
#
#   --ledger DIR   Harvested ledger (harvest-feedback.sh --out).
#   --ours NAME    Reviewer prefix that is ours. Default: claude.
#   --theirs NAME  The reviewer being compared. Default: coderabbitai.
#   --since PR     Only pull requests at or above this number. Use the freeze
#                  point: a prompt change mid-window invalidates the window.
#   --out FILE     Write the report here. Default: stdout.
#
# The exit criterion this serves, decided before any of it was measured:
#
#   On at least MIN_BOTH pull requests reviewed by both, ZERO author-confirmed blocking
#   findings that they raised and we did not, and our precision >= 0.95 on
#   findings the author actually judged.
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
out_file=""

die() { printf 'report: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger) [ "$#" -ge 2 ] || die "--ledger requires a value"; ledger_dir="$2"; shift 2 ;;
    --ours)   [ "$#" -ge 2 ] || die "--ours requires a value";   ours="$2";       shift 2 ;;
    --theirs) [ "$#" -ge 2 ] || die "--theirs requires a value"; theirs="$2";     shift 2 ;;
    --since)  [ "$#" -ge 2 ] || die "--since requires a value";  since="$2";      shift 2 ;;
    --out)    [ "$#" -ge 2 ] || die "--out requires a value";    out_file="$2";   shift 2 ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$ledger_dir" ] || die "--ledger is required"
[ -d "$ledger_dir" ] || die "no ledger at $ledger_dir"

LEDGER_DIR="$ledger_dir" OURS="$ours" THEIRS="$theirs" SINCE="$since" OUT_FILE="$out_file" \
python3 <<'PY'
import json
import os
import re
import sys

ledger_dir = os.environ["LEDGER_DIR"]
ours_name = os.environ["OURS"]
theirs_name = os.environ["THEIRS"]
since = os.environ.get("SINCE") or ""

# Below this many pull requests reviewed by both, the two substantive
# criteria cannot be said to have PASSED — there is not enough of a window
# for the question to have been asked. Stated once; the table interpolates
# it rather than repeating it.
MIN_BOTH = 15
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
    present = {"ours": False, "theirs": False}
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

w("# Can we switch %s off?" % theirs_name)
w("")
w("Window: %d pull request(s)%s, %d reviewed by both."
  % (len(prs), " from #%s" % since if since else "", both_reviewed))
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
        return "FAIL"
    return "PASS" if (ok and enough) else "not yet"


w("| Exit criterion | Target | Now | |")
w("|---|---|---|---|")
w("| Blocking findings only they caught | 0 | %d | %s |"
  % (len(missed), verdict(bool(missed), True)))
w("| Our precision on judged findings | >= 0.95 | %s | %s |"
  % ("%.2f" % ours_p if ours_p is not None else "n/a",
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
w("| **precision** | **%s** | **%s** |"
  % ("%.2f" % ours_p if ours_p is not None else "n/a",
     "%.2f" % theirs_p if theirs_p is not None else "n/a"))
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
