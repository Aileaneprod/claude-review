# report.sh — the page that decides whether CodeRabbit gets switched off.
#
# It shipped with no tests while every sibling script had them, and its own
# reviewer said so. That matters more here than elsewhere: this is arithmetic
# nobody re-does by hand, feeding a decision nobody re-litigates. A precision
# column that is quietly wrong is worse than no column, because it will be
# believed.

_led() { printf '%s' "$TESTTMP/report-ledger"; }

# _seed <<'JSON' — one PR document, written to the ledger.
_seed() {
  rm -rf "$(_led)"; mkdir -p "$(_led)/Aileaneprod/korbyx"
  python3 -c "
import json, sys
json.dump(json.loads(sys.stdin.read()), open(sys.argv[1], 'w', encoding='utf-8'))
" "$(_led)/Aileaneprod/korbyx/1.json"
}

_finding() {
  # reviewer verdict severity  -> one finding object
  python3 -c "
import json, sys
sev = {'blocking': '🔴 Blocking', 'important': '🟠 Important', 'nit': '🟡 Nit'}[sys.argv[3]]
print(json.dumps({'reviewer': sys.argv[1], 'path': 'a.ts', 'line': 1,
                  'finding': sev + ' — a claim ' + sys.argv[4],
                  'author_reply': 'x', 'verdict_keyword': sys.argv[2]}))
" "$@"
}

_report() { "$SCRIPTS/report.sh" --ledger "$(_led)" "$@"; }

# --- precision arithmetic -----------------------------------------------------

it "counts accepted, half-credits partial, and divides by what was judged"
# 2 accepted + 1 partial + 1 rejected -> (2 + 0.5) / 4 = 0.62
python3 -c "
import json, sys
def f(rev, verdict, sev, tag):
    s = {'blocking': '🔴 Blocking', 'important': '🟠 Important'}[sev]
    return {'reviewer': rev, 'path': 'a.ts', 'line': 1,
            'finding': s + ' — ' + tag, 'author_reply': 'x',
            'verdict_keyword': verdict}
doc = {'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't', 'state': 'MERGED',
       'findings': [f('claude','accepted','important','a'),
                    f('claude','accepted','important','b'),
                    f('claude','partial','important','c'),
                    f('claude','rejected','important','d')]}
print(json.dumps(doc))
" | _seed
assert_contains "| **precision** | **0.62** |" "2 accepted + 1 partial over 4 judged" -- _report

it "leaves no_reply and acknowledged out of the denominator"
# A finding nobody ruled on is not one anybody accepted. 1 accepted, 1 no_reply,
# 1 acknowledged -> precision 1.00 over a denominator of 1, not 0.33 over 3.
python3 -c "
import json
def f(v, tag):
    return {'reviewer': 'claude', 'path': 'a.ts', 'line': 1,
            'finding': '🟠 Important — ' + tag, 'author_reply': 'x',
            'verdict_keyword': v}
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [f('accepted','a'), f('no_reply','b'), f('acknowledged','c')]}))
" | _seed
assert_contains "| judged (the denominator) | 1 |" "only the judged one counts" -- _report

it "reports n/a rather than a number when nothing was judged"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'claude', 'path': 'a.ts', 'line': 1,
                                'finding': '🟠 Important — x', 'author_reply': '',
                                'verdict_keyword': 'no_reply'}]}))
" | _seed
assert_contains "n/a" "no judged findings yields n/a, not 0.00" -- _report

# --- the criterion that decides ----------------------------------------------

# The FAIL cells below carry "(thin window)" because these fixtures hold one
# pull request. A FAIL earned on three and one earned on thirty read the same
# in a table and only one is a measurement; the count is what these cases
# assert, and it is unchanged.

# These fixtures hold one pull request, so the verdict column reads `not yet`
# rather than `PASS`: what they assert is the COUNT, which is what the miss
# heuristic gets right or wrong. A window this small cannot earn a pass.

