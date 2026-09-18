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

# --- harvesting must not destroy what classifying added ----------------------
#
# harvest-feedback.sh rewrites the whole document from the API response, so every
# field a later pass added — `key`, `verdict_llm`, `verdict_keyword`, and any
# `verdict_human` correction — vanished the next time the pull request was
# touched. harvest.yml runs harvest and then classify daily, on everything
# updated in the last three days, so a pull request that keeps receiving comments
# was re-classified from scratch every morning: LLM calls re-spent, and verdicts
# free to flip between runs on the page that decides.
#
# Found by re-harvesting the whole ledger locally: 44 findings that carried a
# model verdict came back `unknown`, and the precision figure moved for a reason
# that had nothing to do with the reviewer.

_reharvest_keeps() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 1 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-verdicts.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  # A classifier pass lands afterwards and writes its own fields. Each finding
  # gets a DISTINCT verdict: with the same value everywhere, a carry-over that
  # matched the wrong finding would still count right. Raised by CodeRabbit on
  # the pull request that added this case.
  python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
for i, f in enumerate(d['findings']):
    f['verdict_llm']='verdict-%d' % i
    f['key']='test/repo#1|%s|%s|%d' % (f.get('path'), f.get('line'), i)
json.dump(d, open(p,'w',encoding='utf-8'), indent=2, ensure_ascii=False)
" "$(_ledger)"
  # Then the pull request is touched again and re-harvested.
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 1 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-verdicts.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  # Each finding must have kept ITS OWN verdict, in its own position.
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
fs=d['findings']
right=sum(1 for i,f in enumerate(fs) if f.get('verdict_llm')=='verdict-%d' % i)
print(right, 'of', len(fs))
" "$(_ledger)"
}

it "keeps the verdicts a classifier pass already wrote"
assert_contains "7 of 7" "re-harvesting does not throw the model verdicts away" -- _reharvest_keeps

it "still accepts the suffixed spelling the REST API returns"
# The fixture above uses the GraphQL spelling, which is what this script reads —
# so nothing exercised the `[bot]` removal any more. Raised by CodeRabbit on the
# pull request that introduced it.
_suffixed() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 96 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-ours-silent-suffixed.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d.get('reviewed_by_ours','ABSENT'))
" "$(_out_dir)/test/repo/96.json"
}
assert_equal "True" "$(_suffixed)" "github-actions[bot] is the same account"

it "will not let a HUMAN account named claude claim we were there"
# The suffix is not the discriminant, and `claude` is not a hypothetical login:
# `gh api users/claude` returns type `User`, created 2009-05-07. Comparing the
# bare login moved the spoofing this guard exists to stop from the marker text to
# the account name — a passer-by with that name sets the presence flag. The
# fixture below is the silent-summary shape with one thing changed: the poster is
# that human. `__typename` is the one property they cannot hold.
_human_named_claude() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 97 --out "$(_out_dir)"     --threads-file "$FIXTURES/threads-marker-from-a-human-named-claude.json"     --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
print(d.get('reviewed_by_ours','ABSENT'))
" "$(_out_dir)/test/repo/97.json"
}
assert_equal "False" "$(_human_named_claude)" "the account type decides, not the name"

it "keeps the verdicts when a later commit SHIFTS the lines"
# The case above re-harvests the same fixture, so the diff never moves and the
# carry-over key is never actually tested. `line` is the position in the CURRENT
# diff: GitHub re-anchors it when a commit shifts the code and nulls it once the
# thread goes outdated. harvest.yml harvests everything touched in the last three
# days, i.e. exactly the pull requests receiving commits.
#
# Measured before the fix: a three-line shift carried 0 of 7 verdicts. On korbyx,
# 4 of 17 live threads already have `line` different from `original_line`.
# `verdict_human` wins in report.sh and nothing regenerates it.
_reharvest_after_shift() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 2 --out "$(_out_dir)"     --threads-file "$FIXTURES/threads-verdicts.json"     --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
for i, f in enumerate(d['findings']):
    f['verdict_llm']='verdict-%d' % i
    f['verdict_human']='Retenu-%d' % i
    f['verdict_keyword']='keyword-%d' % i
