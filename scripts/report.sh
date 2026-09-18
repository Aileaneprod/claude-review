#!/usr/bin/env bash
#
# report.sh — the one page that answers "can we switch the other reviewer off?"
#
# Usage:
#   report.sh --ledger DIR [--ours claude] [--theirs coderabbitai]
#             [--since PR] [--since-note TEXT] [--gold-agreement N/M] [--out FILE]
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
#   --gold-agreement N/M
#                  The classifier's agreement with the hand-labelled gold set,
#                  as "agreed/checked" from classify-verdicts.sh --agreement-out.
#                  Printed as a fourth criterion row. Below 95% the precision
#                  row is marked provisional: that number is only as good as the
#                  verdicts it is computed from, and the gate that certifies
#                  them ran red for four days without the page saying a word.
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
#   * The criterion counts FINDINGS of theirs, not pull requests. Every
#     author-confirmed blocking finding of theirs lands in exactly one bucket,
#     and the page prints the bucket beside the number:
#
#       absent          our reviewer never ran on that pull request
#       present, silent it ran and filed nothing in that file
#       covered         we raised the same defect
#       to adjudicate   we filed in that file and nobody has yet read the two
#                       findings side by side
#
#     The criterion counts `absent + present, silent`. `absent` is displayed on
#     its own: a review that never ran is a plumbing failure, and plumbing and
#     recall are not repaired in the same place. `to adjudicate` is counted in
#     neither direction and printed in full — see the overlap note on the page.
#
# A HUMAN'S RULING, AND HOW TO WRITE ONE.
#
#   Every number on this page is a classifier's reading of what the author
#   wrote. Where a human has read the thread and disagrees, four fields on that
#   finding's record in the ledger say so:
#
#     "verdict_human":  accepted | partial | rejected | acknowledged | no_reply
#     "severity_human": blocking | important | nit | preexisting
#     "ruled_by":       who is ruling
#     "ruling":         why, in their own words
#
#   `verdict_human` outranks the classifier's verdict; `severity_human` outranks
#   the severity read off the finding's own text. They are INDEPENDENT, and that
#   is the whole reason there are two: the case that forced this was a finding
#   the author ACCEPTED and downgraded in the same reply — important rather than
#   blocking, nothing breaks at runtime. A taxonomy carrying only a verdict can
#   record that as `rejected`, which is a rejection the author never made, or as
#   nothing at all, which leaves the criterion counting a blocking miss the
#   author said was not blocking.
#
#   Both fields are IGNORED unless `ruled_by` and `ruling` are both filled in,
#   and a ruling that is ignored is NAMED on the page rather than dropped. An
#   override that moves the one number deciding whether a paid tool is switched
#   off, carrying nobody's name and no reason, is not evidence — and it cannot
#   be told apart from a stray field written by a bug. For the same reason the
#   page prints what the classifier alone produced beside every number a ruling
#   moved: a hand-written ruling may move the headline, never in silence.
#
#   harvest-feedback.sh carries all four fields across a re-harvest, so a ruling
#   written by hand survives the next scheduled run that rewrites the document.
#
# Requires: python3.

set -euo pipefail

ledger_dir=""
ours="claude"
theirs="coderabbitai"
since=""
since_given=0
since_note=""
gold_agreement=""
gold_agreement_given=0
out_file=""

die() { printf 'report: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger) [ "$#" -ge 2 ] || die "--ledger requires a value"; ledger_dir="$2"; shift 2 ;;
    --ours)   [ "$#" -ge 2 ] || die "--ours requires a value";   ours="$2";       shift 2 ;;
    --theirs) [ "$#" -ge 2 ] || die "--theirs requires a value"; theirs="$2";     shift 2 ;;
    --since)  [ "$#" -ge 2 ] || die "--since requires a value";  since="$2"; since_given=1; shift 2 ;;
    --since-note) [ "$#" -ge 2 ] || die "--since-note requires a value"; since_note="$2"; shift 2 ;;
    --gold-agreement) [ "$#" -ge 2 ] || die "--gold-agreement requires a value"; gold_agreement="$2"; gold_agreement_given=1; shift 2 ;;
    --out)    [ "$#" -ge 2 ] || die "--out requires a value";    out_file="$2";   shift 2 ;;
    -h|--help) sed -n '2,95p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$ledger_dir" ] || die "--ledger is required"
[ -d "$ledger_dir" ] || die "no ledger at $ledger_dir"

