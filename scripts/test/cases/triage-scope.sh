# GUARD 6 — which files an oversized diff still gets reviewed.
#
# The rule lives as python embedded in review.yml's "Compute reviewed file set"
# step, so this case extracts that heredoc and runs the real thing against
# synthetic file lists. Nothing is re-implemented here: a copy of the rule
# would pass while the workflow's own copy was broken, which is the failure
# mode this directory exists to avoid. repo-hygiene.sh reads the same workflow
# with the same tooling — stock python3, no PyYAML.
#
# WHY IT IS WORTH TESTING. Triage used to keep the files whose path matched an
# English risk vocabulary and nothing else. On Aileaneprod/korbyx, a French
# codebase, the run logs show it keeping 2 files of 31 (run 35072472728), 3 of
# 39 (run 34937782439) and 9 of 42 (run 33628523366), and four findings the
# author later confirmed as blocking were in files it dropped. The defect was
# invisible from inside: the step reports how many files it kept, never that
# the thing deciding was a language rather than a risk.
#
# So the case below is written the way that failure would have been caught: a
# diff dominated by files named in French, with one small English-named file
# that the vocabulary does flag.

it "reviews the files an oversized diff is mostly about, whatever they are named"

# --- the rule, lifted out of the workflow ------------------------------------

_extract_triage() {
  python3 - "$SCRIPTS/../.github/workflows/review.yml" "$TESTTMP/triage.py" <<'EXTRACT'
import io
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = io.open(src, encoding="utf-8").read().splitlines()

start = None
for i, line in enumerate(lines):
    if line.strip() == "- name: Compute reviewed file set":
        start = i
        break
if start is None:
    sys.exit("review.yml has no 'Compute reviewed file set' step")

body = None
for i in range(start, len(lines)):
    if lines[i].strip() == "python3 <<'PY'":
        pad = " " * (len(lines[i]) - len(lines[i].lstrip()))
        body = []
        for line in lines[i + 1:]:
            if line.strip() == "PY":
                break
            body.append(line[len(pad):] if line.startswith(pad) else line.lstrip())
        break
if not body:
    sys.exit("no python heredoc under 'Compute reviewed file set'")

io.open(dst, "w", encoding="utf-8", newline="\n").write("\n".join(body) + "\n")
EXTRACT
}

assert_status 0 "the triage rule can be lifted out of review.yml" -- _extract_triage

# --- fixtures ----------------------------------------------------------------
#
# Each scenario is a directory that looks like RUNNER_TEMP at the moment the
# step runs: config.json, all-files.txt, numstat.txt. Every path is invented.
# `max_diff_lines` is small so the fixtures can be, and nothing is excluded —
# exclusion is a separate concern with its own coverage.

_build_fixtures() {
  python3 - <<'BUILD'
import io
import json
import os

root = os.path.join(os.environ["TESTTMP"], "triage")


def scenario(name, files, limit):
    """`files` is (path, added, removed), exactly the numstat columns."""
    path = os.path.join(root, name)
    if not os.path.isdir(path):
        os.makedirs(path)
    with io.open(os.path.join(path, "config.json"), "w", encoding="utf-8") as fh:
        json.dump({"exclude_paths": [], "max_diff_lines": limit}, fh)
    with io.open(os.path.join(path, "all-files.txt"), "w",
                 encoding="utf-8", newline="\n") as fh:
        fh.write("".join("%s\n" % p for p, _, _ in files))
    with io.open(os.path.join(path, "numstat.txt"), "w",
                 encoding="utf-8", newline="\n") as fh:
        fh.write("".join("%d\t%d\t%s\n" % (a, r, p) for p, a, r in files))


# The shape the defect was measured on: big modules named in French, one small
# module named in English that the vocabulary flags, and a tail of small files.
# 35 files, so the budget of 25 actually has to choose.
#
# One of the French files is pure deletion. A change that only removes lines —
# a dropped guard, a deleted test — is exactly what a review should see, and a
# rank that counted additions alone would put it last.
french = [
    ("src/verification/montant-total.ts", 400, 0),
    ("src/verification/calcul-des-remises.ts", 260, 0),
    ("src/verification/etat-des-lieux.ts", 180, 0),
    ("src/verification/controle-supprime.ts", 0, 350),
]
english = [("src/api/query-cache.ts", 12, 0)]
tail = [("src/pages/ecran-%02d.ts" % i, 5, 0) for i in range(30)]
scenario("language", french + english + tail, 500)

# Same diff, under the limit. Triage must not fire and must narrow nothing.
scenario("under-limit", french + english + tail, 100000)

# More flagged files than the budget. The floor is a floor: all of them stay.
flagged = [("src/auth/session-store-%02d.ts" % i, 8, 0) for i in range(30)]
scenario("floor", flagged + [("src/rapport/%02d-tableau-de-bord.ts" % i, 300, 0)
                             for i in range(5)], 500)

# A huge diff that flags nothing at all. Ordered so the biggest files come
# LAST, because the old fallback took the first 25 in git's order and would
# have looked right on a list sorted the other way.
scenario("nothing-flagged",
         [("src/pages/module-%02d.ts" % i, (i + 1) * 10, 0) for i in range(40)],
         500)
BUILD
}

