#!/usr/bin/env bash
#
# classify-verdicts.sh — decide what the author actually said about a finding.
#
# Usage:
#   classify-verdicts.sh --ledger DIR [--keyword-only] [--only-unclassified]
#                        [--max-calls N] [--gold FILE] [--min-agreement PCT]
#                        [--model ID] [--response-file FILE]
#
#   --ledger DIR         Harvested ledger (harvest-feedback.sh --out).
#   --keyword-only       Skip the model entirely. No credential needed.
#   --only-unclassified  Only findings without a verdict yet. Default: all.
#   --max-calls N        Hard ceiling on model calls. Default 300.
#   --gold FILE          JSON map of verdicts a human read, keyed exactly as the
#                        script keys findings:
#                          "<repo>#<pr>|<path>|<line>|<first 8 of sha256(finding)>"
#                        Every finding carries that string in its `key` field, so
#                        build a gold file from the ledger rather than by hand. A
#                        key that matches nothing exits 2 rather than scoring 100%.
#   --min-agreement PCT  Exit 1 if agreement with --gold falls below this.
#   --model ID           Model for the LLM pass. Read the current id from the
#                        docs; do not carry one in your head.
#   --response-file FILE Canned API response, for tests.
#
# Credential: ANTHROPIC_API_KEY, and ONLY here. This runs offline against a
# ledger — never inside review.yml. The action's `classify_inline_comments`
# defaults to true and would start classifying review comments with a second
# model the moment that variable existed in the review job.
#
# WHY THIS EXISTS. The verdict is the measurement. "Our precision is 1.00 and
# CodeRabbit's is 0.82" is only worth saying if the verdicts behind it are
# right, and the keyword classifier that produced the first draft of those
# numbers was wrong on 46 of 148 findings — it tested REJECT before ACCEPT and
# matched anywhere in the reply, so "Retenu, et traité par une forme plus forte
# que celle demandée" was recorded as a rejection.
#
# It writes `verdict_keyword` and `verdict_llm` ALONGSIDE the existing
# `verdict_guess`, and never touches `author_reply`. The author's words are the
# evidence; everything here is an opinion about them.
#
# Requires: python3.

set -euo pipefail

ledger_dir=""
keyword_only=0
only_unclassified=0
max_calls=300
gold_file=""
min_agreement=""
model=""
response_file=""

die() { printf 'classify-verdicts: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger)         [ "$#" -ge 2 ] || die "--ledger requires a value";  ledger_dir="$2";     shift 2 ;;
    --keyword-only)   keyword_only=1; shift ;;
    --only-unclassified) only_unclassified=1; shift ;;
    --max-calls)      [ "$#" -ge 2 ] || die "--max-calls requires a value"; max_calls="$2";    shift 2 ;;
    --gold)           [ "$#" -ge 2 ] || die "--gold requires a value";    gold_file="$2";      shift 2 ;;
    --min-agreement)  [ "$#" -ge 2 ] || die "--min-agreement requires a value"; min_agreement="$2"; shift 2 ;;
    --model)          [ "$#" -ge 2 ] || die "--model requires a value";   model="$2";          shift 2 ;;
    --response-file)  [ "$#" -ge 2 ] || die "--response-file requires a value"; response_file="$2"; shift 2 ;;
    -h|--help)        sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$ledger_dir" ] || die "--ledger is required"
[ -d "$ledger_dir" ] || die "no ledger at $ledger_dir"