# Fail closed, like --since: a malformed fraction must not be read as "no
# score", because "no score" prints a page that looks complete.
#
# The first version of this guard was two case patterns and let three things
# through, all found on the pull request that introduced it: a bare "46" (no
# slash) matched neither pattern and crashed the Python with an unpack error —
# exit 1 and a traceback; an empty value was read as the flag being absent;
# and "46/45" rendered as 102.2% and passed the gate. The shape is admitted
# positively now — digits, one slash, digits — and the two arithmetic
# constraints are checked here, in the shell, before anything is rendered.
gold_fail() { printf 'report: --gold-agreement %s (got "%s").\n' "$1" "$gold_agreement" >&2; exit 2; }
if [ "$gold_agreement_given" -eq 1 ]; then
  case "$gold_agreement" in
    [0-9]*/[0-9]*) : ;;
    *) gold_fail 'needs "agreed/checked" — digits, one slash, digits' ;;
  esac
  case "$gold_agreement" in
    *[!0-9/]*|*/*/*) gold_fail 'needs "agreed/checked" — digits, one slash, digits' ;;
  esac
  gold_agreed="${gold_agreement%/*}"
  gold_checked="${gold_agreement#*/}"
  # Nine digits a side, at most. A gold set has dozens of entries, and the
  # shell's `-gt` on a twenty-digit operand prints "integer expected" and
  # returns 2 — which inside an `if` is merely false, and set -e stays quiet.
  # An oversized value therefore walked past the comparison and the page
  # printed "10000000000000000000000.0% | PASS". Bounding the length keeps
  # every later comparison inside what the shell can actually compare.
  if [ "${#gold_agreed}" -gt 9 ] || [ "${#gold_checked}" -gt 9 ]; then
    gold_fail 'has more than nine digits on a side, which no gold set has'
  fi
  # A count is written without leading zeros on either side; a bare 0 is a
  # real value for agreed (nothing agreed) and never for checked.
  case "$gold_agreed" in
    0) : ;;
    0*) gold_fail 'writes agreed with a leading zero, which is not how a count is written' ;;
  esac
  case "$gold_checked" in
    0|0*) gold_fail 'checked nothing; a gold set that matches nothing is not a score' ;;
  esac
  if [ "$gold_agreed" -gt "$gold_checked" ]; then
    gold_fail 'has more agreed than checked, which is not a fraction of anything'
  fi
fi

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

LEDGER_DIR="$ledger_dir" OURS="$ours" THEIRS="$theirs" SINCE="$since" SINCE_NOTE="$since_note" GOLD_AGREEMENT="$gold_agreement" OUT_FILE="$out_file" \
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
gold_agreement = os.environ.get("GOLD_AGREEMENT") or ""

# Below this many pull requests reviewed by both, the two substantive
# criteria cannot be said to have PASSED — there is not enough of a window
# for the question to have been asked. Stated once; the table interpolates
# it rather than repeating it.
MIN_BOTH = 15


def truncated(value, places):
    """Truncated DOWN to `places` decimals, through Decimal so the float is not
    what gets truncated. See pct() for the story; this is the same rule with
    the number of places as a parameter, because the agreement row needed one
    decimal and its first version used %.1f — which rounds, and printed 94.96%
    as "95.0%" beside a FAIL against a 95% gate. The same bug, in the same
    file, on the same day pct() was written to end it."""
    quantum = decimal.Decimal(1).scaleb(-places)
    q = decimal.Decimal(str(value)).quantize(quantum, rounding=decimal.ROUND_DOWN)
    return "%.*f" % (places, q)


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
    return truncated(value, 2)
out_file = os.environ.get("OUT_FILE") or ""

JUDGED = ("accepted", "partial", "rejected")


SEVERITIES = (("🔴", "blocking"), ("🟠", "important"),
              ("🟡", "nit"), ("🟣", "preexisting"))

# The other reviewer prefixes every finding with a one-line table of italic
# cells, severity always second:
#
#     _🎯 Functional Correctness_ | _🟠 Major_ | _⚡ Quick win_
#
# TWO or more cells, not one or more. One cell would also match a prose line
# that merely happens to be italic end to end, and eating that line would throw
# away a severity the author wrote. Two cells joined by `|` is a table row and
# nothing else: on the harvest of 2026-09-18 this matched 452 of their 452
# findings and 0 of our 196, so it is applied to both sides unconditionally
# rather than keyed on a reviewer name.
HEADER_LINE = re.compile(r"^\s*_[^_\n]+_(\s*\|\s*_[^_\n]+_)+\s*$")

