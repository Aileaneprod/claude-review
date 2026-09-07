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
assert_contains "| Blocking findings only they caught | 0 | 1 | FAIL |" "a lone accepted blocking is a miss" -- _report
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
assert_contains "| Blocking findings only they caught | 0 | 1 | FAIL |" "one observed miss still fails" -- _report
