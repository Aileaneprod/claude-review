#!/usr/bin/env bash
#
# propose-learnings.sh — turn the harvested ledger into candidate lessons.
#
# Usage:
#   propose-learnings.sh [--ledger DIR] [--reviewer NAME] [--min-count N]
#
#   --ledger DIR     Where harvest-feedback.sh wrote its records. Default ../feedback
#   --reviewer NAME  Only report on this reviewer. Default: claude (ours).
#                    Pass `all` to include CodeRabbit and others, which is useful
#                    for seeing what a competitor catches that we do not.
#   --min-count N    Only propose a lesson for a pattern seen at least N times.
#                    Default 1 while the ledger is small; raise it as it grows.
#
# Prints a report and a set of DRAFT lessons to stdout. It writes nothing.
#
# Deliberately not automated. A wrong lesson does not spoil one review, it
# spoils every review in every repository until somebody notices — and this
# project has already had a confident, well-argued, wholly incorrect diagnosis
# reach the prompt. The final wording is a human's job; this only finds the
# candidates and hands over the evidence.
#
# Workflow: harvest-feedback.sh -> propose-learnings.sh -> edit
# prompts/learnings.md (or the target repo's .claude-review/learnings.md) -> PR.
#
# Requires: python3.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ledger_dir="${script_dir}/../feedback"
reviewer="claude"
min_count=1

die() {
  printf 'propose-learnings: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger)    [ "$#" -ge 2 ] || die "--ledger requires a value";    ledger_dir="$2"; shift 2 ;;
    --reviewer)  [ "$#" -ge 2 ] || die "--reviewer requires a value";  reviewer="$2";   shift 2 ;;
    --min-count) [ "$#" -ge 2 ] || die "--min-count requires a value"; min_count="$2";  shift 2 ;;
    -h|--help)   sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -d "$ledger_dir" ] || die "no ledger at $ledger_dir — run harvest-feedback.sh first"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

python3 - "$ledger_dir" "$reviewer" "$min_count" <<'PY'
import json
import os
import sys

ledger_dir, want_reviewer, min_count = sys.argv[1], sys.argv[2], int(sys.argv[3])


def _first_line(text):
    """First meaningful line, stripped of severity decoration and markdown.

    Skips the banner reviewers put above the actual claim — CodeRabbit's
    `_Category_ | _Severity_ | _Effort_` line carries no information, and
    surfacing it instead of the claim makes every proposal look identical.
    """
    in_fence = False
    for raw in (text or "").splitlines():
        line = raw.strip()
        # Fenced blocks must be skipped WHOLE. CodeRabbit embeds the shell it
        # ran inside ``` blocks, and skipping only the fence line surfaces
        # `#!/bin/bash` as though it were the finding.
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # HTML scaffolding (<details>/<summary>), table rows, and the metadata
        # reviewers print around their tool traces.
        if not line or line.startswith(
            ("<", "_Source", "🏁", "🌐", "💡", "|", "---",
             "Repository:", "Length of output:", "As per")
        ):
            continue
        # A banner is all italic segments separated by pipes, with no sentence.
        if line.count("|") >= 2 and line.startswith("_"):
            continue
        for token in ("🔴", "🟠", "🟡", "🟣", "**", "*", "#", ">", "_"):
            line = line.replace(token, " ")
        line = " ".join(line.split())
        if line:
            return line
    return "(no text)"