it "counts a blocking finding only they caught as a miss"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — real', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 1 | FAIL (thin window) |" "a lone accepted blocking is a miss" -- _report
assert_contains "a.ts:9" "the miss is listed, not just counted" -- _report

it "does NOT count it when we also reviewed that pull request"
# The heuristic is deliberately crude — "they found it, we said nothing" — so it
# must at least stop counting once we did say something.
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — real', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'},
                               {'reviewer': 'claude', 'path': 'b.ts', 'line': 1,
                                'finding': '🟠 Important — ours', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 0 | not yet |" "not a miss when we reviewed too" -- _report

it "does not count a rejected blocking finding of theirs as a miss"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — wrong', 'author_reply': 'Écarté',
                                'verdict_keyword': 'rejected'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 0 | not yet |" "a rejected blocking is not a miss" -- _report

# --- verdict precedence -------------------------------------------------------

it "prefers a human correction over the model, and the model over keywords"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'claude', 'path': 'a.ts', 'line': 1,
                                'finding': '🟠 Important — x', 'author_reply': 'x',
                                'verdict_human': 'rejected',
                                'verdict_llm': 'accepted',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| rejected | 1 |" "verdict_human wins" -- _report

# --- window and shape ---------------------------------------------------------

it "honours --since so a freeze point can start a clean window"
python3 -c "
import json, os
d = os.environ['LED'] + '/Aileaneprod/korbyx'
os.makedirs(d, exist_ok=True)
for pr in (1, 99):
    json.dump({'repo': 'Aileaneprod/korbyx', 'pr': pr, 'title': 't%d' % pr,
               'findings': [{'reviewer': 'claude', 'path': 'a.ts', 'line': 1,
                             'finding': '🟠 Important — x', 'author_reply': 'Retenu',
                             'verdict_keyword': 'accepted'}]},
              open('%s/%d.json' % (d, pr), 'w', encoding='utf-8'))
" 2>/dev/null || true
LED="$(_led)" python3 -c "
import json, os
d = os.environ['LED'] + '/Aileaneprod/korbyx'
os.makedirs(d, exist_ok=True)
for pr in (1, 99):
    json.dump({'repo': 'Aileaneprod/korbyx', 'pr': pr, 'title': 't%d' % pr,
               'findings': [{'reviewer': 'claude', 'path': 'a.ts', 'line': 1,
                             'finding': '🟠 Important — x', 'author_reply': 'Retenu',
                             'verdict_keyword': 'accepted'}]},
              open('%s/%d.json' % (d, pr), 'w', encoding='utf-8'))
"
assert_contains "Window: 1 pull request(s) from #99" "--since narrows the window" -- _report --since 99

it "writes to --out when asked"
assert_status 0 "writes a file" -- _report --out "$TESTTMP/REPORT.md"
assert_contains "Can we switch coderabbitai off?" "the file has the report" -- cat "$TESTTMP/REPORT.md"

# --- a verdict has to be earned ----------------------------------------------

it "never reads PASS on a window too small to have measured anything"
# Freezing the measurement window to start clean made this urgent: on an empty
# window the table printed `| Blocking findings only they caught | 0 | 0 | PASS |`
# — the criterion that decides whether CodeRabbit gets switched off, reading
# green because nothing had been measured at all. Zero misses over one pull
# request is the absence of evidence, not evidence of absence.
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'claude', 'path': 'a.ts', 'line': 1,
                                'finding': '🟠 Important — x', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'},
                               {'reviewer': 'coderabbitai', 'path': 'b.ts', 'line': 2,
                                'finding': '🟠 Important — y', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 0 | not yet |" "no misses on one PR is not a pass" -- _report
assert_contains "| Our precision on judged findings | >= 0.95 | 1.00 | not yet |" "a perfect score on one PR is not a pass either" -- _report

it "still reports a miss it actually saw, however small the window"
# The asymmetry is deliberate. A blocking finding we missed is a positive
# observation and counts from the first one.
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — real', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 1 | FAIL (thin window) |" "one observed miss still fails" -- _report

# --- silence by choice is not silence by failure ------------------------------
#
# The miss heuristic counts a blocking finding of theirs against us only when we
# "said nothing on that pull request", and presence used to be inferred from
# inline comments alone. A review that completed and had nothing to file was
# therefore scored identically to one that never ran — punishing the reviewer
# for the behaviour its own prompt calls "a valid, frequent, and good outcome".
#
# harvest-feedback.sh now records `reviewed_by_ours` from the sticky summary.
# On korbyx#92 that flag is the only evidence we were there: three runs, a
# reasoned 0/0/0 summary, and zero findings in the ledger.

it "does not count a miss on a pull request we reviewed and stayed silent on"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 92, 'title': 't',
                  'reviewed_by_ours': True,
                  'our_summary_at': '2026-09-04T16:31:00Z',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — real', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 0 | not yet |" "we were there, so it is not our miss" -- _report

it "still counts a miss when nothing says we were there"
# The same document without the flag. An older ledger entry, or a run that never
# happened — either way the heuristic keeps its old, deliberately crude answer.
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 92, 'title': 't',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — real', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "| Blocking findings only they caught | 0 | 1 | FAIL (thin window) |" "no evidence of us, still a candidate" -- _report

it "counts a pull request we read but did not comment on as reviewed by both"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 92, 'title': 't',
                  'reviewed_by_ours': True,
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 1,
                                'finding': '🟠 Important — x', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "1 pull request(s), 1 reviewed by both" "both reviewers were present" -- _report

# --- a filter that fails open is worse than no filter ------------------------
#
# `--since ""` used to be accepted and then ignored: the Python read
# `os.environ.get("SINCE") or ""`, empty is falsy, and the page silently
# rendered the FULL window while looking frozen. The only visible difference
# from a correctly frozen page was four words in the header, and it exited 0.
#
# That matters because the value is meant to come out of a file by sed. A
# renamed key, a CRLF, a pattern that stops matching — all of them yield an
# empty string, and all of them would have quietly restored the contaminated
# numbers to the page that decides.

it "refuses an empty --since instead of ignoring it"
assert_status 2 "an empty freeze point is an error" -- _report --since ""
assert_contains "positive pull request number" "and it says what it wanted" -- _report --since ""

it "refuses a --since that is not a number"
assert_status 2 "a non-numeric freeze point is an error" -- _report --since "since: 114"

it "still accepts a real freeze point"
assert_contains "from #99" "a number is a number" -- _report --since 99

# --- a thin FAIL must not read like a measured one ---------------------------

it "marks a FAIL earned on a window too thin to have measured much"
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 9,
                                'finding': '🔴 Blocking — real', 'author_reply': 'Retenu',
                                'verdict_keyword': 'accepted'}]}))