json.dump(d, open(p,'w',encoding='utf-8'), indent=2, ensure_ascii=False)
" "$(_out_dir)/test/repo/2.json" || return 1
  # A commit lands and shifts every thread down three lines. Same file, same
  # finding text, new position — which is what GitHub returns after a push.
  #
  # The fixture is opened BY THE SHELL and piped, never handed to python as a
  # path: $FIXTURES is a POSIX path and the python on some developer machines is
  # a native Windows build that cannot open it. The first version of this case
  # did pass the path, the shift failed silently under `>/dev/null`, and the
  # assertion then re-read an UNTOUCHED document and went green — under the
  # mutant too. Which is this pull request's own title, one directory across.
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['repository']['pullRequest']['reviewThreads']['nodes']:
    if isinstance(t.get('line'), int):
        t['line'] = t['line'] + 3
json.dump(d, sys.stdout, indent=2, ensure_ascii=False)
" <"$FIXTURES/threads-verdicts.json" >"$(_out_dir)/shifted.json" || return 1
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 2 --out "$(_out_dir)"     --threads-file "$(_out_dir)/shifted.json"     --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  # The shifted lines are printed with the counts, so a shift that did not
  # happen cannot be mistaken for a carry-over that worked.
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
fs=d['findings']
llm=sum(1 for i,f in enumerate(fs) if f.get('verdict_llm')=='verdict-%d' % i)
hum=sum(1 for i,f in enumerate(fs) if f.get('verdict_human')=='Retenu-%d' % i)
kw=sum(1 for i,f in enumerate(fs) if f.get('verdict_keyword')=='keyword-%d' % i)
print('lines', ','.join(str(f.get('line')) for f in fs),
      '- llm', llm, 'of', len(fs), '- human', hum, 'of', len(fs),
      '- keyword', kw, 'of', len(fs))
" "$(_out_dir)/test/repo/2.json"
}
assert_contains "lines 13,23,33,43,53,63,73 - llm 7 of 7 - human 7 of 7 - keyword 7 of 7"   "a shifted line does not lose a verdict" -- _reharvest_after_shift

it "keeps the cache stamp, not just the verdict it stamps"
# classify-verdicts.sh caches on `finding.get("verdict_llm_key") == digest`, so a
# verdict carried over WITHOUT its stamp reads as uncached and buys a fresh model
# call on every already-classified finding — the exact cost the carry-over exists
# to avoid, reopened through the one field it forgot. A repeated call can also
# return a different verdict, so the flip this PR closes comes back too.
_reharvest_keeps_stamp() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 3 --out "$(_out_dir)"     --threads-file "$FIXTURES/threads-verdicts.json"     --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
for i, f in enumerate(d['findings']):
    f['verdict_llm']='v-%d' % i
    f['verdict_llm_key']='stamp-%d' % i
    f['verdict_llm_quote']='quote-%d' % i
json.dump(d, open(p,'w',encoding='utf-8'), indent=2, ensure_ascii=False)
" "$(_out_dir)/test/repo/3.json"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 3 --out "$(_out_dir)"     --threads-file "$FIXTURES/threads-verdicts.json"     --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
fs=d['findings']
k=sum(1 for i,f in enumerate(fs) if f.get('verdict_llm_key')=='stamp-%d' % i)
q=sum(1 for i,f in enumerate(fs) if f.get('verdict_llm_quote')=='quote-%d' % i)
print('stamp', k, 'of', len(fs), '- quote', q, 'of', len(fs))
" "$(_out_dir)/test/repo/3.json"
}
assert_contains "stamp 7 of 7 - quote 7 of 7" "the stamp travels with the verdict" -- _reharvest_keeps_stamp

