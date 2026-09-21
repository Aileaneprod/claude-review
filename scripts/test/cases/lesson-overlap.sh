# lesson-overlap.sh ranks candidates for a human to delete. Two ways it could
# be worse than useless, and a case for each.
#
#   * It misses a restatement. Then the file keeps paying for a rule the prompt
#     already gives — 703 bytes of one, read on every review of every
#     repository, is what prompted this script.
#   * It points at an unrelated passage and someone deletes a lesson on its
#     say-so. The header calls these candidates, not verdicts, and the ranking
#     has to earn that: a real restatement must score clearly above the noise,
#     or "read them side by side" is advice nobody can act on.
#
# Everything here runs against a synthetic prompt in $TESTTMP. Running it
# against the repository's own prompt would assert today's wording, which is
# the one thing about this that is expected to change.

_LO="$SCRIPTS/lesson-overlap.sh"
_ROOT="$TESTTMP/overlap"

# _tree — a prompt with one paragraph worth restating and one unrelated.
_tree() {
  rm -rf "$_ROOT"
  mkdir -p "$_ROOT/prompts/profiles"
  cat > "$_ROOT/prompts/base.md" <<'EOF'
# Base

Then read the pull request body a second time, as a checklist. Enumerate what
the change promises — the ticket's acceptance criteria, the stated guarantees —
and tick each promise against the code that arrived.

Findings about formatting belong nowhere. Whitespace, import ordering and
quote style are settled by the repository's own tooling, never by a reviewer.
EOF
  cat > "$_ROOT/prompts/profiles/generic.md" <<'EOF'
# Generic

Prefer guards on a migration. A migration that already carries them is correct
and flagging it is a false positive.
EOF
}

_run() { "$_LO" --learnings "$_ROOT/learnings.md" --prompts "$_ROOT/prompts" "$@" 2>&1; }

# --- arguments ---------------------------------------------------------------

it "refuses what it cannot read"
assert_contains "no learnings file" "says which file is missing" -- \
  "$_LO" --learnings "$TESTTMP/does-not-exist.md"
assert_contains "whole number" "rejects a threshold that is not one" -- \
  "$_LO" --min-overlap seven

# --- it finds a restatement --------------------------------------------------

it "names the passage a lesson restates"
_tree
cat > "$_ROOT/learnings.md" <<'EOF'
# Learnings

## Enumerate the promises and tick each one against the code

Read the pull request body as a checklist: enumerate what the change promises,
the acceptance criteria and the stated guarantees, and tick each promise
against the code that arrived.

**Evidence:** Aileaneprod/korbyx#38, a criterion the body stated and the code
did not meet.
EOF
assert_contains "prompts/base.md:3" "points at the paragraph, with its line" -- _run
assert_contains "checklist" "and names a term they share" -- _run

# The evidence block must not count. It carries repository names and quoted
# replies that the base prompt cannot restate, so including it would dilute
# every score toward zero and make every lesson look unique — the one answer
# this tool must never give by construction.
it "compares the rule, not the evidence that earned it"
_tree
cat > "$_ROOT/learnings.md" <<'EOF'
# Learnings

## Enumerate the promises and tick each one against the code

Read the pull request body as a checklist: enumerate what the change promises,
the acceptance criteria and the stated guarantees, and tick each promise
against the code that arrived.

**Evidence:** findings about formatting belong nowhere; whitespace, import
ordering and quote style are settled by the repository's own tooling, never by
a reviewer. Formatting, whitespace, ordering, tooling, settled, repository,
reviewer, belong, nowhere, style, quote, import.
EOF
assert_contains "prompts/base.md:3" "the evidence's borrowed vocabulary does not move the match" -- _run

# --- and it does not invent one ----------------------------------------------

it "says plainly when nothing in the prompt comes close"
_tree
cat > "$_ROOT/learnings.md" <<'EOF'
# Learnings

## Chronometer drift invalidates a latency histogram

When a benchmark reports percentiles, confirm the clock source survived the
process boundary, because a drifting chronometer silently reshapes the tail.

**Evidence:** none yet.
EOF
assert_contains "nothing in the prompt comes close" "no match is reported as no match" -- _run
assert_not_contains "shared term(s), overlap" "and nothing is offered as a candidate" -- _run

