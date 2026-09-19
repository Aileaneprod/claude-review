# A decoy keyword that is lifted verbatim out of its own fixture's diff cannot
# tell "flagged the decoy" from "quoted the decoy while explaining the real
# defect". It scores the second as the first, so a correct finding is converted
# into a false positive and the fixture cannot pass.
#
# The two halves that collide:
#
#   * prompts/base.md rule 1 REQUIRES `evidence` to be the exact offending
#     line(s) — a verbatim quote of the code;
#   * run-eval.sh matches must_not_find with subject_only=True, whose haystack
#     is title + evidence. It drops why_it_matters and suggested_fix precisely
#     so that naming a decoy by way of contrast is not punished — but evidence
#     is a quote, and a quote carries its neighbours.
#
# So `"any_of": ["IF NOT EXISTS"]` on 10-generic-migration fails any reviewer
# whose evidence includes the guarded CREATE line, which is two lines above the
# DELETE it is right to flag. That fixture failed the gate on 2026-08-05 and
# again, identically, on 2026-09-18, both times on one decoy hit. Six live
# samples taken afterwards all read the guard correctly and all named it in
# why_it_matters, where the matcher cannot see it; the difference between pass
# and fail was which field the words landed in, not what the reviewer thought.
# 25 of the ~50 decoy keywords were in this state across ten of eleven fixtures.
#
# The invariant is mechanical and needs no model call: a must_not_find keyword
# must express the wrong ASSERTION ("missing if not exists", "in list_products",
# "never unsubscribed"), never a string the correct answer is obliged to quote.
# Code cannot state an assertion, so a keyword that is absent from the diff is
# one the reviewer can only produce by writing a claim about the decoy.
#
# must_find is deliberately NOT held to this. Its keywords are supposed to quote
# the defect — "time.sleep", "to_list(None)", "STRIPE_SECRET_KEY" — and the
# asymmetry is the point: an expectation may quote the change, a prohibition may
# not. docs/TUNING.md states the one hazard that does apply to must_find (a
# keyword that also appears in the DECOY's legitimate code makes the fixture
# unable to fail), and that is a different string, not mechanically derivable
# from the diff. The last assertion below pins the exemption so nobody "fixes"
# it later by symmetry.

it "keeps every decoy keyword out of its own fixture's diff"

# Takes a repo root so the same scanner runs over this repository and over the
# synthetic tree below. A guard proved only against files that already comply
# has never been shown to see anything.
_decoys_quoting_their_diff() {
  python3 - "$1" <<'PY'
import glob
import io
import json
import os
import sys

root = sys.argv[1]
offenders = []

for path in sorted(glob.glob(os.path.join(root, "eval", "expected", "*.json"))):
    name = os.path.basename(path)[:-len(".json")]
    diff_path = os.path.join(root, "eval", "fixtures", name, "changes.diff")
    if not os.path.isfile(diff_path):
        offenders.append("%s: no changes.diff" % name)
        continue
    diff = io.open(diff_path, encoding="utf-8").read().lower()

    expected = json.load(io.open(path, encoding="utf-8"))
    for entry in expected.get("must_not_find") or []:
        for keyword in entry.get("any_of") or []:
            # "*" is "any finding here is wrong" — it matches no text.
            if keyword == "*":
                continue
            if keyword.lower() in diff:
                offenders.append("%s/%s: %r" % (name, entry.get("id"), keyword))

print("; ".join(offenders))
PY
}

_repo_root="$(cd -- "$SCRIPTS/.." && pwd)"
assert_equal "" "$(_decoys_quoting_their_diff "$_repo_root")" \
  "no must_not_find keyword is a substring of its own changes.diff"

# --- the guard has to be able to see one ------------------------------------

it "sees a decoy keyword lifted out of the diff"

_probe_root="$TESTTMP/decoy-keywords"
mkdir -p "$_probe_root/eval/fixtures/99-probe" "$_probe_root/eval/expected"
cat >"$_probe_root/eval/fixtures/99-probe/changes.diff" <<'DIFF'
--- /dev/null
+++ b/migrations/0099_probe.sql
@@ -0,0 +1,2 @@
+CREATE INDEX IF NOT EXISTS idx_probe ON probe (seen_at);
+DELETE FROM probe WHERE seen_at < now();
DIFF

_probe_expected() { cat >"$_probe_root/eval/expected/99-probe.json"; }

_probe_expected <<'JSON'
{
  "must_find": [{"id": "real", "path": "migrations/0099_probe.sql", "any_of": ["DELETE FROM"]}],
  "must_not_find": [
    {"id": "decoy", "path": "migrations/0099_probe.sql",
     "any_of": ["CREATE INDEX", "missing if not exists", "*"]}
  ]
}
JSON
assert_equal "99-probe/decoy: 'CREATE INDEX'" \
  "$(_decoys_quoting_their_diff "$_probe_root")" \
  "a keyword copied from the diff is named, and the prose one beside it is not"

# Case matters: the scorer lowercases both sides, so the guard must too.
it "reads the keyword case-insensitively, as the scorer does"
_probe_expected <<'JSON'
{
  "must_not_find": [
    {"id": "decoy", "path": "migrations/0099_probe.sql", "any_of": ["create index if not exists"]}
  ]
}
JSON
assert_equal "99-probe/decoy: 'create index if not exists'" \
  "$(_decoys_quoting_their_diff "$_probe_root")" \
  "lowercase keyword against an uppercase diff is still an offender"

it "leaves an assertion-shaped decoy alone"
_probe_expected <<'JSON'
{
  "must_not_find": [
    {"id": "decoy", "path": "migrations/0099_probe.sql",
     "any_of": ["add if not exists", "index already exists", "create index will fail"]}
  ]
}
JSON
assert_equal "" "$(_decoys_quoting_their_diff "$_probe_root")" \
  "keywords that state the wrong claim pass"

# --- must_find is exempt, on purpose -----------------------------------------
#
# Not decoration: if this ever reads 0, someone has applied the rule above to
# must_find and the fixtures have stopped naming the defect they plant.

it "still lets must_find quote the defect it plants"

_must_find_keywords_quoting_the_diff() {
  python3 - "$1" <<'PY'
import glob
import io
import json
import os
import sys

root = sys.argv[1]
quoting = 0

for path in sorted(glob.glob(os.path.join(root, "eval", "expected", "*.json"))):
    name = os.path.basename(path)[:-len(".json")]
    diff_path = os.path.join(root, "eval", "fixtures", name, "changes.diff")
    if not os.path.isfile(diff_path):
        continue
    diff = io.open(diff_path, encoding="utf-8").read().lower()
    expected = json.load(io.open(path, encoding="utf-8"))
    for entry in expected.get("must_find") or []:
        for keyword in entry.get("any_of") or []:
            if keyword != "*" and keyword.lower() in diff:
                quoting += 1

print("quoting" if quoting else "none")
PY
}

assert_equal "quoting" "$(_must_find_keywords_quoting_the_diff "$_repo_root")" \
  "at least one must_find keyword is a verbatim quote of its diff"
