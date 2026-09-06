# classify-verdicts.sh — decide what the author actually said about a finding.
#
# This is the number the whole comparison rests on. If the verdicts are wrong,
# "precision 1.00 against 0.82" is a story, not a measurement.
#
# The keyword classifier this replaces was wrong on 46 of 148 findings. Its
# failures were not random:
#
#   * ACCEPT held "corrigé" and "fixed" but not "Retenu", "Fermé", "Traité",
#     "Juste", "Toujours valide" — the words this team actually uses.
#   * REJECT was tested BEFORE accept and matched anywhere in the text, so
#     "Retenu, et traité par une forme plus forte que celle demandée" was
#     scored a rejection on a stray later word.
#   * There was no category for a reply that answers without judging — a
#     re-verification sweep, a question, "Fil soldé" — so those became
#     "unknown" and silently left the denominator.
#
# The gold set that gates this lives in the private ledger repo, not here: it
# keys on korbyx paths and pull request numbers, and this repository is public.

_ledger() { printf '%s' "$TESTTMP/ledger"; }

_seed() {
  # Build a tiny ledger: $1 = reply text, $2 = reviewer (default coderabbitai)
  local reply="$1" reviewer="${2:-coderabbitai}"
  rm -rf "$(_ledger)"; mkdir -p "$(_ledger)/Aileaneprod/korbyx"
  python3 -c "
import json, sys
reply, reviewer = sys.argv[1], sys.argv[2]
doc = {'repo': 'Aileaneprod/korbyx', 'pr': 1, 'title': 't', 'state': 'MERGED',
       'findings': [{'reviewer': reviewer, 'path': 'a.ts', 'line': 1,
                     'reviewed_commit': 'abc1234', 'finding': '🟠 Important — a claim',
                     'finding_at': '2026-08-01T00:00:00Z',
                     'author_reply': reply, 'author_reply_at': '2026-08-01T01:00:00Z',
                     'verdict_guess': 'unknown', 'resolved': False, 'outdated': False}]}
json.dump(doc, open(sys.argv[3], 'w', encoding='utf-8'), ensure_ascii=False)
" "$reply" "$reviewer" "$(_ledger)/Aileaneprod/korbyx/1.json"
}

_verdict() {
  _seed "$1"
  "$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)" --keyword-only >/dev/null 2>&1
  python3 -c "
import json
d = json.load(open(r'$(_ledger)/Aileaneprod/korbyx/1.json', encoding='utf-8'))
print(d['findings'][0].get('verdict_keyword', 'MISSING'))
"
}

# --- the words this team actually uses ---------------------------------------

it "reads the French acceptance vocabulary the keyword list missed"
assert_equal "accepted" "$(_verdict 'Retenu, et corrigé en af20c00.')"          "Retenu"
assert_equal "accepted" "$(_verdict 'Fermé, les deux couvertures sont là.')"    "Fermé"
assert_equal "accepted" "$(_verdict 'Traité au head 7a83192.')"                 "Traité"
assert_equal "accepted" "$(_verdict 'Juste, et reproduit plutôt que concédé.')" "Juste"
assert_equal "accepted" "$(_verdict 'Constat vérifié, et corrigé.')"            "Constat vérifié"
assert_equal "accepted" "$(_verdict 'Bloquant confirmé. Corrigé en af20c00.')"  "Bloquant confirmé"
assert_equal "accepted" "$(_verdict 'Corrigé en b7f5341, et le constat est exact.')" "Corrigé (already worked)"

it "still reads rejections"
assert_equal "rejected" "$(_verdict 'Écarté. Le ticket décide lui-même de cet emplacement.')" "Écarté"
assert_equal "rejected" "$(_verdict 'Ce constat est un faux positif après vérification.')"    "faux positif"
assert_equal "rejected" "$(_verdict 'Réfuté, et je l ai prouvé plutôt que raisonné.')"        "Réfuté"
assert_equal "rejected" "$(_verdict 'Pas de changement ici : cette borne est théorique.')"    "Pas de changement"

it "reads partials"
assert_equal "partial" "$(_verdict 'Appliqué à moitié en 74083ff.')" "à moitié"

# --- the ordering bug that cost 46 verdicts ----------------------------------

it "does not let a later word override an opening verdict"
# The real case: scored `rejected` because a REJECT keyword appeared further on.
assert_equal "accepted" \
  "$(_verdict 'Retenu, et traité par une forme plus forte que celle demandée. Une liste de valeurs interdites laisse passer ce qu on a oublié d y mettre, donc pas de changement de ce côté.')" \
  "an opening Retenu wins over a later 'pas de changement'"

assert_equal "rejected" \
  "$(_verdict 'Écarté pour ce ticket. Le constat est exact sur le fond, mais son déclencheur est nommé ailleurs.')" \
  "an opening Écarté wins over a later 'le constat est exact'"

