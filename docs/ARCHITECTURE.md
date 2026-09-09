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
  secrets: {token}                 ├─ scripts/
                                   └─ prompts/
```

This works because **the `github` context inside a called workflow belongs to
the caller**: "When a reusable workflow is triggered by a caller workflow, the
`github` context is always associated with the caller workflow." So
`github.event.pull_request.number` and `github.repository` resolve to the
project repo, and no PR details need to be passed as inputs.

The wrapper passes exactly one secret, named explicitly:

```yaml
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

not `secrets: inherit`. `review.yml` only needs the one token, and `inherit`
would forward every other secret the calling repo happens to have into a job
it doesn't control. That mostly doesn't matter on a private repo, but several
project repos here are public, and Actions logs on a public repo are public —
an unrelated inherited secret leaking through a stray debug print in a future
step would be a real problem, where the same mistake with only the Claude
token present is not. Same principle as the `--allowedTools` restriction and
the fork guard: grant exactly what's needed, nothing adjacent.

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
| 7 | No `CLAUDE_CODE_OAUTH_TOKEN` on the repo | first step of the job | ~5s |

Guards 1–4 are metadata-only, so a skipped job never provisions a runner at all.

**Guard 0 is the big one.** Pushing three times to a PR in five minutes would
otherwise mean three overlapping reviews of which two are already obsolete.
`cancel-in-progress` makes the newest push win.

It is declared **twice on purpose** — once here in `review.yml`
(`claude-review-…`) and once in the caller, `templates/wrapper.yml`
(`ai-review-…`). That is not an oversight:

- Whether a top-level `concurrency` block inside a *called* workflow governs the
  run is **not stated anywhere in GitHub's documentation**. Community reports say
  it works; the docs are silent. This guard is the single biggest quota saver in
  the design, so relying solely on undocumented behaviour is a poor trade.
- Declaring it in the caller, which is an ordinary workflow, is unambiguously
  specified and guaranteed to work.
- The two group names must **differ**, which is why one is `claude-review-…` and
  the other `ai-review-…`. GitHub warns that a caller and callee sharing a group
  value with `cancel-in-progress` will cancel each other.

Guard 7 (missing credential) lives in a step rather than a job `if:`, because the
`secrets` context is unavailable in `jobs.<job_id>.if` — see the wrapper's own
comments.

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

`review.yml` checks out its own repo to get `scripts/` and `prompts/`. Which
revision is **not inferable at runtime**, so it is passed as the `tooling_ref`
input (default `v1`), alongside `tooling_repo` (default `Aileaneprod/claude-review`).

That looks like avoidable duplication — the caller already names the ref in
`uses:` — so it is worth recording why inference does not work, because the
obvious attempts both fail:

- **`github.workflow_ref`** is the *caller's* wrapper file. The github context
  inside a called workflow belongs to the caller, so using this would check the
  project repo out over itself and find no scripts.
- **`github.job_workflow_ref`** looks exactly right — GitHub documents
  `job_workflow_ref` as "for jobs using a reusable workflow, the ref path to the
  reusable workflow". **But that is an OIDC token *claim*, not a `github`
  context property.** In a workflow expression it resolves to an empty string.

The second one was the original implementation, and it made **every review fail
at the first step** until a run log was actually read:

```
env:
  JOB_WORKFLOW_REF:
##[error]github.job_workflow_ref is empty.
```

The runner prints the value we want (`Uses: owner/claude-review/...@refs/tags/v1
(112aa2ef...)`) but does not expose it to expressions. Hence the explicit input.

Two consequences worth knowing:

- A caller that pins `uses: ...@v1` gets `tooling_ref: v1` by default, so ref and
  tooling stay in sync with no boilerplate. A caller pinning something else must
  set `tooling_ref` to match, or it will run one version's workflow against
  another version's prompts.
- `self-review.yml` passes `tooling_ref: ${{ github.event.pull_request.head.sha }}`
  so dogfooding exercises the prompts *in the pull request*, not the released
  ones. Without that override it would silently test the wrong thing.

**Lesson recorded deliberately:** "documented as an OIDC claim" is not the same
as "available in the `github` context", and `actionlint` catches exactly this
class of mistake (`property "job_workflow_ref" is not defined in object type…`).
It is now part of the verification pass.

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

The review step is `continue-on-error: true`. If nothing gets posted, a later
step posts a short note saying so and the job still exits 0.

Two separate questions decide what the author is told, and neither is the
reviewer step's exit code.

**Did the reviewer finish?** `classify-run.sh` reads the last `result` record
out of the execution file and requires `subtype == "success"` with `is_error`
exactly `False`. The `Classify the review outcome` step writes `unavailable` to
disk before calling it, so anything unestablished stays unestablished.