# --- the ranking has to separate signal from length --------------------------
#
# Ranked on the raw count of shared terms, the longest paragraph in the corpus
# wins against everything: on the repository's own prompt one 40-line passage
# came back as the closest match to three unrelated lessons at once. Jaccard
# fixed it. This asserts the property, not the implementation: a restatement
# must outrank a long unrelated paragraph that merely shares common words.

it "ranks a short restatement above a long paragraph of common words"
_tree
cat >> "$_ROOT/prompts/base.md" <<'EOF'

This paragraph exists to be long and to contain every word the lesson uses,
without saying anything: request, checklist, enumerate, change, promises,
acceptance, criteria, stated, guarantees, promise, against, arrived, and also
documented, invariant, ledger, harvest — which the restatement does not. Then
filler, at length, so that its vocabulary dwarfs the passage that actually
restates the rule: tooling, whitespace, ordering, reviewer, repository,
formatting, settled, migration, flagging, positive, carries, correct, prefer,
guards, latency, histogram, chronometer, percentile, boundary, drifting,
silently, reshapes, benchmark, process, source, confirm, survived, reports.
EOF
cat > "$_ROOT/learnings.md" <<'EOF'
# Learnings

## Enumerate the promises and tick each one against the code

Read the pull request body as a checklist: enumerate what the change promises,
the acceptance criteria and the stated guarantees, and tick each promise
against the code that arrived. A documented invariant is a promise, and so is
anything the ledger's harvest recorded as one.

**Evidence:** Aileaneprod/korbyx#38.
EOF
assert_contains "prompts/base.md:3" "the restatement still wins" -- _run
assert_not_contains "documented, enumerate" "the long bag of words does not" -- _run

# --- three defects the other reviewer found, after this file was merged -------
#
# All three were in the first version, and all three are the same shape as the
# bugs this repository spent two days removing from its own measurements: an
# input check that admits the value it exists to reject, a threshold applied
# after the decision instead of before it, and a missing state reported as a
# clean answer.

it "refuses an empty threshold instead of crashing on it"
# `*[!0-9]*` admits the empty string — it holds no non-digit character — and the
# empty string reached int("") and a python traceback. report.sh already carried
# a case for exactly this on --since.
assert_contains "empty value" "an empty --min-overlap is named, not traced back" -- \
  "$_LO" --min-overlap ""
assert_not_contains "Traceback" "and python is never the one reporting it" -- \
  "$_LO" --min-overlap ""

it "applies the threshold before the ranking, not after the winner is picked"
# The bug: rank everything on Jaccard, then test the winner against the
# threshold. A two-term passage with a high score beat a three-term passage with
# a low one, was rejected at three, and the tool answered "nothing comes close"
# while a qualifying passage sat in the corpus — under-reporting, which is the
# one direction this tool must not fail in.
rm -rf "$_ROOT"; mkdir -p "$_ROOT/prompts"
printf '# Base\n\nalpha bravo\n\nalpha bravo charlie kilo lima mike november oscar\n' \
  > "$_ROOT/prompts/base.md"
printf '# L\n\n## Test\n\nalpha bravo charlie delta echo.\n' > "$_ROOT/learn.md"
_run3() { "$_LO" --learnings "$_ROOT/learn.md" --prompts "$_ROOT/prompts" --min-overlap 3 2>&1; }
assert_contains "3 shared term(s)" "the qualifying passage is found" -- _run3
assert_not_contains "nothing in the prompt comes close" \
  "and a higher-scoring passage below the threshold does not hide it" -- _run3

it "says a corpus is empty rather than calling it no overlap"
rm -rf "$_ROOT"; mkdir -p "$_ROOT/prompts"
printf '# L\n\n## Test\n\nalpha bravo charlie delta echo.\n' > "$_ROOT/learn.md"
_run4() { "$_LO" --learnings "$_ROOT/learn.md" --prompts "$_ROOT/prompts" 2>&1; }
assert_contains "nothing to compare against" "an empty prompt is a configuration error" -- _run4
assert_not_contains "Traceback" "and not an unpacked None" -- _run4