# --- the first word decides, when the repository asks for one ----------------
# korbyx/CONTRIBUTING.md mandates Retenu / Écarté / Partiel / Vu at the head of
# every reply. An exact label beats any amount of vocabulary, and it fixes a
# case the opening-window rule gets WRONG on its own: "Retenu — le faux positif
# est sur le point voisin" opens with an acceptance and mentions a rejection
# word four words later, so precedence alone inverts it.

it "takes the first word as the verdict when there is one"
assert_equal "accepted" "$(_verdict 'Retenu — le faux positif est sur le point voisin.')"   "Retenu wins over a rejection word right behind it"
assert_equal "rejected" "$(_verdict 'Écarté — le constat est exact sur le fond.')"   "Écarté wins over an acceptance word right behind it"
assert_equal "partial"  "$(_verdict 'Partiel : la moitié est corrigée.')" "Partiel"

it "reads Vu as an acceptance, per CONTRIBUTING.md"
assert_equal "accepted" "$(_verdict 'Vu. Le constat est bon, il part dans KOR-233.')" "Vu"

it "reads the mandated word through markdown and accents"
assert_equal "accepted" "$(_verdict '**Retenu**, et corrigé.')"  "bold Retenu"
assert_equal "rejected" "$(_verdict 'ecarte, sans accent.')"     "unaccented ecarte"
assert_equal "accepted" "$(_verdict '> Retenu, en citation.')"   "quoted Retenu"

# --- a reply that answers without judging ------------------------------------

it "separates acknowledgement from a verdict"
# These left the denominator as "unknown" before, which quietly flattered both
# reviewers: a finding nobody judged is not a finding anybody accepted.
# "Toujours vivant" affirms the finding still stands — an acceptance for a
# precision metric, however sweep-like it reads.
assert_equal "accepted" "$(_verdict 'Toujours vivant, vérifié contre le main du 29/08.')" "a still-valid confirmation"
assert_equal "acknowledged" "$(_verdict 'Fil soldé.')" "a thread being closed"
assert_equal "acknowledged" "$(_verdict 'Tu peux préciser ce que tu entends par là ?')" "a question back"

it "marks an empty reply as no_reply, not as a judgement"
assert_equal "no_reply" "$(_verdict '')" "empty reply"

# --- it must never touch the evidence ----------------------------------------

it "never rewrites the author's words"
_seed 'Retenu, et corrigé.'
"$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)" --keyword-only >/dev/null 2>&1
assert_contains "Retenu, et corrigé." "author_reply is preserved verbatim" -- \
  cat "$(_ledger)/Aileaneprod/korbyx/1.json"

it "keeps the original keyword guess alongside its own"
assert_contains "verdict_guess" "verdict_guess survives" -- \
  cat "$(_ledger)/Aileaneprod/korbyx/1.json"

# --- the gate: agreement against a gold set ----------------------------------

it "reports agreement against a gold set and fails below the threshold"
_seed 'Retenu, et corrigé.'
# Read the key the classifier persisted rather than recomputing the hash here:
# two shells disagreed about how to encode the emoji in the finding text, and
# the gold set silently matched nothing.
"$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)" --keyword-only >/dev/null 2>&1
_goldkey() {
  python3 -c "
import json
d = json.load(open(r'$(_ledger)/Aileaneprod/korbyx/1.json', encoding='utf-8'))
print(d['findings'][0]['key'])
"
}
python3 -c "
import json, sys
json.dump({sys.argv[1]: 'accepted'}, open(sys.argv[2], 'w', encoding='utf-8'))
" "$(_goldkey)" "$(_ledger)/gold.json"
assert_status 0 "agreement at 100 percent passes a 95 percent gate" --   "$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)" --keyword-only     --gold "$(_ledger)/gold.json" --min-agreement 95
python3 -c "
import json, sys
json.dump({sys.argv[1]: 'rejected'}, open(sys.argv[2], 'w', encoding='utf-8'))
" "$(_goldkey)" "$(_ledger)/gold.json"
assert_status 1 "disagreement fails the gate" --   "$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)" --keyword-only     --gold "$(_ledger)/gold.json" --min-agreement 95

it "fails loudly when the gold set matches nothing"
python3 -c "
import json, sys
json.dump({'nope|nope|nope|deadbeef': 'accepted'}, open(sys.argv[1], 'w', encoding='utf-8'))
" "$(_ledger)/gold.json"
assert_status 2 "a gold set that matches nothing is an error, not 100 percent" --   "$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)" --keyword-only     --gold "$(_ledger)/gold.json" --min-agreement 95

# --- the API path must not be reachable by accident --------------------------

it "refuses LLM mode without a credential rather than silently degrading"
_seed 'Retenu.'
assert_contains "ANTHROPIC_API_KEY" "says what is missing" -- \
  env -u ANTHROPIC_API_KEY "$SCRIPTS/classify-verdicts.sh" --ledger "$(_ledger)"