# Innermost-first, so repetition unwinds nesting instead of pairing an outer
# opening tag with an inner closing one. `<details>A<details>B</details>C</details>`
# under a plain non-greedy pattern leaves `C</details>` — C escapes into the
# prose it was folded away from. 81 of their findings nest; on this corpus the
# two variants never disagreed about a LABEL, but one of them is right about
# what it is doing and the other happens to be.
DETAILS = re.compile(r"<details\b(?:(?!<details\b).)*?</details\s*>",
                     re.DOTALL | re.IGNORECASE)


def split_header(text):
    """(header line, everything after it). Empty header when there is none."""
    lines = (text or "").split("\n")
    i = 0
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i < len(lines) and HEADER_LINE.match(lines[i]):
        return lines[i], "\n".join(lines[i + 1:])
    return "", (text or "")


def prose_of(body):
    """`body` with its collapsed `<details>` blocks removed.

    Those blocks carry static-analysis transcripts, web queries and proposed
    diffs — text the finding quotes, not text it asserts. They also carry
    severity emoji of their own, which is how a folded block came to decide a
    finding's severity.
    """
    previous = None
    current = body
    while previous != current:
        previous = current
        current = DETAILS.sub("", current)
    # An unclosed `<details>` is prose up to the tag and a fold after it. Two
    # findings in the ledger have unbalanced tags; without this they would
    # carry their whole appendix into the scan.
    cut = current.lower().find("<details")
    if cut >= 0:
        current = current[:cut]
    return current


def highest(text):
    for emoji, label in SEVERITIES:
        if emoji in text:
            return label
    return None


def severity(text):
    """(label, source) — source is "prose", "header" or "none".

    The whole prose is scanned, not its first 400 characters. The cap had no
    written justification and it could only ever UNDERSTATE: it hid a 🔴 that
    sat past the cap behind a 🟠 that sat before it, never the reverse. On the
    harvest of 2026-09-18 it understated 13 findings and overstated none — a
    bias that ran one way, against the reviewer being measured.

    The header is a fallback, not a tiebreak. It is a coarse label the tool
    assigns; the prose is what the reviewer wrote about this defect, and 29
    findings label the prose MORE severe than the header. Where the prose says
    nothing the header is all there is, and the page prints how many labels
    came from it rather than merging the two silently: 118 of 452 here, 111 of
    them written before korbyx's `.coderabbit.yaml` severity convention landed
    on 2026-08-11.

    Deliberately no word-based rescue for a `Bloquant` written without its
    emoji. It would recover two findings, and a keyword scan over free prose is
    one sentence away from matching a finding that merely discusses blocking.
    """
    header, body = split_header(text or "")
    label = highest(prose_of(body))
    if label:
        return label, "prose"
    label = highest(header)
    if label:
        return label, "header"
    return "unlabelled", "none"


def classifier_verdict(finding):
    """What the machinery read off the author's reply: the model, then keywords
    over the whole reply, then the first-word guess harvest-feedback.sh makes.

    `verdict_human` used to head this chain, under the comment "a human's own
    correction outranks the model". Measured on the ledger it appeared in 0 of
    the 153 documents carrying findings: designed, honoured by this reader, and
    never once written. Nothing said how to write one, and nothing promised a
    hand-written field would survive the next harvest — so the documented
    priority was in practice `verdict_llm > verdict_keyword > verdict_guess`,
    and the model was never outranked by anybody.

    It is a RULING now, read by ruling_of() below, and it is off this chain
    because a ruling is admitted on different evidence: it has to carry a name
    and a reason. A chain lookup cannot express that.
    """
    for key in ("verdict_llm", "verdict_keyword", "verdict_guess"):
        value = finding.get(key)
        if value:
            return value
    return "unknown"


# The vocabulary each ruling field is allowed. Anything else is refused and
# named, never coerced: a `severity_human` of "orange" or "🟠" that silently did
# nothing would reproduce, by hand, the exact defect `verdict_human` had.
#
# `unknown` is deliberately not a verdict a human may write. The classifier says
# `unknown` when it cannot read the reply; a human who cannot tell either has
# not ruled, and should leave the fields out.
VERDICT_WORDS = ("accepted", "partial", "rejected", "acknowledged", "no_reply")
SEVERITY_WORDS = tuple(label for _emoji, label in SEVERITIES)