**Did a comment actually land?** Only `post-review.sh` knows, and it says so in
`--posted-out`. The notice fires on `!= 'true'`, so a skipped step, a crashed
step and a deliberate "nothing worth posting" all reach the author.

This used to be one question — `steps.claude.outcome` — asked twice, and the
answer stopped meaning what both readers assumed. `claude-code-action` checks
`num_turns` after the run and fails the step when it overran `--max-turns`,
even when the CLI reported success. On Aileaneprod/korbyx#110, run 34058925818,
a review that had finished (`terminal_reason: completed`, 43 turns, $0.87) was
announced as "AI review unavailable" and discarded.

Do not fold the two back together. The action writes the execution file about
9 ms before it flushes buffered inline comments, so nothing in that file can
witness whether the findings reached GitHub — "the reviewer finished" and "the
author can see it" are genuinely different facts. Two conditions derived from
one signal also drift: they can both speak, or both stay silent.

Known limitation: if that flush step itself fails, the reviewer will have
finished, `post-review.sh` will post a summary with counts, and the inline
comments those counts refer to will not be on the diff. Nothing currently
detects it. Cross-checking the live review comments against the transcript
would, and is not built.

`steps.claude.outputs.conclusion` reads empty, whatever the action does
internally: it sets a `conclusion` output but does not declare it, and
composite actions only surface declared outputs. That is a trap worth
remembering even though nothing depends on it now.

`fail_on_blocking` is opt-in and off by default.

### Non-blocking is not the same as silent

The job concludes `success` even when no review happened, and it has to: the
merge must not depend on a third-party service being up. But a green check is
read as "the reviewer looked and found nothing", and on Aileaneprod/korbyx#131
that reading was wrong three times in a row and the pull request was merged on
it. The step summary, the annotation and the notice comment all said the truth;
none of them is what a reviewer looks at.

So the notice step also publishes a check run of its own, `AI review outcome`,
concluded `neutral`. Grey sits next to green in the merge box and says which of
the two things happened.

**The job itself cannot be `neutral`.** Measured, not remembered, on
theo986/claude-review run 34414488366:

| what was tried | job conclusion |
| -- | -- |
| `exit 78` | `failure` |
| job-level `continue-on-error` + `exit 1` | `failure` |
| `POST /check-runs` with `conclusion=neutral` | a check run genuinely `neutral` |

The neutral exit code went away when Actions left HCL and nothing replaced it.
A separate check run is the closest thing that exists.

**Which is why `review.yml`'s review job has no `permissions:` block.** A block
in a called workflow is exhaustive — anything it does not list is `none`, even
when the caller granted it (run 34415311149). And a called workflow that asks
for more than its caller granted does not degrade: the entire run is
`startup_failure` before any job starts (run 34415031622). Since `@v1` is a
moving tag, declaring `checks: write` there would have broken every consuming
repository at the retag rather than when each of them opted in. With no block,
the job inherits the caller's grant (run 34415220299), the wrapper is the one
place that decides, and a wrapper without `checks: write` gets a plain 403 that
`publish-outcome-check.sh` reports and does not fail on.

The notice comment is deliberately **not** sticky, unlike the summary. It says
"no summary was posted for this push", which is a fact about one push; three
pushes that went unreviewed are three separate facts and collapsing them would
erase two. The check run is the opposite — it is addressed by name on the head
SHA, so a re-run of the same push updates it in place instead of stacking, and
a re-run that then reviews the commit successfully turns the grey check green
rather than leaving it to contradict the summary that just landed. That
correction only ever updates a check run an earlier attempt published; a review
that worked the first time creates nothing.

## The eval harness cannot catch environment-assumption errors

Worth stating plainly, because it was learned the hard way. Every fixture in
`eval/` is a self-contained snippet: the reviewer's job is to reason about code
it can read. That measures code reasoning, and it measures the anti-false-positive
rules — but only for claims whose evidence is *in the file*.

It cannot measure the other failure mode: a finding whose premise is a fact
about the **repository**, guessed rather than checked. The reviewer's first real
inline finding in production was exactly this — a confident 🔴 Blocking claim
that the default branch was `main` (it was `develop`), built on a comment in the
file describing the general case. The code reasoning on top of that premise was
sound. The premise was invented, so the finding was worthless.

Root cause was a tooling gap as much as a prompt gap: `gh repo view` was not in
`--allowedTools`, so the reviewer *could not* check the default branch even if
it had wanted to. It is now, and `base.md` rule 8 requires checking rather than
assuming. But the harness still will not catch a regression here, because
fixtures have no repository around them. Watch for it in real reviews instead.

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
