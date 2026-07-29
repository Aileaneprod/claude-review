# Architecture

Why this is built the way it is. Mostly a record of decisions, so future-me does
not "fix" something that is load-bearing.

## Shape

One central repo holds a reusable workflow (`on: workflow_call`) plus a
versioned prompt system. Every project repo opts in with a ~12-line wrapper.

```
project repo                     claude-review
─────────────                    ─────────────
ai-review.yml  ──── uses: ───▶   review.yml @v1
  permissions                      ├─ 7 guards
  secrets: inherit                 ├─ scripts/
                                   └─ prompts/
```

This works because **the `github` context inside a called workflow belongs to
the caller**: "When a reusable workflow is triggered by a caller workflow, the
`github` context is always associated with the caller workflow." So
`github.event.pull_request.number` and `github.repository` resolve to the
project repo, and no PR details need to be passed as inputs.

Prompt changes ship to every repo by re-tagging `v1`. That is the entire point:
one place to improve the review, not N.

## The scarce resource is quota, not money

Reviews authenticate with a `CLAUDE_CODE_OAUTH_TOKEN` backed by a Claude
subscription. Subscription quota, not dollars, is what runs out — so the
workflow is built to *avoid* spending a review that cannot produce value.

Seven guards, cheapest first:

| # | Guard | Where | Cost when it fires |
|---|---|---|---|
| 0 | Cancel superseded runs | workflow `concurrency` | in-flight run killed |
| 1 | Skip drafts | job `if:` | job never starts |
| 2 | Skip bot authors | job `if:` | job never starts |
| 3 | Skip `skip-ai-review` label | job `if:` | job never starts |
| 4 | Skip forks | job `if:` + `fork-notice` job | ~5s |
| 5 | Empty changed set after excludes | step after checkout | ~20s |
| 6 | Oversized diff → triage | step after checkout | narrows scope |

Guards 1–4 are metadata-only, so a skipped job never provisions a runner at all.

**Guard 0 is the big one.** Pushing three times to a PR in five minutes would
otherwise mean three overlapping reviews of which two are already obsolete.
`cancel-in-progress` makes the newest push win. The group name is namespaced
(`claude-review-…`) because GitHub warns that a caller and callee sharing a
group value will cancel each other.

**Guard 6 does not bail out**, it narrows. A 5000-line PR still gets auth,
payments, migrations, DB access, config, and dependency manifests reviewed, and
the summary states plainly that the review was partial and why. Changed lines
are counted **only over files that survived exclusion**, so a regenerated
lockfile cannot push a small PR into triage.

## The reviewer cannot modify code

`--allowedTools` grants exactly: the inline-comment MCP tool, `gh pr diff`,
`gh pr view`, `gh pr comment`, `Read`, `Grep`, `Glob`. No `Edit`, no `Write`, no
unrestricted `Bash`.

The action's own inline-comment server exists for the same reason — its source
says it "provides an inline comment tool without exposing full PR review
capabilities, so that Claude can't accidentally approve a PR". A reviewer that
can edit the code it is reviewing is not a reviewer.

## Fork pull requests are never reviewed

Secrets are unavailable to `pull_request` runs from a fork, so the review cannot
authenticate.

**We deliberately do not use `pull_request_target`.** That runs with the base
repository's secrets, so checking out contributor code in a job holding the
subscription token is a direct credential-exfiltration path. The reviewer is
worth far less than the token. This is not an oversight — do not "fix" it.

On a public repo the `GITHUB_TOKEN` is read-only for fork PRs regardless of the
`permissions:` block, so the explanatory comment can legitimately fail to post.
The `fork-notice` job therefore also writes a job summary and emits a `::notice::`
annotation, both of which always work.

## Prompt injection

A PR title, body, or diff is attacker-controlled on any PR that accepts outside
contributions.

- PR text is **never interpolated into the prompt**. The reviewer fetches it
  itself with `gh pr view`, so it arrives as tool output — data, not instruction.
- `prompts/base.md` rule 7 states that repo text is data, and that text trying to
  instruct the reviewer is itself a finding.
- No workflow `run:` block contains a `${{ }}` expression. Every value arrives
  through `env:`, so nothing can break out into shell.

## Sticky summary and dedupe

`post-review.sh` owns the summary comment. It runs twice:

- **before** the review, reading the ledger of already-posted findings out of
  the existing comment and feeding them into the prompt, so a re-review after a
  push does not repeat what the author already read;