records = []
for root, _dirs, files in os.walk(ledger_dir):
    for fname in sorted(files):
        if not fname.endswith(".json"):
            continue
        try:
            with open(os.path.join(root, fname), encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        for f in doc.get("findings", []):
            f = dict(f)
            f["repo"] = doc.get("repo")
            f["pr"] = doc.get("pr")
            records.append(f)

if not records:
    print("No harvested findings yet. Run harvest-feedback.sh on a reviewed PR.")
    raise SystemExit(0)

if want_reviewer != "all":
    scoped = [r for r in records if (r.get("reviewer") or "").startswith(want_reviewer)]
else:
    scoped = records

print("# Learning proposals")
print()
print("Ledger: %d finding(s) across %d pull request(s)."
      % (len(records), len({(r["repo"], r["pr"]) for r in records})))
print()

# --- scoreboard --------------------------------------------------------------
print("## Where each reviewer stands")
print()
print("| reviewer | accepted | partial | rejected | no reply | precision* |")
print("|---|---|---|---|---|---|")
by_rev = {}
for r in records:
    by_rev.setdefault(r.get("reviewer") or "?", []).append(r)
for rev, rows in sorted(by_rev.items()):
    counts = {k: 0 for k in ("accepted", "partial", "rejected", "no_reply", "unknown")}
    for r in rows:
        counts[r.get("verdict_guess", "unknown")] = counts.get(r.get("verdict_guess", "unknown"), 0) + 1
    judged = counts["accepted"] + counts["partial"] + counts["rejected"]
    prec = ("%.2f" % ((counts["accepted"] + 0.5 * counts["partial"]) / judged)) if judged else "n/a"
    print("| %s | %d | %d | %d | %d | %s |"
          % (rev, counts["accepted"], counts["partial"], counts["rejected"],
             counts["no_reply"], prec))
print()
print("\\* accepted + half credit for partial, over findings the author actually")
print("judged. Findings with no reply are excluded, not counted as wrong.")
print()

# --- the highest-value lessons: things we got wrong ---------------------------
rejected = [r for r in scoped if r.get("verdict_guess") == "rejected"]
print("## Rejected findings — draft a lesson for each")
print()
if not rejected:
    print("_None. Nothing rejected means either genuinely good precision or too few")
    print("judged findings to tell yet — check the scoreboard above._")
else:
    for r in rejected:
        print("### %s#%s — `%s:%s`" % (r["repo"], r["pr"], r.get("path"), r.get("line")))
        print()
        print("**What we said:** %s" % _first_line(r.get("finding")))
        print()
        print("**What the author said:** %s" % _first_line(r.get("human_reply")))
        print()
        print("Reviewed at commit `%s` — re-check against that, not the branch tip."
              % (r.get("reviewed_commit") or "unknown")[:12])
        print()
        print("> Draft lesson — rewrite in your own words before merging:")
        print("> ")
        print("> ## <one imperative rule that would have prevented this>")
        print("> ")
        print("> <the rule>")
        print("> ")
        print("> **Evidence:** %s#%s, the author replied %s"
              % (r["repo"], r["pr"],
                 json.dumps(_first_line(r.get("human_reply"))[:160], ensure_ascii=False)))
        print()

# --- what a competitor caught and we did not ---------------------------------
ours = {(r["repo"], r["pr"]) for r in records if (r.get("reviewer") or "").startswith("claude")}
theirs = [r for r in records
          if not (r.get("reviewer") or "").startswith("claude")
          and r.get("verdict_guess") in ("accepted", "partial")
          and (r["repo"], r["pr"]) in ours]
print("## Accepted findings from other reviewers on PRs we also reviewed")
print()
if not theirs:
    print("_None recorded._")
else:
    print("Each is something a competing reviewer found, the author agreed with, and")
    print("we did not raise. Worth asking why — a missing profile check, a category")
    print("the priority ladder ranks too low, or a genuine blind spot.")
    print()
    for r in theirs:
        print("- **%s** on `%s:%s` (%s#%s) — %s"
              % (r.get("reviewer"), r.get("path"), r.get("line"),
                 r["repo"], r["pr"], _first_line(r.get("finding"))[:160]))
    print()

print("---")
print()
print("Merge nothing from here verbatim. Each lesson must be one rule, phrased as")
print("an instruction, with the evidence that earned it. Delete lessons that stop")
print("paying for their place — this file is read on every single review.")
PY
