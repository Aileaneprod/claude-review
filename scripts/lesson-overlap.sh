#!/usr/bin/env bash
#
# lesson-overlap.sh — which lessons does the prompt already give?
#
# Usage:
#   lesson-overlap.sh [--learnings FILE] [--prompts DIR] [--min-overlap N]
#
#   --learnings FILE  The memory file to audit. Default prompts/learnings.md.
#   --prompts DIR     Where base.md and profiles/ live. Default prompts/.
#   --min-overlap N   Report a match only at N shared distinctive terms or more.
#                     Default 3. Lower it to see more, and more noise.
#
# Prints, for each lesson, the passage elsewhere in the prompt that says the
# most similar thing — file, line, and the terms they share. Reads nothing but
# the prompt; no ledger, no model, no network.
#
# WHY THIS EXISTS. `learnings.md` is injected into every review and is capped at
# 7500 bytes by CI, so every lesson is paid for on every run of every repository.
# Lessons arrive through propose-learnings.sh and a human merge, and **nothing
# in that loop asks whether the prompt already says it**. It accreted a
# restatement: "A README's own caveats usually answer the objection you are
# about to raise" was also `base.md`'s "if the document already answers your
# objection elsewhere — often in the paragraph directly above — there is no
# finding", also `base.md`'s guard-clause rule, and also `profiles/generic.md`'s
# "a migration that already has them is correct — do not flag it", which names
# the construct outright. Six live runs of the eval fixture built to catch that
# mistake passed with the lesson deleted from the file: the reviewer was
# following the rule from somewhere else. 703 bytes, read on every review, that
# changed nothing.
#
# WHAT IT CANNOT DO. Two passages can say the same thing in different words, and
# this will not see it; two can share vocabulary and mean different things, and
# this will point at them anyway. It ranks candidates for a person to judge —
# the same division of labour propose-learnings.sh already takes, and for the
# same reason: a wrong deletion here costs every review in every repository.
#
# Requires: python3.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

learnings="${script_dir}/../prompts/learnings.md"
prompts_dir="${script_dir}/../prompts"
min_overlap=3

die() { printf 'lesson-overlap: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --learnings)   [ "$#" -ge 2 ] || die "--learnings requires a value";   learnings="$2";   shift 2 ;;
    --prompts)     [ "$#" -ge 2 ] || die "--prompts requires a value";     prompts_dir="$2"; shift 2 ;;
    --min-overlap) [ "$#" -ge 2 ] || die "--min-overlap requires a value"; min_overlap="$2"; shift 2 ;;
    -h|--help)     sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

case "$min_overlap" in *[!0-9]*) die "--min-overlap must be a whole number (got '${min_overlap}')" ;; esac
[ -f "$learnings" ]   || die "no learnings file at ${learnings}"
[ -d "$prompts_dir" ] || die "no prompts directory at ${prompts_dir}"

python3 - "$learnings" "$prompts_dir" "$min_overlap" <<'PY'
import io
import os
import re
import sys

learnings_path, prompts_dir, min_overlap = sys.argv[1], sys.argv[2], int(sys.argv[3])

# Words that carry no signal about WHAT a rule says. Deliberately short: a long
# stoplist tuned against this corpus would stop finding anything else.
STOP = set("""
a an and are as at be been before but by can cannot do does each else for from
has have if in into is it its not of on one only or other our out over said say
says should so some that the their them then there these they this those to
under up was what when where which while who why will with would you your
already also always any been being both each every just may might must never
new now than too very
""".split())


def terms(text):
    """Distinctive words: five letters or more, not a stopword, lowercased.

    Five is a threshold, not a truth. It drops `read`, `line`, `code` and `file`
    — words every paragraph in a reviewer's prompt contains, which would make
    every passage look like every other one.
    """
    words = re.findall(r"[a-z][a-z_-]{4,}", text.lower())
    return {w for w in words if w not in STOP}


def rule_of(lesson):
    """A lesson is a rule and then its evidence. Only the rule is compared.

    The evidence names repositories, pull requests and quotes replies, none of
    which the base prompt can restate — including it would make every lesson
    look unique, which is the answer this tool must not give by construction.
    """
    body = lesson.split("**Evidence:**")[0]
    return "\n".join(body.splitlines()[1:])


text = io.open(learnings_path, encoding="utf-8").read()
lessons = []
for chunk in re.split(r"(?m)^## ", text)[1:]:
    title = chunk.splitlines()[0].strip()
    lessons.append((title, terms(rule_of(chunk))))

# The corpus: base.md and every profile, split into paragraphs so a match points
# at something a person can read, and carrying its line number so they can go
# and read it.
corpus = []
candidates = [os.path.join(prompts_dir, "base.md")]
profiles = os.path.join(prompts_dir, "profiles")
if os.path.isdir(profiles):
    candidates += [os.path.join(profiles, n) for n in sorted(os.listdir(profiles))
                   if n.endswith(".md")]

for path in candidates:
    if not os.path.isfile(path):
        continue
    line_no = 1
    for para in io.open(path, encoding="utf-8").read().split("\n\n"):
        if para.strip():
            corpus.append((os.path.relpath(path, os.path.dirname(prompts_dir)).replace("\\", "/"),
                           line_no, para, terms(para)))
        line_no += para.count("\n") + 2

if not lessons:
    print("No lessons in %s." % learnings_path)
    raise SystemExit(0)

print("# Does the prompt already say it?")
print()
print("%d lesson(s) against %d passage(s) of base.md and the profiles."
      % (len(lessons), len(corpus)))
print()

flagged = 0
for title, lesson_terms in lessons:
    # Ranked on Jaccard, not on the raw count. A long paragraph shares more
    # terms with everything — ranking on the count alone made one 40-line
    # passage of base.md the "closest" match to three unrelated lessons at once.
    # The count is still what --min-overlap gates on, because a ratio is not a
    # quantity a person can reason about when deciding whether to delete a rule.
    best = None
    for path, line_no, para, para_terms in corpus:
        shared = lesson_terms & para_terms
        union = lesson_terms | para_terms
        score = len(shared) / len(union) if union else 0.0
        if best is None or score > best[0]:
            best = (score, shared, path, line_no, para)
    score, shared, path, line_no, para = best
    if len(shared) < min_overlap:
        print("## %s\n\n  nothing in the prompt comes close (best: %d shared term(s))\n"
              % (title, len(shared)))
        continue
    flagged += 1
    first = " ".join(para.split())[:150]
    print("## %s" % title)
    print()
    print("  %s:%d — %d shared term(s), overlap %.2f: %s"
          % (path, line_no, len(shared), score, ", ".join(sorted(shared))))
    print("  > %s%s" % (first, "…" if len(" ".join(para.split())) > 150 else ""))
    print()

print("---")
print()
if flagged:
    print("%d lesson(s) have a passage above worth reading side by side. Shared" % flagged)
    print("vocabulary is not a restatement — go and read both before deleting one.")
else:
    print("No lesson overlaps the prompt at this threshold. Lower --min-overlap to")
    print("see the near misses.")
PY
