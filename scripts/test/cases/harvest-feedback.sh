# harvest-feedback.sh — the ledger that decides which reviewer we keep.
#
# The verdict guess is a hint for a human, never a decision — that is written
# above the keyword lists in the script itself, and it stays true. But the hint
# is what propose-learnings.sh counts, and korbyx/CONTRIBUTING.md now MANDATES
# a four-word vocabulary so that counting works at all: Retenu, Écarté, Partiel,
# Vu. The vocabulary exists because 46 verdicts out of 148 had to be re-read by
# hand for lack of a clear first word.
#
# Three of these cases fail against the keyword lists as they were written:
#
#   * `Retenu` appears in no list, so the most frequent verdict — the one that
#     says a finding was GOOD — scored `unknown`.
#   * `Vu` likewise, so a finding that was right and handled elsewhere scored
#     `unknown` too.
#   * The search ran over the whole reply rather than its first word, so
#     "Retenu — le faux positif est sur le point voisin" matched `faux positif`
#     and scored `rejected`: the exact inversion of what the author wrote.
#
# `Vu` maps to `accepted` on purpose. CONTRIBUTING.md defines it as "le constat
# est juste mais traité ailleurs" — a true positive for precision. The nuance is
# not lost: the ledger keeps `human_reply` verbatim.

_out_dir() { printf '%s' "${TMPDIR:-/tmp}/cr-test-harvest"; }
_ledger()  { printf '%s' "$(_out_dir)/test/repo/1.json"; }

_harvest() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 1 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-verdicts.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
}

# _verdict PATH — the verdict_guess recorded for the thread on that file.
_verdict() {
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
m={f['path']:f['verdict_guess'] for f in d['findings']}
print(m.get(sys.argv[2],'ABSENT'))
" "$(_ledger)" "$1"
}

_field() {
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
m={f['path']:f for f in d['findings']}
print(m.get(sys.argv[2],{}).get(sys.argv[3],'ABSENT'))
" "$(_ledger)" "$1" "$2"
}

_harvest

# --- the four words CONTRIBUTING.md mandates ---------------------------------

it "reads Retenu as accepted"
assert_equal "accepted" "$(_verdict a.ts)" "« **Retenu**. » is the author saying the finding was good"

it "reads Vu as accepted"
assert_equal "accepted" "$(_verdict b.ts)" "« Vu — … » is a true positive handled elsewhere"

it "reads Écarté as rejected"
assert_equal "rejected" "$(_verdict d.ts)" "« Écarté : … » is a rejection"

it "reads Partiel as partial"
assert_equal "partial" "$(_verdict e.ts)" "« Partiel, … » is half credit"

# --- the first word decides, not the rest of the sentence --------------------

it "does not let a later word overturn the verdict"
assert_equal "accepted" "$(_verdict c.ts)" \
  "« Retenu — le faux positif est sur le point voisin » is an acceptance, not a rejection"

it "accepts Ecarté written without the first accent"
assert_equal "rejected" "$(_verdict f.ts)" "« Ecarté, … » is still a rejection"

# --- the shapes that must keep working ---------------------------------------

it "records a thread nobody answered as no_reply"
assert_equal "no_reply" "$(_verdict g.ts)" "an unanswered finding is not a verdict"

it "ignores threads a human opened"
assert_equal "ABSENT" "$(_verdict h.ts)" "a human-initiated thread is not our finding to score"

it "anchors the finding to the commit it was made on"
assert_equal "deadbeef1234" "$(_field a.ts reviewed_commit)" \
  "the SHA comes from the REST payload, not from the branch tip"

it "keeps the author's own words alongside the guess"
assert_equal "**Retenu**." "$(_field a.ts human_reply)" "the verbatim reply survives the guess"

# --- "we reviewed and had nothing to say" is not "we never ran" ---------------
#
# The ledger recorded a reviewer's presence only through inline comments, and
# this harvester fetched only reviewThreads — never issue comments. So a review
# that completed and found nothing left NO trace, and report.sh's miss heuristic
# ("they found it, we said nothing on that pull request") counted every blocking
# finding of theirs on such a pull request as ours to answer for.
#
# That is not hypothetical. On Aileaneprod/korbyx#92 our reviewer ran three
# times, posted a reasoned 0/0/0 summary that read the Terraform, the migration
# and the README — and the ledger holds zero findings from us for that pull
# request. Five of the seven "blocking findings only they caught" sit on pull
# requests of exactly this shape.
#
# The sticky summary carries `<!-- claude-review:summary -->`, posted by
# post-review.sh. It is the one artefact that says we were there.

_silent() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 92 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-ours-silent.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d.get(sys.argv[2], 'ABSENT'))
" "$(_out_dir)/test/repo/92.json" "$1"
}

it "records that our reviewer was there even when it filed nothing"
assert_equal "True" "$(_silent reviewed_by_ours)" "the sticky summary is proof we ran"
assert_equal "2026-09-04T16:31:00Z" "$(_silent our_summary_at)" "and when it was posted"

it "does not mistake anyone else's comment for our summary"
# Same shape, but the only issue comment is the competitor's walkthrough.
# A marker check that cannot say no is not a check.
_silent_none() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 93 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-nobody-of-ours.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d.get('reviewed_by_ours', 'ABSENT'))
" "$(_out_dir)/test/repo/93.json"
}
assert_equal "False" "$(_silent_none)" "no marker, no claim that we were there"

it "will not let anyone but our own poster claim we were there"
# The marker is a plain string in a public comment thread. Anybody can type it,
# and the people most likely to are the ones discussing this tool — the pull
# request that added this check quotes it three times in its own body. A
# presence flag a passer-by can set is not evidence.
_impostor() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 94 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-marker-from-a-human.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d.get('reviewed_by_ours','ABSENT'))
" "$(_out_dir)/test/repo/94.json"
}
assert_equal "False" "$(_impostor)" "a human quoting the marker is not our review"

it "says so when it could not see every comment"
# `comments(first:100)` reads one page. The highest count on korbyx today is 16,
# so this is not a live problem — but the failure mode is a SILENT loss of the
# only evidence that our reviewer was present, and the ledger's whole purpose is
# to not be quietly wrong. It is cheaper to say "I did not look at all of them"
# than to discover later that a number was built on a partial read.
_truncated() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 95 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-many-comments.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" 2>&1 >/dev/null
}
assert_contains "only the first" "a partial read is reported, not assumed complete" -- _truncated
