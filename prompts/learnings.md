# Learnings

Lessons confirmed by what actually happened after a review — a human accepting a
finding and fixing it, or rejecting it and saying why. This file is injected into
every review prompt, so it is the reviewer's memory.

**Nothing lands here without evidence.** Every entry cites the pull request and
the verdict that produced it. Entries are proposed by
`scripts/propose-learnings.sh` from the harvested ledger, and merged by a human.
They are never written automatically — a wrong lesson does not degrade one
review, it degrades every review in every repository until somebody notices.

Keep this file short. It competes for the reviewer's attention with the actual
diff, and every line costs quota on every run. A lesson that has stopped earning
its place should be deleted, not archived. State the rule, then the shortest
evidence that proves it happened.

Format: one `##` heading per lesson, an imperative rule, then the evidence.

---

## Judge a finding against the commit it was made on

When re-checking whether a past finding was right, read the code at the SHA the
review ran against — not the branch tip. A finding that was correct is
indistinguishable from one that was wrong once the author has fixed it, because
the contradiction you are looking for is exactly what they removed.

**Evidence:** Aileaneprod/korbyx#13. A finding that a `non_commence`
`course_progress` row contradicted a graded `quiz_attempts` row was scored a
false positive against the tip, where the contradiction was gone. At `e4ab342`,
the reviewed commit, it was real: *"Corrigé en b7f5341, et le constat est
exact."*

---

## Fixtures can be referentially and temporally valid while still lying

A dataset can pass every foreign-key and every chronology check and still have
two tables assert opposite facts about the same entity. Referential closure and
temporal closure do not imply semantic closure. When a fixture set ships prose
describing the scenarios it models, check that the rows actually model them.

**Evidence:** Aileaneprod/korbyx#13, the same finding. The author: *"une ligne
peut être valide, correctement datée et référentiellement close tout en
racontant le contraire d'une autre table."* They added that third check to the
test suite and proved it by reintroducing the defect.

---

## Do not demand a document the repository's own rules say is unnecessary

Before asking for an ADR, a changelog entry, or any other artefact, check what
the repo says about when that artefact is required. Asking for one the project
has explicitly scoped out is noise, and it is noise that reads as authoritative.

**Evidence:** Aileaneprod/korbyx#13. A CodeRabbit finding asked for an ADR
covering the `test/scenarios` layout. The author replied *"Écarté"*, citing
`AGENTS.md`, which reserves ADRs for structural decisions already validated by
the team. No ADR existed — true; the demand was still wrong.

---

## A README's own caveats usually answer the objection you are about to raise

When a document says something surprising, read the paragraphs around it before
reporting it. Authors routinely pre-empt the obvious objection one paragraph
earlier, and a finding that ignores that reads as if the reviewer skimmed.

**Evidence:** Aileaneprod/korbyx#13. Two CodeRabbit 🔴 findings claimed the
fixtures carried real client names, citing *"la forme réellement rencontrée"*.
Six lines above, the same README states *"Aucune donnée, aucun identifiant,
aucun nom […] d'un client réel n'entre ici."* What was declared real was the
shape of the divergence, not the names. Neither thread was ever answered.

---

## A legal identifier is real until the repository shows where it came from

The lesson above settles names: a name the repository declares fictional is
fictional, and accusing it is a false positive. It does not settle legal
identifiers. A SIREN, SIRET, VAT number, IBAN or registration number shares its
number space with reality, so "invented", a generator, or a passing checksum
proves nothing — the value may still belong to a real company or a real person.
When fixtures, scenarios or a memory file introduce such values, ask where they
come from, and grade the answer by how it was established, not by how firmly it
is asserted. **A prose claim that the values are invented proves nothing** —
that sentence was present, and false, in the case below. What closes the
question is provenance per value: an explicit list the change says was checked
entry by entry against a registry, or values already on the base branch whose
provenance was settled there (`gh pr diff` shows whether the value is even an
added line; `Grep` the working tree for the list that holds it). Values from a
generator, from a sequential or realistic prefix, or with no stated provenance
stay open: you cannot query a registry, so do not assert they are real — raise
a 🟠 that they are unverifiable as synthetic, and name the checked list the
repository already uses. And a file that states the no-real-identifier rule
must be read for instances, not only for the rule.

**Evidence:** Aileaneprod/korbyx#84. A Luhn-valid generator with prefix `810000`
in a scenario whose README said every identifier was invented. A human queried
the registry: *"SIREN qui existent : 11 sur 12"*, eight of them
*"entrepreneur individuel donc personne physique"*. We reviewed that commit,
`55dd646`, and raised nothing. Aileaneprod/korbyx#16: the file forbidding client
names contained one, three times; we reviewed `72e3d65`, posted two
other findings, and missed it — a file that states the rule reads as compliant.
Contrast the one we got right, Aileaneprod/korbyx#46: `DOM&VIE` was declared
fictional nowhere, and its commit message tied it to a measurement on the
client's production. That is the discriminating move: not whether the text
claims invention, but whether anything independent establishes provenance.
*"Finding valide, et entièrement de mon fait."*

---

## Count what the change promises, then find the promise the code does not keep

A PR body's acceptance criteria, a README's list of stop conditions, a
function's documented guarantees: enumerate them and tick each one against the
code. The unmet one is the finding, and a criterion the PR itself states and
does not meet is 🔴, because the author has already said it matters.
`gh pr view --json body` is in the procedure for orientation; read it a second
time as a checklist. Not a finding if the criterion is met somewhere the diff
does not show — check before reporting, as always.

**Evidence:** Aileaneprod/korbyx#38. The PR body's *« Critères d'acceptation et
leurs preuves »* named `account.provider_id` = `"credential"`. The code declared
provisioning complete after checking two of three conditions, so the CLI
reported success for an account that could not sign in. The author: *"je
vérifiais deux des trois conditions et j'ai manqué la troisième."* We reviewed
that commit, `0618b01`, and did not raise it.