# WHO and WHY, or it does not count. Both, and both non-empty.
ATTRIBUTION = ("ruled_by", "ruling")


def _written(finding, field):
    value = finding.get(field)
    return value.strip() if isinstance(value, str) and value.strip() else ""


def ruling_of(finding):
    """(verdict or None, severity or None, [refusal, ...]).

    A human's ruling on one finding. Either field may be set, or both, or
    neither — they are independent because the author's own replies are: the
    finding that forced this concept was accepted on its substance and
    downgraded on its severity in the same sentence.

    Refused rather than applied when the ruling carries no `ruled_by` and
    `ruling`. The page this feeds decides whether a paid review tool is
    switched off, and these two fields are the only ones on it that a human
    writes by hand into a document every other field of which is machine-
    written. An unattributed one cannot be told from a bug in whatever wrote it,
    and it can move the headline. The refusal is returned rather than swallowed
    so the page can print it: a ruling that quietly does nothing is the failure
    `verdict_human` already had, and repeating it silently would be worse than
    having no override at all.
    """
    claimed = [(field, _written(finding, field), words)
               for field, words in (("verdict_human", VERDICT_WORDS),
                                    ("severity_human", SEVERITY_WORDS))]
    claimed = [c for c in claimed if c[1]]
    if not claimed:
        return None, None, []

    missing = [field for field in ATTRIBUTION if not _written(finding, field)]
    if missing:
        return None, None, ["%s written without %s"
                            % (" and ".join("`%s`" % c[0] for c in claimed),
                               " or ".join("`%s`" % f for f in missing))]

    verdict = label = None
    refusals = []
    for field, word, words in claimed:
        if word not in words:
            refusals.append("`%s: %s` is not one of %s"
                            % (field, word, ", ".join(words)))
        elif field == "verdict_human":
            verdict = word
        else:
            label = word
    return verdict, label, refusals


def tag_of(finding):
    """A short handle for one finding, so a list a human is asked to read can
    be read.

    Two blocking findings of theirs on the same file with a null `line` print
    as the same bullet otherwise — and null is the normal case, not the corner
    one. `key` is `repo#pr|path|line|digest`, written by harvest-feedback.sh
    over the finding's own text, so its last field identifies the finding and
    survives re-anchoring. It is a digest, not the text: nothing quoted from a
    client repository reaches this page that was not already on it.
    """
    key = finding.get("key") or ""
    digest = key.rsplit("|", 1)[-1] if "|" in key else ""
    return digest or (finding.get("finding_at") or "")


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

rows, totals, unruled = [], {}, {}
for key in ("ours", "theirs"):
    totals[key] = {v: 0 for v in ("accepted", "partial", "rejected",
                                  "acknowledged", "no_reply", "unknown")}
    totals[key]["blocking_accepted"] = 0
    # How many of that side's severity labels came from the header rather than
    # from the prose. Printed, never merged in silently: a label the tool
    # assigned and a label the reviewer wrote are different evidence, and the
    # page that decides has to be able to say which it is counting.
    totals[key]["header_label"] = 0
    # And how many rest on a human's ruling rather than on any reading of the
    # text at all. Same rule, same reason: a number a person decided and a
    # number a classifier decided are different evidence.
    totals[key]["ruled_verdict"] = 0
    totals[key]["ruled_severity"] = 0
    # The same tally with every ruling ignored — what this page would say if no
    # human had touched it. It exists so the page can print both: an override
    # nobody can see is the same defect as a misreading nobody can see, and the
    # criterion here is the number that ends a contract.
    unruled[key] = dict(totals[key])

# Every honoured ruling, and every one refused, so both can be printed by name.
rulings = []
refused = []

# A confirmed blocking finding of theirs lands in exactly one of these.
missed_absent = []      # our reviewer never ran
missed_silent = []      # it ran and filed nothing in that file
adjudicate = []         # we filed in that file; nobody has compared the two
#
# There is no `covered` list. Deciding that we raised the same defect takes a
# rule for when two findings are the same finding, and the evidence for the one
# rule worth having is not in the ledger — see the bucketing below. Every
# candidate goes to `adjudicate` instead, which is why the criterion is a floor
# and the page says so.
#
# The same criterion with every human ruling ignored. The page prints the two
# side by side, so a ruling can move the number that ends a contract and cannot
# move it without the reader seeing where it came from.
criterion_unruled = 0
both_reviewed = 0

