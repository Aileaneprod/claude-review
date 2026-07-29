# Setup

The steps only you can do, in order. Nothing here is automated, on purpose —
these touch credentials and org settings.

Budget about 15 minutes for steps 1–6, then a minute per repo after that.

---

## 0. Owner — already set

Everything points at **`jdfyras`**, so there is nothing to substitute.
`templates/wrapper.yml` reads:

```yaml
    uses: jdfyras/claude-review/.github/workflows/review.yml@v1
```

To move the repo under one of your orgs instead (`Gear-Five-5`, `Aileaneprod`),
change that one line and the remote in step 1. Everything else is
owner-agnostic — `review.yml` resolves its own repo and ref at runtime from
`github.job_workflow_ref`, so no owner is hardcoded anywhere in the workflow
itself.

`scripts/install-wrapper.sh` still refuses to run if it ever finds an
unreplaced `[GITHUB_OWNER]` in the template, so a half-configured clone cannot
emit a broken wrapper.

## 1. Push this repo to GitHub — **public**

```bash
gh repo create jdfyras/claude-review --public --source=. --remote=origin --push
```

Or manually:

```bash
git remote add origin git@github.com:jdfyras/claude-review.git
git push -u origin main
```

**It has to be public.** A private reusable workflow can only be called from
repositories owned by the same account or org — the access options are "Not
accessible", "repositories in the ORG organization", and "repositories owned by
USER". Nothing grants a *different owner* access. Since some of your repos are
standalone client repos owned by the client, a private `claude-review` simply
cannot serve them.

Public is safe here: this repo holds prompts, shell scripts, and workflow YAML.
No client code, no client names, no secrets. Keep it that way — see
[ARCHITECTURE.md](ARCHITECTURE.md#the-repo-is-public).

## 2. Mint the subscription token

Run locally, on a machine already logged into Claude Code:

```bash
claude setup-token
```

This prints a one-year OAuth token and **saves it nowhere** — copy it before
closing the terminal. It requires a Pro, Max, Team, or Enterprise plan; it
authenticates against your subscription rather than API credits.

Do not commit it, do not paste it into a file, do not echo it in a script.

## 3. Store it as a secret

**`jdfyras` is a personal account, and GitHub has no user-level Actions
secrets** — they exist only at organization, repository, and environment scope.
So for any repo owned by `jdfyras`, the secret goes on that repo directly:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo jdfyras/some-project
```

Same for a client repo you have admin on:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo CLIENT-ORG/their-repo
```

You *do* have two orgs, and repos inside them can share one secret:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org Gear-Five-5 --visibility all
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org Aileaneprod --visibility all
```

All of these prompt for the value rather than taking it as an argument, which
keeps it out of your shell history.

**Secrets never cross repositories.** Every repo that runs a review needs this
secret available to it. Making `claude-review` public shares the *workflow*,
not the credential — which is exactly the property that makes publishing safe.

A quick way to see which of your repos still need it:

```bash
gh repo list jdfyras --limit 100 --json nameWithOwner --jq '.[].nameWithOwner' \
  | while read -r r; do
      gh secret list --repo "$r" 2>/dev/null | grep -q CLAUDE_CODE_OAUTH_TOKEN \
        || echo "missing: $r"
    done
```

## 4. Install the Claude GitHub App

Visit **https://github.com/apps/claude** and install it on the `jdfyras`
account (and on `Gear-Five-5` / `Aileaneprod` if you review repos there),
selecting the repositories you want reviewed.

The action authenticates through this app using the OIDC token, which is why
every caller declares `id-token: write`. Without the app installed, the review
step fails — harmlessly, since it runs with `continue-on-error` and never blocks
a merge.

## 5. Tag v1

Callers pin `@v1`, so the tag must exist before any wrapper works:

```bash
git tag -a v1 -m "claude-review v1"
git push origin v1
```

`v1` is a moving tag. When you change prompts and want it live everywhere:

```bash
git tag -fa v1 -m "claude-review v1" && git push --force origin v1
```

Run the eval first — see [TUNING.md](TUNING.md).

## 6. Confirm cross-repo access

Public repos need nothing further, which is the whole reason step 1 says public.

If you ever make this repo private, go to **Settings → Actions → General →
Access** and choose **"Accessible from repositories owned by the 'jdfyras'
user"**. That covers your own repos — but note it does **not** cover client
repos owned by anyone else, and no setting does. Private means client repos
lose reviews entirely.

The default is "Not accessible", which makes every caller fail with a confusing
"workflow was not found" error.

---

## Adding a repo

Dry run first — this prints the diff and writes nothing:

```bash
./scripts/install-wrapper.sh jdfyras/some-repo
```

Then apply. It creates a branch, commits the wrapper, and opens a PR:

```bash
./scripts/install-wrapper.sh jdfyras/some-repo --confirm
```

It is idempotent — re-running against a repo that already has an identical
wrapper exits cleanly without touching anything.

Or do it by hand: copy [`templates/wrapper.yml`](../templates/wrapper.yml) to
`.github/workflows/ai-review.yml` in the target repo.

### Why the wrapper declares permissions

```yaml
    permissions:
      contents: read
      pull-requests: write
      id-token: write
```

A reusable workflow can only ever **downgrade** the caller's token, never
elevate it. GitHub is explicit: "The `GITHUB_TOKEN` permissions passed from the
caller workflow can be only downgraded (not elevated) by the called workflow."

So these have to be declared in the caller. Omit them and the review job runs
with whatever the repo's default happens to be — usually read-only, so the
reviewer silently cannot comment.

`secrets: inherit` passes `CLAUDE_CODE_OAUTH_TOKEN` through.

---

## Per-repo tuning

Drop a `.claude-review.yml` at the repo root. Copy
[`templates/.claude-review.yml`](../templates/.claude-review.yml) and delete
what you do not need.

Precedence, least to most specific:

```
config/defaults.yml  <  workflow inputs  <  target repo .claude-review.yml
```

The file next to the code wins, because it knows most about that code.

---

## Turning it off

- **One PR:** add the `skip-ai-review` label.
- **One repo:** delete `.github/workflows/ai-review.yml`.
- **Everywhere at once:** delete the `v1` tag. Every caller fails to resolve the
  workflow, and since the review job cannot block a merge, nothing else breaks.

---

## When nothing happens

Reviews are skipped by design when the PR is a draft, the author is a bot, the
`skip-ai-review` label is present, every changed file is excluded, or the PR
comes from a fork. The first four are silent; the fork case posts a comment and
always writes a job summary.

| Symptom | Cause |
|---|---|
| "workflow was not found" | `v1` not tagged, or repo private without access configured |
| Review job skipped entirely | Draft, bot author, `skip-ai-review` label, or fork |
| "AI review skipped — pull request from a fork" | Expected. Forks get no secrets; review manually |
| Step fails immediately | `CLAUDE_CODE_OAUTH_TOKEN` missing or expired (tokens last a year) |
| Runs but posts nothing | Genuinely nothing to report — check the job summary |
| Reviewer cannot comment | `permissions:` missing from the wrapper |