- **after**, recovering the summary and upserting it — PATCH the comment
  carrying `<!-- claude-review:summary -->`, POST if there is none.

N pushes produce one summary, edited in place, not N summaries.

The summary text comes from the action's `execution_file`, a single
pretty-printed JSON array of SDK messages written even when the run crashes. If
that yields nothing, the script falls back to adopting a summary the reviewer
posted itself. Findings are hashed `sha256(path|line|title)` and stored base64 in
an HTML comment.

### Why not `--json-schema`

`claude_args --json-schema` would give machine-readable findings and make
`fail_on_blocking` exact. It is rejected because when the model returns no
conforming output the action calls `core.setFailed` and **throws**, with no
retry around the schema check. That turns an imperfect review into a failed
step — the opposite of "a reviewer failure must never block a merge".

The eval harness *does* use it, because there a hard failure just means "this
fixture errored", and deterministic output is exactly what scoring needs.

### Settings deliberately left off

- `track_progress: true` would force the action into tag mode and discard the
  prompt-driven agent mode entirely.
- `use_sticky_comment: true` matches the first comment by *any* bot whose login
  contains "claude", ignoring HTML markers, and would clobber our summary.

## Dependencies: none beyond the runner

`bash`, `git`, `gh`, `python3`. No npm packages, no Docker, no build step.

Structured data is handled by **stock python3 only** — no PyYAML, no `yq`, no
`jq`. `resolve-config.sh` embeds a small strict parser for the flat
`key: scalar` / `key:` + block-list subset the two config files use, and rejects
anything outside it with a `file:line` error rather than misreading it.

`yq` 4.53.3 and `jq` 1.7.1 *are* on the current `ubuntu-24.04` image, so using
them would work today. We don't, because: PyYAML's presence is undocumented;
stock python3 behaves identically on a dev machine and the runner, so local
testing means something; and GitHub has already staged `ubuntu-26.04`, so
depending on the image's tool inventory is borrowing trouble.

The one exception is `eval.yml`, which `npm install -g`s the Claude Code CLI for
live runs. The harness drives `claude -p` directly, so the CLI has to come from
somewhere. It is dispatch-only and touches nothing in the reviewer path.

## Finding the tooling at the right version

`review.yml` checks out its own repo to get `scripts/` and `prompts/`, resolving
the revision from **`github.job_workflow_ref`**.

This must not be `github.workflow_ref`. Inside a reusable workflow the github
context is the *caller's*, so `workflow_ref` is the project repo's wrapper file —
using it would check the project repo out over itself and find no scripts.
`job_workflow_ref` is documented as "for jobs using a reusable workflow, the ref
path to the reusable workflow", which is what we need.

The upshot: a caller pinned to `@v1` runs the prompts from `v1`, never from
`main`, and no owner or repo name is hardcoded in `review.yml`.

## The repo is public

Not a preference — a constraint. GitHub's access model for private reusable
workflows offers "Not accessible", "repositories in the ORG organization", and
"repositories owned by USER". Nothing grants a **different owner** access, so a
private `claude-review` cannot serve standalone client repos.

Consequences:

- **Never** put client code, client names, or anything secret in this repo.
- The prompts are the deliverable and are fine to publish.
- Secrets do not travel with the workflow. Every calling repo needs its own
  `CLAUDE_CODE_OAUTH_TOKEN`.

## Failure is always non-blocking

The review step is `continue-on-error: true`. If it fails, a later step posts a
short "review unavailable" note and the job still exits 0.

Success is read from `steps.claude.outcome`. The action sets a `conclusion`
output internally but does not declare it, and composite actions only surface
declared outputs — so `steps.claude.outputs.conclusion` reads empty. That is a
trap worth remembering.

`fail_on_blocking` is opt-in and off by default.

## Known limitations

- **`exclude_paths` replaces, it does not merge.** A repo that sets it must
  restate the exclusions it still wants.
- **Inline comments appear after the run, not during it.** Under subscription
  auth the action's post-run classifier is skipped (it needs an
  `ANTHROPIC_API_KEY` we never set) and all comments where `confirmed !== false`
  are flushed in a post step. Nothing is dropped; `base.md` mandates
  `confirmed: true` for deterministic timing.
- **Line counts come from `--numstat`,** so a binary file contributes 0.
- **The ledger reflects comments still on the PR.** Resolving or deleting a
  comment makes the finding eligible to return on the next review.