for (repo, number), doc in sorted(prs.items(), key=lambda kv: (kv[0][0] or "", kv[0][1] or 0)):
    counts = {"ours": {}, "theirs": {}}

    # Presence, not productivity. `reviewed_by_ours` is written by
    # harvest-feedback.sh from the sticky summary our reviewer posts on every
    # completed run, so a review that read the diff and had nothing to file is
    # no longer indistinguishable from one that never ran.
    #
    # That distinction is what the BUCKETING below turns on, and getting it
    # wrong labelled the reviewer absent for the behaviour its own prompt calls
    # "a valid, frequent, and good outcome". On Aileaneprod/korbyx#92 our
    # reviewer ran three times and posted a reasoned 0/0/0 summary; the ledger
    # held zero findings from us, so it read as a review that never happened.
    #
    # What this flag decides is which bucket, not whether to count. A blocking
    # finding of theirs on a pull request we were present for is still one we
    # did not raise; it is a failure of recall rather than of plumbing, and the
    # page reports the two separately for exactly that reason.
    #
    # `or` and not `=`: a document harvested before the field existed has no
    # opinion, and falls back to the old inference rather than asserting we were
    # absent. Re-harvesting upgrades it; nothing regresses in the meantime.
    present = {"ours": bool(doc.get("reviewed_by_ours")), "theirs": False}
    pr_missed = []
    # The same list with every ruling ignored, so the counterfactual the page
    # prints beside the criterion is computed rather than asserted.
    pr_missed_unruled = []
    ours_here = []
    for finding in doc["findings"]:
        which = side(finding)
        if which is None:
            continue
        present[which] = True
        if which == "ours":
            ours_here.append(finding)

        ruled_verdict, ruled_label, refusals = ruling_of(finding)
        for problem in refusals:
            refused.append((repo, number, finding.get("path"),
                            tag_of(finding), problem))

        base_verdict = classifier_verdict(finding)
        base_label, base_source = severity(finding.get("finding"))
        verdict = ruled_verdict or base_verdict
        label = ruled_label or base_label

        counts[which][verdict] = counts[which].get(verdict, 0) + 1
        if verdict in totals[which]:
            totals[which][verdict] += 1
        if base_verdict in unruled[which]:
            unruled[which][base_verdict] += 1
        # Counted against the label actually in use: where a human ruled, the
        # label is not the tool's header any more, and a caveat about the
        # header would be describing a number this page no longer prints.
        if ruled_label is None and base_source == "header":
            totals[which]["header_label"] += 1
        if base_source == "header":
            unruled[which]["header_label"] += 1
        if ruled_verdict:
            totals[which]["ruled_verdict"] += 1
        if ruled_label:
            totals[which]["ruled_severity"] += 1
        if ruled_verdict or ruled_label:
            rulings.append((repo, number, finding.get("path"), tag_of(finding),
                            base_verdict, ruled_verdict, base_label, ruled_label,
                            _written(finding, "ruled_by"),
                            _written(finding, "ruling")))

        if label == "blocking" and verdict in ("accepted", "partial"):
            totals[which]["blocking_accepted"] += 1
            if which == "theirs":
                pr_missed.append(finding)
        if base_label == "blocking" and base_verdict in ("accepted", "partial"):
            unruled[which]["blocking_accepted"] += 1
            if which == "theirs":
                pr_missed_unruled.append(finding)

    if present["ours"] and present["theirs"]:
        both_reviewed += 1

    # The 2026-09-07 correction, kept: a review that ran and had nothing to file
    # must not score like one that never ran. `reviewed_by_ours` is written by
    # harvest-feedback.sh from the sticky summary, and korbyx#92 is the case it
    # was written for — three runs, a reasoned 0/0/0 summary, zero findings.
    #
    # The same correction over-reached, and this is where it is walked back. It
    # said `if pr_missed and not present["ours"]`, so a pull request our reviewer
    # merely SHOWED UP on scored zero misses however much it failed to see. That
    # measures our plumbing's availability, not our reviewer's recall, and the
    # criterion is about recall. Presence now decides which bucket a finding
    # lands in, not whether it is counted at all.
    #
    # Overlap is the reason this is not simply `for finding in pr_missed`. Some
    # of those findings are defects we raised too, and counting them would swap
    # a number that was too low for one that is too high. Two findings address
    # the same defect when they sit on the same file and their line ranges
    # intersect — except that `line` is null on 225 of their 452 findings and 96
    # of our 196 (GitHub nulls it on an outdated thread), and where both sides
    # do carry one it never once matched: 0 exact matches, 3 pairs within fifty
    # lines, out of 21 same-file candidates. There is no line evidence to rule
    # on, so nothing is ruled. Same file is treated as necessary-but-not-
    # sufficient: no finding of ours in that file is scored as not covered, and
    # a finding of ours in that file is sent to a human, listed by name, and
    # counted in neither direction.
    ours_paths = set(f.get("path") for f in ours_here if f.get("path"))
    for finding in pr_missed:
        where = (repo, number, finding.get("path"), finding.get("line"),
                 tag_of(finding))
        if not present["ours"]:
            missed_absent.append(where)
        elif finding.get("path") in ours_paths:
            adjudicate.append(where + (
                sorted(set(f.get("line") for f in ours_here
                           if f.get("path") == finding.get("path")),
                       key=lambda value: (value is None, value or 0)),))
        else:
            missed_silent.append(where)

    # The same arithmetic with the rulings taken out: absent and present-silent
    # count, `adjudicate` does not. Written as one expression rather than a
    # second copy of the block above so the two cannot drift apart — a
    # counterfactual that stops matching the real thing is a lie with a number
    # on it.
    criterion_unruled += sum(
        1 for finding in pr_missed_unruled
        if not present["ours"] or finding.get("path") not in ours_paths)

    rows.append((repo, number, doc.get("title") or "", counts, present))