assert_status 0 "the scenarios build" -- _build_fixtures

# --- running it --------------------------------------------------------------

_run() {
  local dir="${TESTTMP}/triage/$1"
  : > "${dir}/github-output"
  ( cd "$dir" \
    && RUNNER_TEMP="$dir" GITHUB_OUTPUT="${dir}/github-output" \
       python3 "$TESTTMP/triage.py" )
}

_reviewed() { cat "${TESTTMP}/triage/$1/reviewed-files.txt" 2>/dev/null; }
_count()    { _reviewed "$1" | grep -c . ; }
_has()      { _reviewed "$1" | grep -qxF "$2" && echo yes || echo no; }

# --- the language scenario ---------------------------------------------------

assert_status 0 "a French-named oversized diff is scoped without error" -- _run language

# Stated as an assertion rather than a comment: if a fixture path ever starts
# matching the vocabulary by accident, the scenario stops testing what it says
# it tests, and this is the line that notices.
assert_contains "risk=1" "exactly one fixture path is risk-flagged" -- _run language

assert_equal "yes" "$(_has language src/verification/montant-total.ts)" \
  "the largest change in the diff is reviewed, though its name is French"
assert_equal "yes" "$(_has language src/verification/calcul-des-remises.ts)" \
  "the second largest is reviewed too"
assert_equal "yes" "$(_has language src/verification/controle-supprime.ts)" \
  "a change that only deletes lines is ranked by the lines it deletes"
assert_equal "yes" "$(_has language src/api/query-cache.ts)" \
  "the risk-flagged file survives as the floor it is"
assert_equal "25" "$(_count language)" \
  "triage still narrows: 35 files kept, 25 reviewed"
assert_equal "no" "$(_has language src/pages/ecran-29.ts)" \
  "and what it drops is the least changed, not the least English"

# --- the floor holds in both directions --------------------------------------

it "never drops a risk-flagged file to make room"

assert_status 0 "a diff with more flagged files than the budget is scoped" -- _run floor
assert_equal "30" "$(_count floor)" \
  "all 30 flagged files are reviewed, budget or no budget"
assert_equal "yes" "$(_has floor src/auth/session-store-29.ts)" \
  "including the last of them"
assert_equal "no" "$(_has floor src/rapport/00-tableau-de-bord.ts)" \
  "and the budget is spent before the unflagged files are reached"

# --- a huge diff that flags nothing still gets looked at ---------------------
#
# The property the comment under the old filter claimed, kept and sharpened:
# the bounded slice is now the 25 biggest files rather than the 25 git happened
# to list first.

it "looks at a huge diff that flags nothing, biggest first"

assert_status 0 "a diff flagging nothing is scoped" -- _run nothing-flagged
assert_contains "risk=0" "nothing in this scenario is risk-flagged" -- _run nothing-flagged
assert_equal "25" "$(_count nothing-flagged)" \
  "a diff with no flagged file is still reviewed, up to the budget"
assert_equal "yes" "$(_has nothing-flagged src/pages/module-39.ts)" \
  "the biggest file is in scope even though git listed it last"
assert_equal "no" "$(_has nothing-flagged src/pages/module-00.ts)" \
  "the smallest is what gets dropped"

# --- and none of this fires below the limit ----------------------------------

it "changes nothing about a diff that is not oversized"

assert_status 0 "an ordinary diff is scoped" -- _run under-limit
assert_contains "triage=False" "the limit is not reached" -- _run under-limit
assert_equal "35" "$(_count under-limit)" \
  "every kept file is reviewed when triage does not fire"