# --- a human's ruling has to outlive the harvest that wrote the finding -------
#
# `severity_human`, `ruled_by` and `ruling` are the fields report.sh reads to
# let a person overrule the classifier — see its header. They are the only
# fields in this document a HUMAN writes by hand, into a file every other field
# of which this script rebuilds from the API on the next run, and harvest.yml
# runs on everything touched in the last three days: that is, precisely the pull
# requests still receiving commits, where a ruling is most likely to be written.
#
# A hand-written field the next harvest erases is worse than no field at all.
# The person who wrote it has no way of knowing it is gone; the page silently
# goes back to the classifier's answer; and unlike a model verdict, nothing can
# regenerate it. `verdict_human` was already carried here for exactly that
# reason, and its three companions have to travel with it or the ruling arrives
# half-applied — a severity ruling lost while the verdict beside it survives is
# the page reporting a judgement nobody made.
#
# The lines are SHIFTED between the two harvests, as a commit would shift them,
# because the carry-over is keyed on (path, digest of the finding text) and a
# fixture that never moves would not test that at all.
_reharvest_keeps_a_ruling() {
  rm -rf "$(_out_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 4 --out "$(_out_dir)" \
    --threads-file "$FIXTURES/threads-verdicts.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  # A human reads the thread and rules on it. Distinct values per finding, so a
  # carry-over that matched the wrong finding cannot still count as right.
  python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
for i, f in enumerate(d['findings']):
    f['verdict_human']='accepted-%d' % i
    f['severity_human']='important-%d' % i
    f['ruled_by']='ruler-%d' % i
    f['ruling']='because-%d' % i
json.dump(d, open(p,'w',encoding='utf-8'), indent=2, ensure_ascii=False)
" "$(_out_dir)/test/repo/4.json" || return 1
  # The fixture is opened BY THE SHELL and piped: $FIXTURES is a POSIX path and
  # the python on some developer machines is a native Windows build that cannot
  # open it. See the neighbouring case for what a silent failure here costs.
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['repository']['pullRequest']['reviewThreads']['nodes']:
    if isinstance(t.get('line'), int):
        t['line'] = t['line'] + 3
json.dump(d, sys.stdout, indent=2, ensure_ascii=False)
" <"$FIXTURES/threads-verdicts.json" >"$(_out_dir)/shifted-ruling.json" || return 1
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 4 --out "$(_out_dir)" \
    --threads-file "$(_out_dir)/shifted-ruling.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
fs=d['findings']
def kept(field, shape):
    return sum(1 for i,f in enumerate(fs) if f.get(field)==shape % i)
print('lines', ','.join(str(f.get('line')) for f in fs),
      '- verdict', kept('verdict_human','accepted-%d'), 'of', len(fs),
      '- severity', kept('severity_human','important-%d'), 'of', len(fs),
      '- by', kept('ruled_by','ruler-%d'), 'of', len(fs),
      '- why', kept('ruling','because-%d'), 'of', len(fs))
" "$(_out_dir)/test/repo/4.json"
}

it "keeps a ruling a human wrote by hand, all four fields of it"
assert_contains "lines 13,23,33,43,53,63,73 - verdict 7 of 7 - severity 7 of 7 - by 7 of 7 - why 7 of 7" \
  "a re-harvest does not erase a judgement nothing can regenerate" -- _reharvest_keeps_a_ruling

# --- reading back what our own prompt told the reviewer not to raise ---------
#
# post-review.sh --mode pre hands the reviewer an "already known" block whose
# `theirs` section says, of every finding the other reviewer or a human posted
# first, "do not post an inline comment on any of them". `post` writes what it
# suppressed into the ledger blob of the sticky comment — version 2,
# {path, key, severity, by, concurred} — and NOTHING read it. So report.sh went
# on publishing "author-confirmed blocking findings of theirs we did not raise"
# with no way of saying which of them our own instruction had forbidden.
#
# `key` is sha256(the thread's opening comment)[:8], which is exactly what
# finding_key() digests, so the join needs no new identifier. This file already
# reads that comment's body for the presence flag, so it needs no new API call
# either.

_supp_dir() { printf '%s' "$TESTTMP/cr-test-suppressed"; }

# _supp FIXTURE PR — harvest one fixture and print, per path, the two flags.
_supp() {
  rm -rf "$(_supp_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr "$2" --out "$(_supp_dir)" \
    --threads-file "$FIXTURES/$1" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
for f in d['findings']:
    print('%s suppressed=%s concurred=%s by=%s' % (
        f['path'], f.get('suppressed_at_review', 'ABSENT'),
        f.get('suppressed_concurred', 'ABSENT'), f.get('suppressed_by', 'ABSENT')))
print('record=%s' % json.dumps(d.get('suppressed_by_us', 'ABSENT'), sort_keys=True))
" "$(_supp_dir)/test/repo/$2.json"
}