# The criterion: every confirmed blocking finding of theirs that we are known
# not to have raised. Absent and present-silent both count — one is our
# plumbing and one is our recall, and the question "did we catch it" does not
# care which failed. `covered` and `adjudicate` do not count.
criterion = len(missed_absent) + len(missed_silent)
criterion_prs = sorted(set((r, n) for r, n, _p, _l, _t in missed_absent + missed_silent))


def precision(bucket):
    judged = sum(bucket[v] for v in JUDGED)
    if not judged:
        return None, 0
    return (bucket["accepted"] + 0.5 * bucket["partial"]) / judged, judged


out = []
w = out.append

ours_p, ours_judged = precision(totals["ours"])
theirs_p, theirs_judged = precision(totals["theirs"])
ours_p_unruled, _unruled_judged = precision(unruled["ours"])
theirs_p_unruled, _unruled_judged_theirs = precision(unruled["theirs"])

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

# The classifier's score, when given. The precision row is computed from the
# verdicts this classifier produced, so below its gate that row cannot be
# called PASSED whatever the arithmetic says — the arithmetic is the part in
# doubt. "not yet (provisional)" rather than FAIL: nothing was measured wrong,
# the measuring instrument is uncertified.
GOLD_GATE = 95.0
gold_pct = None
gold_agreed = gold_checked = 0
if gold_agreement:
    gold_agreed, gold_checked = (int(x) for x in gold_agreement.split("/"))
    gold_pct = 100.0 * gold_agreed / gold_checked
classifier_uncertified = gold_pct is not None and gold_pct < GOLD_GATE


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
w("| Blocking findings of theirs we did not raise | 0 | %d | %s |"
  % (criterion, verdict(bool(criterion), True)))
precision_verdict = verdict(ours_p is not None and ours_p < 0.95, ours_p is not None)
if classifier_uncertified and precision_verdict == "PASS":
    precision_verdict = "not yet (provisional)"
w("| Our precision on judged findings | >= 0.95 | %s | %s |"
  % (pct(ours_p), precision_verdict))
if gold_pct is not None:
    w("| Classifier agreement with the gold set | >= %d%% | %s%% (%d/%d) | %s |"
      % (GOLD_GATE, truncated(gold_pct, 1), gold_agreed, gold_checked,
         "PASS" if not classifier_uncertified else "FAIL"))
w("| Pull requests reviewed by both | >= %d | %d | %s |"
  % (MIN_BOTH, both_reviewed, "PASS" if enough else "not yet"))
w("")
# The definition travels with the number. Two different questions live on this
# page — "how many findings of theirs did we not raise" and "on how many pull
# requests do we have no confirmed blocking finding" — they have different
# answers, and a bare figure that does not say which one it answers is how this
# page came to publish a 1 that meant neither.
w("The first row counts **findings, not pull requests**. It is %d"
  % criterion)
w("author-confirmed blocking finding(s) of %s's that we are known not" % theirs_name)
w("to have raised, spread over %d pull request(s): %d where our reviewer never"
  % (len(criterion_prs), len(missed_absent)))
w("ran, and %d where it ran and filed nothing in that file."
  % len(missed_silent))