" | _seed
assert_contains "FAIL (thin window)" "one miss on one PR is flagged as thin" -- _report

# --- the frozen page must say it was frozen ----------------------------------
#
# report.sh writes the file with mode "w", so a note added by hand dies at the
# next scheduled run. The page has to carry its own provenance or it will read
# "_None in this window._" as "we no longer miss anything".

it "prints the note the caller gives it, under the window line"
assert_contains "Window reset on 2026-09-07" "the note reaches the page" \
  -- _report --since 99 --since-note "Window reset on 2026-09-07; see report/freeze.yml."

# --- a bare number cannot address two repositories ---------------------------
#
# The filter compares `doc["pr"]` alone and is repo-blind, even though the next
# line keys the result by (repo, number). With a second repository in the ledger
# a freeze point of 114 admits `other#400` — an old review, numbered high — and
# silently drops `other#3`, a pull request opened today, which is exactly the
# clean measurement the window exists to collect. Wrong in both directions, and
# neither is reported.
#
# One repository is the only case where a bare number means anything, so that is
# the only case it is allowed in.

_seed_two() {
  rm -rf "$(_led)"
  mkdir -p "$(_led)/Aileaneprod/korbyx" "$(_led)/Aileaneprod/other"
  python3 -c "
import json, sys
for repo, pr, path in (('Aileaneprod/korbyx', 120, sys.argv[1]),
                       ('Aileaneprod/other', 400, sys.argv[2])):
    json.dump({'repo': repo, 'pr': pr, 'title': 't', 'reviewed_by_ours': False,
               'findings': [{'reviewer': 'coderabbitai', 'path': 'a.ts', 'line': 1,
                             'finding': '🔴 Blocking — x', 'author_reply': 'Retenu',
                             'verdict_keyword': 'accepted'}]},
              open(path, 'w', encoding='utf-8'))
" "$(_led)/Aileaneprod/korbyx/120.json" "$(_led)/Aileaneprod/other/400.json"
}

