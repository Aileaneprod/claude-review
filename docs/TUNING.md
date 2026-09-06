# Tuning

How to make the reviewer quieter, sharper, or cheaper — and how to know whether
a change helped rather than just feeling like it did.

## Before anything else: run the tests

```bash
./scripts/test/run-tests.sh          # all cases
./scripts/test/run-tests.sh --case resolve-config --verbose
```

`scripts/` had no tests until three defects reached commits in a single
session, each one past a check that could not fail: a `language` guard proved
against a 65-character payload while admitting a 32-character instruction, a
denial reporter whose fixture used a message shape the API never emits, and a
counter that counted attempted comments as posted ones. The person writing the
check chose the input, so the input agreed with them.

Hence the rule for `scripts/test/`: **a case is only worth adding if it fails
against the code that had the bug.** Write it, watch it go red, then fix. The
existing cases are all real defects, so they double as the record of what has
already gone wrong.

CI (`.github/workflows/ci.yml`) runs these plus `bash -n`, a YAML parse, the
stub eval and the `learnings.md` size budget on every push and pull request. No
model calls, so it costs nothing and gates everything.

## Then: lint the workflows

Any change to a `.yml` under `.github/workflows/` or to `templates/wrapper.yml`
must pass [actionlint](https://github.com/rhysd/actionlint):

```bash
actionlint .github/workflows/*.yml
```

This is not optional politeness. A context that does not exist — a
`github.job_workflow_ref` that is only an OIDC claim, a `secrets` reference in a
job-level `if:` — is accepted by every YAML parser and by GitHub's own editor,
then fails at runtime on every single review. actionlint catches both instantly;
`python3 -c "import yaml"` catches neither.

To lint the wrapper template, copy it into a real workflows path first —
actionlint keys some checks off the file location:

```bash
mkdir -p /tmp/lint/.github/workflows
cp templates/wrapper.yml /tmp/lint/.github/workflows/ai-review.yml
(cd /tmp/lint && actionlint .github/workflows/ai-review.yml)
```

## Memory: how the reviewer learns

The reviewer has a memory, and it is a plain markdown file injected into every
prompt. There is no fine-tuning and no hidden state — if the reviewer knows
something, it is because a human wrote it down here.

Two files, both optional:

| file | scope |
|---|---|
| `prompts/learnings.md` (this repo) | lessons that generalise across repositories |
| `.claude-review/learnings.md` (target repo) | that repo's own conventions |

### The loop

```bash
./scripts/harvest-feedback.sh --repo OWNER/REPO --pr 13
./scripts/propose-learnings.sh --reviewer all
```

`harvest-feedback.sh` records what actually happened to every finding — the
author's reply verbatim, whether the thread was resolved, whether the code
underneath changed, and the commit the finding was anchored to. It writes
`feedback/<owner>/<repo>/<pr>.json` and nothing else; it never touches prompts.

`propose-learnings.sh` reads the ledger and prints a scoreboard, a draft lesson
for every finding the author rejected, and a list of findings a competing
reviewer got right that we never raised. **You** write the final wording and
open a PR. Nothing is merged automatically.

### Why it is human-gated

A wrong lesson does not spoil one review. It spoils every review in every
repository until somebody notices. This project has already produced a
confident, well-argued, entirely incorrect diagnosis that reached the prompt —
so the gate is not ceremony.

### Judge a past finding against the commit it was made on

The single most important rule in this loop, and the reason `reviewed_commit` is
in the ledger. Once an author fixes a finding, the evidence for it is gone: the
contradiction you would look for is exactly what the fix removed. Re-checking
against the branch tip therefore scores **correct** findings as false positives.

That is not hypothetical — it happened here, on `Aileaneprod/korbyx#13`, and led
to a true positive being reported as a failure and prompt rules being written on
the strength of it.

### The author is already labelling your findings

You do not need to build a labelling pipeline. On a healthy PR the author
replies to each finding with a verdict in plain words — *"Corrigé en 74083ff, et
le constat est juste"*, *"Écarté"*, *"Appliqué à moitié"*. `verdict_guess`
classifies those heuristically for the scoreboard, but `human_reply` always
keeps the raw text, because the guess is a hint for a human and never a
decision.

The heuristic reads the **first word** before falling back to a keyword search,
so a repository that asks its authors to open every reply with one word gets an
exact label instead of a guess. `Aileaneprod/korbyx` mandates four — *Retenu*,
*Écarté*, *Partiel*, *Vu* — after 46 of its 148 verdicts had to be re-read by
hand. Without that rule the search runs over the whole reply, and *"Retenu — le
faux positif est sur le point voisin"* scores as a rejection. Ask for the word;
it costs the author nothing and it is the only thing that makes the scoreboard
countable.

### Keeping memory from becoming bloat

Every line is read on every review, so it costs quota and competes for attention
with the diff. Delete lessons that have stopped earning their place. A lesson
that only ever applied to one repository belongs in that repository's file, not
the global one.

## The one rule for prompts

**Change the prompt, run the eval, compare.** A prompt edit that feels like an
improvement very often trades a false positive for a missed defect. The harness
exists so that trade is visible instead of invisible.

```bash
./eval/run-eval.sh            # stub mode, free, checks the harness itself
./eval/run-eval.sh --live     # real model calls, spends quota
```

Every fixture carries a planted defect **and** a decoy — something that looks
wrong but is correctly handled elsewhere in the same file. `must_find` measures
recall; `must_not_find` measures precision. Fixture 11 has no defect at all, so
any finding on it is a false positive by definition.

A run is a regression if any expected finding is missed or any decoy is hit, and
the script exits non-zero on either.

### Local live runs are advisory, not authoritative

`claude --bare` is the documented way to get reproducible runs, but it **does
not read `CLAUDE_CODE_OAUTH_TOKEN`** — it needs an API key, which bills credits
instead of subscription. On subscription auth we cannot use it, so a local
`--live` run inherits this machine's `CLAUDE.md`, MCP servers, and hooks, all of
which perturb the result.

So: **the authoritative baseline is the `Prompt eval` workflow on a clean
runner.** Run it from the Actions tab with `live: true`. Treat a local score
that drifts from CI as a local-environment artefact until CI agrees.

## Which knob to turn

| Symptom | Change |
|---|---|
| Too many comments | Lower `max_findings` (12 → 6). Blunt but immediate. |
| Comments are trivial | Tighten the nit rule in `prompts/base.md`, or cut the nit cap from 3 to 1 |
| Wrong findings on one stack | Edit that `prompts/profiles/*.md`, not `base.md` |
| Flags things a linter owns | Add the linter to grounding rule 5 |
| Misses a defect class you care about | Add it to the matching profile, then add a fixture |
| Reviews cost too much | Lower `max_turns` (20 → 12). Fewer turns means less file-reading, so expect precision to drop |
| Huge PRs get shallow reviews | Raise `max_diff_lines`, or accept triage mode |

Set these in `config/defaults.yml` for everywhere, or `.claude-review.yml` for
one repo. Precedence: `defaults.yml` < workflow inputs < the repo's own file.

## Choosing a model

`model` is empty by default, which lets `claude-code-action` use its own
default. That is usually the right answer and is why nothing is pinned.

**Do not copy a model ID from memory or from an old example — they change and go
away.** Read the current IDs from the official Claude Code documentation, then
set it explicitly if you want to:

```yaml
model: "the-current-id-from-the-docs"
```

It is passed through as `--model` inside `claude_args`. The action has no
`model` input; that was removed, along with `max_turns`, `allowed_tools`, and
the other former top-level inputs. Everything goes through `claude_args` now.

A smaller model is cheaper per review and noticeably worse at the thing that
matters most here — grounding a finding by reading surrounding code rather than
pattern-matching the diff. If you downgrade, run the eval and watch the decoy
column.

## Editing prompts

`prompts/base.md` is the contract: role, severity taxonomy, grounding rules,
output format. `prompts/profiles/*.md` are stack-specific checklists appended to
it. Keep stack specifics in profiles — `base.md` applies to everything.

Placeholders substituted by `build-prompt.sh`: `{{REPO}}`, `{{PR_NUMBER}}`,
`{{MAX_FINDINGS}}`, `{{PROFILE_BLOCK}}`, `{{TRIAGE_NOTE}}`, `{{EXCLUDED_PATHS}}`,
`{{PRIOR_FINDINGS}}`, `{{CHANGED_FILES}}`. An unsubstituted placeholder fails
the build rather than reaching the model.

Preview the assembled prompt without running anything:

```bash
./scripts/resolve-config.sh > /tmp/cfg.json
printf 'src/example.py\n' > /tmp/files.txt
./scripts/build-prompt.sh --config /tmp/cfg.json --repo me/demo --pr 1 \
  --changed-files /tmp/files.txt --profiles python-fastapi --out /tmp/prompt.md
```

### Writing a good profile entry

Describe the failure mode, then say what the *correct* form looks like. Without
the second half you are training false positives — half the profile entries here
carry a "*Not a finding if*" clause for exactly that reason.

## Adding a fixture

Any defect class worth adding to a profile is worth a fixture.

1. `eval/fixtures/NN-name/` — the source file(s), containing the defect **and** a
   decoy, plus `changes.diff`.
2. `eval/expected/NN-name.json` — `profile`, `must_find`, `must_not_find`. Give
   every entry an `id` and a `why` explaining the decoy.
3. `eval/stubs/NN-name.json` — a canned response so stub mode still runs free.

Keyword matching notes, learned the hard way: decoys are matched against the
finding's **title and evidence only**, not its explanatory prose, because a good
finding often names the decoy by way of contrast ("unlike `fetch_logo`, which is
threadpooled"). Decoys are also checked **before** `must_find`, so a reviewer
cannot score a true positive for flagging the exact thing planted to catch it.
Keep `must_find` keywords specific to the real defect — a keyword that also
appears in the decoy's legitimate code makes the fixture unable to fail.

## Version discipline

Callers pin `@v1`, a moving tag. Re-tagging ships to every repo at once:

```bash
git tag -fa v1 -m "claude-review v1" && git push --force origin v1
```

Run the eval on CI first. Immutable `v1.0.x`-style tags exist on
`anthropics/claude-code-action` if you ever want to pin the action itself rather
than tracking `@v1` — worth considering, since its input surface has already
changed once in a breaking way.

## What is deliberately not tunable

- **The reviewer cannot write.** `--allowedTools` grants read and comment tools
  only. Do not add `Edit`, `Write`, or unrestricted `Bash`.
- **Fork PRs are never reviewed.** See [ARCHITECTURE.md](ARCHITECTURE.md).
- **The review step never blocks a merge** unless you opt in with
  `fail_on_blocking`. Think hard before giving an AI reviewer merge authority.