if criterion_unruled != criterion:
    w("")
    w("**%d of that figure rests on a human's ruling, not on the classifier.**"
      % abs(criterion_unruled - criterion))
    w("The classifier alone reads %d. Every ruling behind the difference is named"
      % criterion_unruled)
    w("under \"Human rulings\" below, with who wrote it and why.")
if adjudicate:
    w("")
    w("It is a FLOOR, not a total: %d further finding(s) of theirs sit beside one of"
      % len(adjudicate))
    w("ours in the same file, and whether those are the same defect is a question")
    w("this page refuses to answer by guessing. They are listed below, by name.")
w("")

w("## Human rulings")
w("")
w("Every number on this page is a classifier's reading of what the author")
w("wrote — the model, then keywords over the reply, then a first-word guess.")
w("A human who has read the thread can rule on a finding by hand, and %d of"
  % len(rulings))
w("the findings in this window carry such a ruling.")
w("")
if rulings:
    # The whole point of the section. A ruling is allowed to move a published
    # number; it is not allowed to move one invisibly, so the number the
    # classifier alone produces is printed beside the number a human's judgement
    # produces, on the same page, and every ruling behind the difference is
    # named underneath with who wrote it and why.
    w("| | classifier alone | after the rulings below |")
    w("|---|---|---|")
    w("| Blocking findings of theirs we did not raise | %d | %d |"
      % (criterion_unruled, criterion))
    w("| Our precision on judged findings | %s | %s |"
      % (pct(ours_p_unruled), pct(ours_p)))
    w("| %s's precision on judged findings | %s | %s |"
      % (theirs_name, pct(theirs_p_unruled), pct(theirs_p)))
    w("| blocking and author-confirmed, %s | %d | %d |"
      % (theirs_name, unruled["theirs"]["blocking_accepted"],
         totals["theirs"]["blocking_accepted"]))
    w("")
    w("Where the two columns differ, a person decided it and is named below.")
    w("Where they agree, the ruling confirmed what the classifier already said.")
    w("")
    for (repo, number, path, tag, base_verdict, ruled_verdict,
         base_label, ruled_label, ruled_by, note) in rulings:
        moved = []
        if ruled_verdict:
            moved.append("verdict %s -> **%s**" % (base_verdict, ruled_verdict))
        if ruled_label:
            moved.append("severity %s -> **%s**" % (base_label, ruled_label))
        w("- %s#%s `%s` %s — %s — %s: %s"
          % (repo, number, path, tag, "; ".join(moved), ruled_by,
             (note or "").replace("\n", " ")))
    w("")
else:
    w("_None in this window._ Every number above is the classifier's.")
    w("")

# Printed whether or not anybody has ruled yet, because the reader who needs it
# is the one looking at a number they believe is wrong. `verdict_human` was
# honoured by this script for months and written zero times; a mechanism nobody
# can find is the same as no mechanism.
w("To rule on a finding, add these four fields to its record in the ledger and")
w("leave the classifier's own fields alone:")
w("")
w("```json")
w('    "verdict_human":  "accepted" | "partial" | "rejected" | "acknowledged" | "no_reply",')
w('    "severity_human": "blocking" | "important" | "nit" | "preexisting",')
w('    "ruled_by":       "who is ruling",')
w('    "ruling":         "why, in your own words"')
w("```")
w("")
w("The verdict and the severity are independent, and that is why there are two.")
w("A finding the author accepted and downgraded in the same reply is")
w('`verdict_human: "accepted"` with `severity_human: "important"`. Writing')
w('`verdict_human: "rejected"` instead would record a rejection the author never')
w("made, and writing nothing leaves the criterion above counting a blocking miss")
w("the author themselves said was not blocking.")
w("")
w("A ruling with no `ruled_by` and `ruling` is refused rather than applied, and")
w("named below. harvest-feedback.sh carries all four fields across a re-harvest,")
w("so a ruling written by hand survives the next run that rewrites the document.")
w("")

if refused:
    w("### rulings this page refused")
    w("")
    w("Each of these findings carries a ruling field this page did NOT apply; the")
    w("classifier's reading stands for every one of them. They are listed rather")
    w("than dropped, because a ruling that quietly does nothing is the defect this")
    w("section exists to close.")
    w("")
    for repo, number, path, tag, problem in refused:
        w("- %s#%s `%s` %s — %s" % (repo, number, path, tag, problem))
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
w("| severity read off the header, not the prose | %d | %d |"
  % (totals["ours"]["header_label"], totals["theirs"]["header_label"]))
