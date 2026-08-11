# Learnings

Lessons confirmed by what actually happened after a review — a human accepting a
finding and fixing it, or rejecting it and saying why. This file is injected into
every review prompt, so it is the reviewer's memory.

**Nothing lands here without evidence.** Every entry cites the pull request and
the verdict that produced it. Entries are proposed by
`scripts/propose-learnings.sh` from the harvested ledger under `feedback/`, and
merged by a human. They are never written automatically — a wrong lesson does
not degrade one review, it degrades every review in every repository until
somebody notices.

Keep this file short. It competes for the reviewer's attention with the actual
diff, and every line costs quota on every run. A lesson that has stopped earning
its place should be deleted, not archived.

Format: one `##` heading per lesson, an imperative rule, then the evidence.

---

## Judge a finding against the commit it was made on

When re-checking whether a past finding was right, read the code at the SHA the
review ran against — not the branch tip. A finding that was correct is
indistinguishable from one that was wrong once the author has fixed it, because
the contradiction you are looking for is exactly what they removed.

**Evidence:** Aileaneprod/korbyx#13. A finding reported that a `course_progress`
row marked `non_commence` on course `…0001` contradicted a graded
`quiz_attempts` row for the same user on the same course. Re-verified against
the branch tip, the contradiction was absent and the finding was scored a false
positive. It was not: at `e4ab342`, the commit under review, both rows really
did sit on course `…0001`. The author replied *"Corrigé en b7f5341, et le
constat est exact"* and the fix commit is titled *"fix(kor-41): coherence
semantique entre course_progress et quiz_attempts"*. The tip had already been
repaired.

---

## Fixtures can be referentially and temporally valid while still lying

A dataset can pass every foreign-key and every chronology check and still have
two tables assert opposite facts about the same entity. Referential closure and
temporal closure do not imply semantic closure. When a fixture set ships prose
describing the scenarios it models, check that the rows actually model them.

**Evidence:** Aileaneprod/korbyx#13, same finding as above. The author's reply is
the clearest statement of the lesson: *"Ma passe de vérification contrôlait deux
clôtures, la référentielle puis la temporelle. Il en manquait une troisième, la
cohérence sémantique entre tables : une ligne peut être valide, correctement
datée et référentiellement close tout en racontant le contraire d'une autre
table."* They added that third check to the project's own test suite as a
result, and proved it by deliberately reintroducing the defect.

---

## Do not demand a document the repository's own rules say is unnecessary

Before asking for an ADR, a changelog entry, or any other artefact, check what
the repo says about when that artefact is required. Asking for one the project
has explicitly scoped out is noise, and it is noise that reads as authoritative.

**Evidence:** Aileaneprod/korbyx#13, a CodeRabbit finding asked for an ADR
covering the `test/scenarios` layout. The author replied *"Écarté"*, pointing at
`AGENTS.md`, which reserves ADRs for structural decisions explicitly validated
by the team, and at `docs/adr/README.md`, which states an ADR is not for
documenting a decision in advance. The observation that no ADR existed was
factually true; the demand was still wrong.

---

## A README's own caveats usually answer the objection you are about to raise

When a document says something surprising, read the paragraphs around it before
reporting it. Authors routinely pre-empt the obvious objection one paragraph
earlier, and a finding that ignores that reads as if the reviewer skimmed.

**Evidence:** Aileaneprod/korbyx#13, two CodeRabbit findings — both marked
🔴 Bloquant — claimed the fixtures carried real pilot-client names, citing a line
saying the naming divergence was *"la forme réellement rencontrée"*. Six lines
above, the same README states *"Aucune donnée, aucun identifiant, aucun nom et
aucun secret d'un client réel n'entre ici. Le réseau de franchise n'existe
pas."* What was declared real was the shape of the divergence, not the names.
Both threads remain unanswered by the author.