_supp_record() { _supp threads-suppressed-record.json 200; }

it "marks the findings our own prompt told the reviewer to leave alone"
assert_contains "src/pay.ts suppressed=True concurred=False by=coderabbitai" \
  "the record joins the finding on (path, digest of the opening comment)" -- _supp_record

it "carries the reviewer's own judgement of a suppressed finding"
assert_contains "src/queue.ts suppressed=True concurred=True by=coderabbitai" \
  "the summary said this one is blocking, and the flag survives the harvest" -- _supp_record

it "leaves a finding nobody suppressed unmarked"
assert_contains "src/free.ts suppressed=ABSENT" \
  "absent is not False: only a record makes the claim" -- _supp_record

it "keeps the whole record, including a suppression whose thread is gone"
# A thread deleted or lost to a force-push leaves no finding to flag, and the
# record is then the only evidence that the reviewer was ever told to leave it
# alone. Dropping the unmatched entries would make the instruction look smaller
# than it was, in exactly the direction that flatters us.
assert_contains '"path": "src/gone.ts"' \
  "an entry matching no thread is still on the document" -- _supp_record

it "does not read a ledger written before the record as an empty record"
# Version 1 says NOTHING about suppression; version 2 with an empty list says
# this run suppressed nothing. A reader that cannot tell them apart reports
# "we suppressed nothing" for every pull request reviewed before 2026-09-18.
_supp_versions() {
  printf 'v2 %s\n' "$(_supp threads-suppressed-record.json 200 | grep '^src/pay.ts')"
  printf 'v1 %s\n' "$(_supp threads-suppressed-v1.json 201 | grep 'record=')"
}
assert_contains "v1 record=\"ABSENT\"" \
  "a version 1 ledger leaves the field off the document entirely" -- _supp_versions
assert_contains "v2 src/pay.ts suppressed=True" \
  "while a version 2 ledger on the same threads marks them" -- _supp_versions

it "takes the record off our own sticky comment and nobody else's"
# The marker is a plain string and the blob is base64 anybody can paste. This
# record decides which findings of theirs stop counting against our reviewer,
# so a passer-by who can write it can retire the criterion. The fixture has two
# comments carrying the marker: a human's, listing src/pay.ts, and ours,
# listing src/queue.ts.
_supp_impostor() { _supp threads-suppressed-impostor.json 202; }
assert_contains "src/pay.ts suppressed=ABSENT" \
  "a human's paste of the blob suppresses nothing" -- _supp_impostor
assert_contains "src/queue.ts suppressed=True" \
  "and our own comment in the same thread is still read" -- _supp_impostor

it "re-derives the flags every harvest instead of carrying them over"
# They are NOT in CARRIED_OVER, and that is the point. The carry-over fires on
# `kept.get(field) is not None and finding.get(field) is None` — precisely the
# shape of a flag written only when true — so a suppression that a later run
# corrected, or a sticky comment a human edited, would keep a True nothing on
# the pull request supports any more. The verdicts in CARRIED_OVER cannot be
# regenerated; these can, from the comment, on every single harvest.
_supp_reharvest() {
  rm -rf "$(_supp_dir)"
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 203 --out "$(_supp_dir)" \
    --threads-file "$FIXTURES/threads-suppressed-record.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  first="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
print([f.get('suppressed_at_review', 'ABSENT') for f in d['findings']
       if f['path'] == 'src/pay.ts'][0])
" "$(_supp_dir)/test/repo/203.json")" || return 1
  # The record is corrected: the same pull request, re-reviewed by a run whose
  # ledger no longer holds that entry.
  "$SCRIPTS/harvest-feedback.sh" --repo test/repo --pr 203 --out "$(_supp_dir)" \
    --threads-file "$FIXTURES/threads-suppressed-v1.json" \
    --rest-file "$FIXTURES/rest-verdicts.json" >/dev/null 2>&1 || return 1
  second="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
print([f.get('suppressed_at_review', 'ABSENT') for f in d['findings']
       if f['path'] == 'src/pay.ts'][0])
" "$(_supp_dir)/test/repo/203.json")" || return 1
  printf 'first %s then %s\n' "$first" "$second"
}
assert_contains "first True then ABSENT" \
  "a record that is no longer written is no longer claimed" -- _supp_reharvest
