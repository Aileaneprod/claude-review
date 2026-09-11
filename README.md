# claude-review

One centralized AI pull-request reviewer for all my repos. A GitHub **reusable
workflow** plus a versioned prompt system lives here; every project repo opts in
with a 12-line wrapper file. Runs on
[`anthropics/claude-code-action@v1`](https://github.com/anthropics/claude-code-action)
authenticated by a Claude subscription token.

Tuned for **precision over recall** — it stays silent rather than guessing, caps
findings, and never comments on anything a linter already owns.

## Quickstart

**1.** Mint a token and store it as a repo/org secret named
`CLAUDE_CODE_OAUTH_TOKEN` (see [docs/SETUP.md](docs/SETUP.md) for all steps):

```bash
claude setup-token
```

**2.** Drop [`templates/wrapper.yml`](templates/wrapper.yml) into the target repo
at `.github/workflows/ai-review.yml` — it already points at this repo. Or let
the script do it, dry-run by default:

```bash
./scripts/install-wrapper.sh jdfyras/some-project --confirm
```

**3.** Open a PR. Findings arrive as inline comments plus one sticky summary.

Per-repo overrides go in `.claude-review.yml` — see
[`templates/.claude-review.yml`](templates/.claude-review.yml).

## How it works

The wrapper calls `review.yml` here. Because `github.*` inside a called workflow
resolves to the **caller's** event, the reusable workflow sees the real PR
without being told about it. Seven guards run *before* any model call — the
scarce resource is subscription quota, so a review that can't produce value must
never start. Superseded runs are cancelled, drafts/bots/labelled and fork PRs are
skipped, an empty diff exits early, and an oversized diff degrades to triage mode
over the highest-risk files instead of burning the whole budget. The draft skip
is the one a repository can switch off, with `review_drafts: true`.

The reviewer is granted read and comment tools only — no `Edit`, no `Write`, no
unrestricted `Bash`. It cannot modify code.

```
.github/workflows/review.yml   the reusable workflow (7 guards + model call)
prompts/base.md                severity taxonomy, grounding rules, output contract
prompts/profiles/*.md          per-stack checklists (fastapi, ts, rn, n8n, generic)
config/defaults.yml            excludes, caps, thresholds
scripts/*.sh                   config merge, profile detect, prompt build, comment post
eval/                          fixtures with planted defects + decoys, precision/recall
templates/                     wrapper.yml and .claude-review.yml to copy out
docs/                          SETUP, TUNING, ARCHITECTURE
```

## Docs

- [SETUP.md](docs/SETUP.md) — the human steps, in order
- [TUNING.md](docs/TUNING.md) — dialling noise up or down, model selection
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — why it's built this way

MIT licensed.