it "refuses a bare --since when the ledger holds more than one repository"
_seed_two
assert_status 2 "a repo-blind number is an error, not a silent misfilter" -- _report --since 114
assert_contains "more than one repository" "and it names the problem" -- _report --since 114

it "still reports both repositories when no window is asked for"
_seed_two
assert_contains "2 pull request(s)" "without --since the ledger is whole" -- _report

it "refuses a freeze point of zero"
# Re-seed first: the case above leaves a two-repository ledger behind, and
# without this the multi-repo guard returns 2 and these assertions pass for a
# reason that has nothing to do with zero.
python3 -c "
import json
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'findings': []}))
" | _seed
# Pull request numbers start at 1. `--since 0` passed the digits-only check and
# rendered "from #0" over the whole ledger — a window that looks narrowed and
# is not, which is the same failure as the empty value one line up.
assert_status 2 "zero is not a pull request" -- _report --since 0
assert_status 2 "and neither is 00" -- _report --since 00

# --- never round a measurement up toward its target --------------------------
#
# A real run printed
#
#     | Our precision on judged findings | >= 0.95 | 0.95 | FAIL |
#
# The value was 0.945946. Rounded to two places it reads as meeting the target
# it fails, and the reader has no way to reconcile the two cells. Truncating
# downward instead means the printed number never overstates: 0.94 next to a
# target of 0.95 explains its own FAIL, and a genuine 0.951 still shows 0.95.

it "does not round a precision up to the target it misses"
python3 -c "
import json
f = lambda v, i: {'reviewer': 'claude', 'path': 'a%d.ts' % i, 'line': i,
                  'finding': '🟠 Important — x%d' % i, 'author_reply': 'x',
                  'verdict_keyword': v}
findings = [f('accepted', i) for i in range(18)] + [f('rejected', 99)]
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'reviewed_by_ours': True, 'findings': findings}))
" | _seed
assert_contains "| **precision** | **0.94** |" "18 of 19 is 0.94, not 0.95" -- _report
assert_not_contains ">= 0.95 | 0.95 | FAIL" "the cell never contradicts its own verdict" -- _report

it "truncates by value, not by whatever the float happens to be"
# Raised by CodeRabbit on the pull request that added pct(). `int(0.29 * 100)`
# is 28, because 0.29 * 100 is 28.999999999999996 — so the cell that was made
# to stop OVERSTATING started understating by a hundredth. 29/100, 57/100 and
# 58/100 all did it.
_pct() { python3 -c "
import sys
sys.path.insert(0, '.')
" ; "$SCRIPTS/report.sh" --ledger "$(_led)" ; }
python3 -c "
import json
f = lambda v, i: {'reviewer': 'claude', 'path': 'a%d.ts' % i, 'line': i,
                  'finding': '🟠 Important — x%d' % i, 'author_reply': 'x',
                  'verdict_keyword': v}
# 29 accepted of 100 judged -> exactly 0.29
findings = [f('accepted', i) for i in range(29)] + [f('rejected', 100 + i) for i in range(71)]
print(json.dumps({'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't',
                  'reviewed_by_ours': True, 'findings': findings}))
" | _seed
assert_contains "| **precision** | **0.29** |" "29 of 100 is 0.29, not 0.28" -- _report