if [ "$keyword_only" -eq 0 ] && [ -z "$response_file" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  printf 'classify-verdicts: ANTHROPIC_API_KEY is not set.\n' >&2
  printf 'classify-verdicts: pass --keyword-only to classify without a model,\n' >&2
  printf 'classify-verdicts: or set the key. It belongs here and never in review.yml.\n' >&2
  exit 2
fi

LEDGER_DIR="$ledger_dir" \
KEYWORD_ONLY="$keyword_only" \
ONLY_UNCLASSIFIED="$only_unclassified" \
MAX_CALLS="$max_calls" \
GOLD_FILE="$gold_file" \
MIN_AGREEMENT="$min_agreement" \
MODEL="$model" \
RESPONSE_FILE="$response_file" \
python3 <<'PY'
import hashlib
import json
import os
import re
import sys
import unicodedata
import urllib.request

ledger_dir = os.environ["LEDGER_DIR"]
keyword_only = os.environ["KEYWORD_ONLY"] == "1"
only_unclassified = os.environ["ONLY_UNCLASSIFIED"] == "1"
max_calls = int(os.environ["MAX_CALLS"] or 300)
gold_file = os.environ.get("GOLD_FILE") or ""
min_agreement = os.environ.get("MIN_AGREEMENT") or ""
model = os.environ.get("MODEL") or ""
response_file = os.environ.get("RESPONSE_FILE") or ""

# --- the keyword pass ---------------------------------------------------------
# Ordering is the whole lesson. The verdict is decided by what the reply OPENS
# with, because that is how people write them: the judgement first, the
# reasoning after. Scanning the whole text for any keyword is what turned
# "Retenu, et traité par une forme plus forte" into a rejection.

# Matched on WORD BOUNDARIES, not as substrings. Bare "juste", "exact" and
# "vrai" as substrings hit "justement", "exactement" and "vraiment", which is
# the same disease as the classifier this replaces — a short common word
# matching inside a longer one, somewhere in a paragraph, deciding a verdict.
ACCEPT = (r"retenu\w*", r"corrigé\w*", r"corrige\w*", r"fixed", r"corrected",
          r"appliqué\w*", r"applique\w*", r"traité\w*", r"traite\w*",
          r"fermé\w*", r"ferme\w*", r"accepté\w*", r"accepte\w*",
          r"le constat est (?:exact|juste|vrai)", r"constat (?:vérifié|verifie|valide)",
          r"finding valide", r"bloquant confirmé", r"bloquant confirme",
          r"good catch", r"done", r"tu as raison", r"d'accord",
          r"juste[,.]", r"exact[,.]",
          # "Toujours vivant, vérifié contre le main du 29/08" is the author
          # affirming the finding still stands. For a PRECISION metric — was
          # the finding correct — that is an acceptance, not a status note.
          # It reads like a sweep, which is why it first landed in ACK; what
          # the sentence actually says is "you were right, and still are".
          r"toujours (?:valide|vivant|présent|present|vrai)")
REJECT = (r"écarté\w*", r"ecarte\w*", r"rejected", r"declined",
          r"faux positif", r"false positive", r"réfuté\w*", r"refuté\w*",
          r"pas de changement", r"aucun changement", r"invalide", r"no change",
          r"non retenu", r"je ne change pas", r"hors périmètre", r"hors perimetre")
PARTIAL = (r"à moitié", r"a moitie", r"partiel\w*", r"partially", r"en partie",
           r"à demi", r"a demi")
# A reply that answers without judging. Before this category these fell into
# "unknown" and left the denominator, which flatters whichever reviewer has
# more unanswered findings — a finding nobody judged is not one anybody accepted.
ACK = (r"fil soldé", r"fil solde", r"noté\b", r"je regarde",
       r"peux-tu", r"tu peux préciser", r"que veux-tu dire", r"\?")


def _compile(needles):
    """Word-boundary-prefixed, EXCEPT for needles that begin with punctuation.

    `(?<!\w)` before `\?` demands a non-word character in front of the question
    mark, so spaced French ("par là ?") matched and "you mean?" did not — the
    replies most likely to be questions were the ones it missed.
    """
    out = []
    for n in needles:
        pattern = n if n.startswith("\\") else r"(?<!\w)(?:%s)" % n
        out.append((n, re.compile(pattern, re.UNICODE)))
    return out


ACCEPT_RE, REJECT_RE, PARTIAL_RE, ACK_RE = (
    _compile(ACCEPT), _compile(REJECT), _compile(PARTIAL), _compile(ACK))

# How much of the reply counts as "the opening". Long enough for a sentence,
# short enough that the reasoning after it cannot flip the verdict.
OPENING = 120


def normalise(text):
    return " ".join((text or "").lower().split())


# THE FIRST WORD DECIDES, when the repository asks for one. This mirrors
# harvest-feedback.sh, deliberately: a repo that mandates a vocabulary should
# get the same answer from the cheap hint and from the measurement, and two
# classifiers disagreeing silently is worse than either being crude.
#
# korbyx/CONTRIBUTING.md mandates Retenu / Écarté / Partiel / Vu. An exact label
# beats any amount of vocabulary — and it repairs a case the opening-window rule
# gets backwards on its own: "Retenu — le faux positif est sur le point voisin"
# opens with an acceptance and carries a rejection word four words later, so
# precedence alone inverts what the author wrote.
#
# `vu` maps to accepted because CONTRIBUTING.md defines it that way: the finding
# is good, and handled somewhere other than this pull request.
# Prefixes, because these words inflect: retenue, écartée, partiellement.
FIRST_WORD = (("retenu", "accepted"), ("ecart", "rejected"), ("partiel", "partial"))

# `vu` needs the label to be FOLLOWED BY PUNCTUATION, not merely to be the first
# word. Two letters swallow far too much on their own: "Vulnérable", "Vue",
# "Vus" — and above all "Vu que", the ordinary French connector meaning "given
# that", which opens plenty of replies that are outright refusals. Matching the
# bare word is not enough either, because first_word() reduces "Vu." and
# "Vu que" to the same thing. Scoring those as acceptances would inflate the
# precision figure this ledger exists to report, in our own favour.
FIRST_WORD_EXACT = ((re.compile(r"^[*_>#\s-]*vu\s*(?:[.,:;!?—–-]|$)", re.UNICODE),
                     "accepted"),)


def first_word(text):
    """Lower-cased, accent-stripped, freed of markdown and trailing punctuation."""
    stripped = unicodedata.normalize("NFD", (text or "").strip().lower())
    stripped = "".join(c for c in stripped if not unicodedata.combining(c))
    return re.split(r"[^a-z]+", stripped.lstrip("*_># \t-"), 1)[0]


def first_hit(text, compiled):
    """Earliest match position of any pattern, or None."""
    positions = [m.start() for _n, rx in compiled for m in [rx.search(text)] if m]
    return min(positions) if positions else None


def _decide(text):
    """Precedence, not position: partial, then refusal, then acceptance.

    Position looks right and is wrong. "Le principe est juste, l'application à
    cet artefact ne l'est pas. Je ne change pas la commande" opens with an
    acceptance word and is a refusal — the concession is rhetorical and the
    refusal is the operative statement. Whenever both appear in the same
    breath, the refusal is what the author did.
    """
    if first_hit(text, PARTIAL_RE) is not None:
        return "partial"
    if first_hit(text, REJECT_RE) is not None:
        return "rejected"
    if first_hit(text, ACCEPT_RE) is not None:
        return "accepted"
    return None


def keyword_verdict(reply):
    text = normalise(reply)
    if not text:
        return "no_reply"

    # An exact mandated label outranks everything below it.
    word = first_word(reply)
    # Accent-stripped, lower-cased original, so the label test sees the
    # punctuation that first_word() throws away.
    plain = unicodedata.normalize("NFD", (reply or "").strip().lower())
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    for pattern, verdict in FIRST_WORD_EXACT:
        if pattern.match(plain):
            return verdict
    for prefix, verdict in FIRST_WORD:
        if word.startswith(prefix):
            return verdict

    # Decide on the opening if anything decisive is there; earliest wins, so
    # "Écarté … le constat est exact" is a rejection and "Retenu … pas de
    # changement de ce côté" is an acceptance.
    decided = _decide(text[:OPENING])
    if decided:
        return decided

    # An acknowledgement is judged on the opening too. Checking it only after a
    # full-text sweep let a long status note reach a stray "corrigé" three
    # paragraphs down and be recorded as the author accepting the finding.
    if first_hit(text[:OPENING], ACK_RE) is not None:
        return "acknowledged"

    decided = _decide(text)
    if decided:
        return decided
    if first_hit(text, ACK_RE) is not None:
        return "acknowledged"
    return "unknown"


# --- the model pass -----------------------------------------------------------

PROMPT = """You are reading one reply an engineer wrote to a code-review finding.
Classify what the reply says about the finding. Answer with JSON only.

verdict must be exactly one of:
  accepted      - the engineer agrees the finding is correct (whether or not they
                  fixed it here, and whether or not they deferred the fix)
  partial       - they agree with part of it and decline part
  rejected      - they say the finding is wrong, or decline it outright
  acknowledged  - they replied without judging it: a status note, a question, a
                  re-verification sweep, "thread closed"
  no_reply      - there is no reply text

Judge the reply, not the finding. Deferring a fix to another ticket while saying
the observation is correct is "accepted", not "rejected".

THE FINDING:
%s

THE REPLY:
%s

Answer: {"verdict": "...", "quote": "<= 12 words from the reply that decide it"}
"""


def call_model(finding, reply):
    if response_file:
        with open(response_file, encoding="utf-8") as handle:
            return json.load(handle)
    body = {
        "model": model or "claude-sonnet-5",
        "max_tokens": 200,
        "messages": [{"role": "user",
                      "content": PROMPT % (finding[:1500], reply[:2000])}],
    }
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json",
                 "x-api-key": os.environ["ANTHROPIC_API_KEY"],
                 "anthropic-version": "2023-06-01"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def llm_verdict(finding, reply):
    payload = call_model(finding, reply)
    try:
        text = "".join(b.get("text", "") for b in payload.get("content", []))
        match = re.search(r"\{.*\}", text, re.S)
        parsed = json.loads(match.group(0))
        verdict = parsed.get("verdict")
    except Exception:
        return None, None
    if verdict not in ("accepted", "partial", "rejected", "acknowledged", "no_reply"):
        return None, None
    return verdict, (parsed.get("quote") or "")[:200]


# --- walk the ledger ----------------------------------------------------------

calls = 0
counts = {}
classified = []

for root, _dirs, files in os.walk(ledger_dir):
    for name in sorted(files):
        if not name.endswith(".json") or name == "gold.json":
            continue
        path = os.path.join(root, name)
        try:
            with open(path, encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            continue
        if "findings" not in doc:
            continue

        changed = False
        for finding in doc["findings"]:
            # author_reply is the verdict; harvest keeps other humans separate,
            # because a passer-by agreeing is not the author accepting.
            reply = finding.get("author_reply")
            if reply is None:
                reply = finding.get("human_reply") or ""

            keyword = keyword_verdict(reply)
            if finding.get("verdict_keyword") != keyword:
                finding["verdict_keyword"] = keyword
                changed = True

            verdict = keyword
            if not keyword_only and reply:
                already = finding.get("verdict_llm")
                digest = hashlib.sha256(
                    ((finding.get("finding") or "") + "\x00" + reply).encode("utf-8")
                ).hexdigest()
                cached = finding.get("verdict_llm_key") == digest
                if not (cached and already) and not (only_unclassified and already):
                    if calls < max_calls:
                        calls += 1
                        llm, quote = llm_verdict(finding.get("finding") or "", reply)
                        if llm:
                            finding["verdict_llm"] = llm
                            finding["verdict_llm_quote"] = quote
                            finding["verdict_llm_key"] = digest
                            changed = True
                            already = llm
                if already:
                    verdict = already
            elif finding.get("verdict_llm"):
                verdict = finding["verdict_llm"]

            counts[verdict] = counts.get(verdict, 0) + 1
            # path+line is NOT unique: three findings sat on
            # sales-projection.ts with line null on one pull request, and a key
            # built from those alone silently collapsed them, losing rows from
            # both the gold set and the comparison. The finding text
            # disambiguates.
            finding["key"] = "%s#%s|%s|%s|%s" % (
                doc.get("repo"), doc.get("pr"), finding.get("path"),
                finding.get("line"),
                hashlib.sha256((finding.get("finding") or "").encode("utf-8")).hexdigest()[:8],
            )
            classified.append((finding["key"], verdict))

        if changed:
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(doc, handle, indent=2, ensure_ascii=False)
                handle.write("\n")

sys.stderr.write("classify-verdicts: %d finding(s), %d model call(s)\n"
                 % (len(classified), calls))
for verdict in sorted(counts):
    sys.stderr.write("  %-14s %d\n" % (verdict, counts[verdict]))

# --- the gate -----------------------------------------------------------------

if gold_file:
    try:
        with open(gold_file, encoding="utf-8") as handle:
            gold = json.load(handle)
    except (OSError, ValueError) as exc:
        sys.stderr.write("classify-verdicts: unreadable gold file: %s\n" % exc)
        raise SystemExit(2)

    ours = dict(classified)
    checked = [(k, gold[k], ours.get(k)) for k in gold if k in ours]
    if not checked:
        sys.stderr.write("classify-verdicts: the gold set matches nothing in this ledger\n")
        raise SystemExit(2)

    agreed = [c for c in checked if c[1] == c[2]]
    pct = 100.0 * len(agreed) / len(checked)
    sys.stderr.write("classify-verdicts: agreement %.1f%% (%d/%d) against the gold set\n"
                     % (pct, len(agreed), len(checked)))
    for key, want, got in checked:
        if want != got:
            sys.stderr.write("  disagree  %s: gold=%s ours=%s\n" % (key, want, got))
    if min_agreement and pct < float(min_agreement):
        sys.stderr.write("classify-verdicts: below the %s%% gate\n" % min_agreement)
        raise SystemExit(1)
PY