w("| verdict set by a human ruling, not the classifier | %d | %d |"
  % (totals["ours"]["ruled_verdict"], totals["theirs"]["ruled_verdict"]))
w("| severity set by a human ruling, not the text | %d | %d |"
  % (totals["ours"]["ruled_severity"], totals["theirs"]["ruled_severity"]))
w("")
w("Precision counts `accepted` plus half credit for `partial`, over findings the")
w("author actually judged. `no reply` and `acknowledged` are excluded, not")
w("counted as wrong — a finding nobody ruled on is not one anybody accepted.")
w("")
w("The last row is a caveat on the one above it. Severity is read from the")
w("finding's own prose, with its collapsed `<details>` appendices removed; where")
w("the prose carries no severity at all, the label falls back to the tool's")
w("header line. Those labels are the tool's, not the reviewer's, and the count")
w("says how many of them there are rather than blending them in unannounced.")
w("")
w("The two rows under it say how much of this table is a person's judgement")
w("rather than a classifier's. Both are zero on a page nobody has ruled on, and")
w("every non-zero one is named in full under \"Human rulings\" above.")
w("")

w("## Blocking findings of theirs we did not raise")
w("")
w("Every author-confirmed blocking finding of %s's sits in exactly one bucket."
  % theirs_name)
w("The criterion above is the first two rows added together.")
w("")
w("| Bucket | Findings | In the criterion |")
w("|---|---|---|")
w("| absent — our reviewer never ran on that pull request | %d | yes |"
  % len(missed_absent))
w("| present, silent — it ran and filed nothing in that file | %d | yes |"
  % len(missed_silent))
w("| covered — we raised the same defect | — | no |")
w("| to adjudicate by hand | %d | not yet |" % len(adjudicate))
w("")
w("`absent` and `present, silent` are both counted and kept apart: a review that")
w("never ran is a plumbing failure, a review that ran and saw nothing is a recall")
w("failure, and they are not repaired in the same place. This row pair used to be")
w("one row holding `absent` alone, which measured whether our reviewer was")
w("available rather than whether it saw anything.")
w("")

if missed_absent:
    w("### absent — our reviewer never ran")
    w("")
    for repo, number, path, line, tag in missed_absent:
        w("- %s#%s `%s:%s` %s" % (repo, number, path, line, tag))
    w("")

if missed_silent:
    w("### present, silent — it ran and filed nothing in that file")
    w("")
    for repo, number, path, line, tag in missed_silent:
        w("- %s#%s `%s:%s` %s" % (repo, number, path, line, tag))
    w("")

if not missed_absent and not missed_silent:
    w("_None in this window._")
    w("")

# The fourth bucket, and why it is a bucket rather than a rule. Guessing here
# would be the same mistake the presence guard made, in the other direction: a
# title-similarity rule that scores `covered` invents coverage, and counting
# every candidate as a miss invents misses.
if adjudicate:
    w("### to adjudicate by hand")
    w("")
    w("Two findings address the same defect when they sit on the same file and")
    w("their line ranges intersect. That rule cannot be run on this ledger: GitHub")
    w("nulls a thread's `line` once the thread goes outdated, and it is null on")
    w("half of both sides' findings. Where both sides did carry a line, it matched")
    w("exactly zero times out of the candidates below. So no finding here is")
    w("scored `covered` and none is scored a miss — each is a pair a human reads.")
    w("")
    w("Same file is treated as necessary but not sufficient: a finding of theirs")
    w("with nothing of ours anywhere in that file is counted as a miss above.")
    w("")
    # `—` where a line is null, which is most of them, and is the whole reason
    # this list exists rather than a rule.
    for repo, number, path, line, tag, ours_lines in adjudicate:
        w("- %s#%s `%s:%s` %s — ours in that file at line(s): %s"
          % (repo, number, path, line, tag,
             ", ".join(str(l) if l is not None else "—" for l in ours_lines)))
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

for _repo, _number, _path, _tag, _problem in refused:
    sys.stderr.write("report: ruling not applied on %s#%s %s: %s\n"
                     % (_repo, _number, _path, _problem))

text = "\n".join(out) + "\n"
if out_file:
    with open(out_file, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    sys.stderr.write("report: wrote %s (%d bytes)\n" % (out_file, len(text.encode("utf-8"))))
else:
    sys.stdout.write(text)
PY
