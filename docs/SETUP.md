# Setup

A complete, copy-paste walkthrough. No prior knowledge assumed — every command
is explained before you run it, every step says what success looks like, and
what to do if it doesn't.

Run everything from a **Git Bash** terminal (or WSL/macOS/Linux) inside the
`claude-review` folder, unless a step says otherwise. `git`, `gh`, and `claude`
work identically in PowerShell too, except the one script in step 8 that uses a
bash `while` loop.

**Current status of this specific setup**, checked just now:

| Item | Status |
|---|---|
| Repo pushed to GitHub | ✅ done — `https://github.com/jdfyras/claude-review` is public |
| Subscription token minted | ❌ not yet — step 2 |
| Token stored as a secret | ❌ not yet — step 3 |
| Claude GitHub App installed | ❌ not yet — step 4 |
| `v1` tag created | ❌ not yet — step 5 |
| A project repo wired up | ❌ not yet — step 7 |

So you can skip straight to **step 2**. Step 1 is included below anyway, so
this document is complete on its own and you can hand it to someone else
starting from zero.

Total time: about 15 minutes for steps 1–6, then 2 minutes per project repo
after that (steps 7–8).

---

## Before you start: check your tools

Run each of these. Expected output is shown; if yours differs, the fix is
underneath.

**1. Git**

```bash
git --version
```
Expect: `git version 2.x.x` (any recent version is fine).
If you get "command not found": install Git from https://git-scm.com/downloads.

**2. GitHub CLI (`gh`)**

```bash
gh --version
```
Expect: `gh version 2.x.x`.
If missing: `winget install --id GitHub.cli` (Windows), or see
https://cli.github.com/.

**3. `gh` is logged in**

```bash
gh auth status
```
Expect a line starting `✓ Logged in to github.com account jdfyras`.
If not logged in:
```bash
gh auth login
```
and follow the prompts (choose GitHub.com → HTTPS or SSH → login via browser).

**4. Claude Code CLI**

```bash
claude --version
```
Expect: `2.x.x (Claude Code)`.
If missing: see https://code.claude.com/docs/en/quickstart for install
instructions for your platform.

**5. You have a paid Claude plan**

`claude setup-token` (step 2) only works on **Pro, Max, Team, or Enterprise**.
If you're not sure which plan you're on, run `claude` and check, or look at
https://claude.ai/settings/billing.

Once all five check out, continue below.

---

## What you're setting up, in one paragraph

`claude-review` is a shared recipe for AI pull-request review. Any repo that
wants it adds a tiny 12-line file (a "wrapper workflow") that says "run the
review recipe from `claude-review`." That recipe needs one credential — a
token proving you have a Claude subscription — stored as a GitHub "secret" (an
encrypted variable GitHub injects into the workflow, never shown in logs). The
steps below: get that token, store it, and turn the recipe on.

---

## Step 1 — Push `claude-review` to GitHub, publicly

**Already done for this setup** — verified: `jdfyras/claude-review` exists and
is public. Skip to step 2.

*(Included for completeness / for redoing this from scratch elsewhere.)*

```bash
gh repo create jdfyras/claude-review --public --source=. --remote=origin --push
```

If the repo already exists on GitHub but isn't linked locally:
```bash
git remote add origin git@github.com:jdfyras/claude-review.git
git push -u origin main
```

**Why public, specifically:** GitHub will only let a *private* reusable
workflow be called by other repos owned by the exact same account or
organization. There is no setting that grants a different owner access. Since
you review client repos owned by other people, a private `claude-review`
cannot serve them — it has to be public.

This is safe because the repo contains only prompts, shell scripts, and
workflow YAML. No client code, no client names, no secrets ever go in here —
see [ARCHITECTURE.md](ARCHITECTURE.md#the-repo-is-public) for the reasoning,
and keep it that way going forward.

**Check it worked:**
```bash
gh repo view jdfyras/claude-review --json visibility,url
```
Expect: `"visibility":"PUBLIC"` and the URL.

---

## Step 2 — Get your Claude subscription token

This token lets GitHub Actions run Claude on your behalf, billed against your
subscription (not a separate API bill).

```bash
claude setup-token
```

This opens a browser to confirm, then prints a long token string directly in
your terminal, starting with something like `sk-ant-oat01-...`.

**Important:**
- It is shown **once** and saved **nowhere** — if you lose it, run the command
  again to get a new one.
- It's valid for **one year**.
- **Select and copy it right now**, before doing anything else in this
  terminal (don't run other commands that might scroll it out of view).
- **Never** paste it into a file in this repo, a chat message, a commit, or an
  `echo`/`print` statement anywhere. Treat it like a password.

Keep it in your clipboard (or a password manager) for the next step.

**If the command fails** with something like "requires a paid plan": your
account isn't on Pro/Max/Team/Enterprise — check
https://claude.ai/settings/billing.

---

## Step 3 — Store the token as a GitHub secret

A "secret" is an encrypted value GitHub stores per-repo (or per-org) and
injects into workflow runs as an environment variable. It's never visible in
logs, never visible to people browsing the repo, and different from ordinary
repo settings.

**Important wrinkle for your account specifically:** `jdfyras` is a *personal*
GitHub account, and personal accounts have **no "org-wide" secret** — that
feature only exists for organizations. So for any repo owned by `jdfyras`
directly, you set the secret on *that repo*, one at a time.

### 3a. For a repo owned by `jdfyras`

Replace `some-project` with the actual repo name:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo jdfyras/some-project
```

Since no value is given on the command line, `gh` prompts you to enter it
interactively. Paste the token from step 2 and press Enter — the input is
masked, so nothing visibly appears as you paste, which is normal.

**Check it worked:**
```bash
gh secret list --repo jdfyras/some-project
```
Expect a line: `CLAUDE_CODE_OAUTH_TOKEN   Updated <date>`.

### 3b. For repos inside your two organizations

You *do* belong to two orgs, and organizations **do** support one secret shared
across every repo in them:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org Gear-Five-5 --visibility all
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org Aileaneprod --visibility all
```

Same prompt as above — paste the token, press Enter. `--visibility all` means
every repo in that org can use it (use `--visibility selected` plus
`--repos` if you want to restrict it to specific repos instead).

### 3c. For a client's repo (they own it, you have admin access)

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo CLIENT-ORG/their-repo
```

You need admin (or at least "manage secrets") permission on that repo for this
to succeed.

### 3d. Which repos still need it?

Run this to scan every repo you personally own and flag the ones missing the
secret (needs a bash shell — Git Bash, WSL, macOS/Linux terminal):

```bash
gh repo list jdfyras --limit 100 --json nameWithOwner --jq '.[].nameWithOwner' \
  | while read -r r; do
      gh secret list --repo "$r" 2>/dev/null | grep -q CLAUDE_CODE_OAUTH_TOKEN \
        || echo "missing: $r"
    done
```

It prints nothing for repos that already have it, and `missing: owner/repo`
for the ones that don't.

**One secret per repo, always.** Making `claude-review` public shares the
*recipe*; it never shares the *credential*. Every repo that wants a review
needs its own copy of this secret, set via 3a/3b/3c above.

---

## Step 4 — Install the Claude GitHub App

1. Open **https://github.com/apps/claude** in a browser.
2. Click **Install** (or **Configure** if it's already installed somewhere).
3. When asked which account, choose **jdfyras** — and separately repeat this
   for **Gear-Five-5** and **Aileaneprod** if you'll review repos in those
   orgs too.
4. Choose **"Only select repositories"** and pick the ones you want reviewed
   (or **"All repositories"** if you'd rather it apply automatically to future
   repos too).
5. Click **Install**.

**What this does:** the workflow authenticates to GitHub through this app
using a short-lived token (OIDC), which is why every wrapper file declares
`id-token: write` permission. Without the app installed, the review step
simply fails for that repo — harmlessly. It's built to never block a merge
either way (see `continue-on-error` in `review.yml`).

**Check it worked:** go to `https://github.com/settings/installations` (or
your org's equivalent, `https://github.com/organizations/Gear-Five-5/settings/installations`)
and confirm "Claude" is listed with the repos you selected.

---

## Step 5 — Tag `v1`

Every project repo's wrapper file says `uses: jdfyras/claude-review/...@v1` —
it points at a *tag* called `v1`, not a branch. That tag has to exist before
any wrapper can find it.

```bash
git tag -a v1 -m "claude-review v1"
git push origin v1
```

**Check it worked:**
```bash
git ls-remote --tags origin
```
Expect a line containing `refs/tags/v1`.

### Updating it later

`v1` is meant to move — when you improve a prompt and want every repo using it
to get the update immediately:

```bash
git tag -fa v1 -m "claude-review v1"
git push --force origin v1
```

**Run the eval first** so you know the change didn't make the reviewer worse —
see [TUNING.md](TUNING.md):
```bash
./eval/run-eval.sh
```

---

## Step 6 — Cross-repo access (only relevant if you ever go private)

Since the repo is public, **there is nothing to do here** — public repos are
automatically callable by anyone. This step only matters if you later flip
`claude-review` to private.

If you do: go to the repo's **Settings → Actions → General → Access**, and
choose **"Accessible from repositories owned by the 'jdfyras' user"**. That
covers repos you personally own — it does **not** extend to your two orgs or
to any client's repos, and nothing does. Going private means client repos lose
reviews entirely. The default, "Not accessible", makes every caller fail with a
confusing "workflow was not found" error, so don't go private without doing
this.

---

## Step 7 — Turn reviews on for a project repo

This is the step you repeat for every repo you want reviewed.

### Option A: the script (recommended)

First, a dry run — this only *prints* what would happen, it writes nothing:

```bash
./scripts/install-wrapper.sh jdfyras/some-project
```

You'll see a diff of the file it would add and a summary like:
```
repo    jdfyras/some-project
base    main
branch  chore/add-ai-review
path    .github/workflows/ai-review.yml
state   absent
```

If that looks right, actually apply it — this creates a branch, commits the
workflow file, and opens a pull request for you to merge:

```bash
./scripts/install-wrapper.sh jdfyras/some-project --confirm
```

Expect output ending with a line like:
```
install-wrapper: opened https://github.com/jdfyras/some-project/pull/1
```

Open that PR link and merge it (or ask a teammate to). Once merged, reviews
are live on that repo.

Re-running the same command later is safe — if the repo already has an
identical wrapper file, it exits immediately and changes nothing.

### Option B: by hand

Copy [`templates/wrapper.yml`](../templates/wrapper.yml) into the target repo
at `.github/workflows/ai-review.yml`, commit, and push (or open a PR) yourself.
The file already points at `jdfyras/claude-review@v1` — nothing to edit.

### It must land on the DEFAULT branch

This one is easy to get wrong and produces a workflow that is present, valid,
and permanently silent.

The Claude GitHub App **refuses to run a workflow whose content differs from the
copy on the repository's default branch.** That is the control that stops a pull
request from rewriting the workflow to steal your token. The run log says:

```
Workflow validation failed. The workflow file must exist and have identical
content to the version on the repository's default branch.
```

Two consequences:

- **On a repo with a `develop` → `main` split, merging into `develop` is not
  enough.** Reviews stay silent until the identical file is on `main` too.
  `install-wrapper.sh` now warns when you pass a `--base` that is not the
  default branch, and prints the second command to run.
- **The pull request that adds the workflow never gets reviewed by it** — its
  copy differs from the default branch by definition. That is expected, not a
  bug. Reviews start on the *next* pull request.

### Don't forget

Before this works on that repo, it also needs:
- **The secret** from step 3 (`gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo ...`)
- **The GitHub App** from step 4 installed on that repo
- **The wrapper on the default branch**, per the section directly above
- **Actions minutes available on the account that owns the repo.** Private
  repositories draw from a monthly allowance; when it is exhausted every run
  fails instantly with `startup_failure` and an empty workflow name, before any
  step executes. Check <https://github.com/settings/billing>. Public repos are
  unlimited, so this only bites private ones.

If either is missing, the review step will fail quietly (it never blocks a
merge) — see the troubleshooting table at the bottom.

---

## Step 8 — Confirm it actually works

Do this once, on one real repo, before rolling out further.

1. In the project repo you just wired up, make a small change on a branch —
   anything real, even a one-line change to a source file.
2. Open a pull request for it.
3. Go to that repo's **Actions** tab in a browser. Within a few seconds you
   should see a workflow run named **"AI Code Review"** start.
4. Click into the run. It should go through steps named things like
   *Resolve claude-review revision*, *Compute reviewed file set*, *Review*,
   *Post the sticky summary*.
5. Back on the pull request, wait for the run to finish (usually well under a
   minute for a small PR). You should see either:
   - one or more inline comments on specific lines, plus one summary comment
     with a severity counts table, **or**
   - just the summary comment saying nothing significant was found — that's a
     valid, good outcome, not a failure.

If nothing shows up at all after a couple of minutes, see the troubleshooting
table below — start with "Runs but posts nothing" and "Step fails immediately."

---

## Ongoing operations

### Per-repo tuning

Drop a `.claude-review.yml` at that repo's root to override defaults just for
it. Start from [`templates/.claude-review.yml`](../templates/.claude-review.yml)
and delete whatever you don't need to change.

Precedence (later wins):
```
config/defaults.yml  <  workflow inputs  <  that repo's own .claude-review.yml
```

### Turning it off

- **One pull request:** add the `skip-ai-review` label to it.
- **One repo:** delete `.github/workflows/ai-review.yml` from it.
- **Everywhere at once:** delete the `v1` tag —
  `git push --delete origin v1` — every caller then fails to resolve the
  workflow. Since the review step never blocks a merge, nothing else breaks.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every run is `startup_failure`, empty workflow name, no jobs, instantly | Actions minutes exhausted on the owning account (private repos only), or Actions disabled for the repo | Check <https://github.com/settings/billing>. Confirm by looking for *any* successful Actions run on *any* private repo of that account — if there are none, it's account-level, not your workflow |
| Run succeeds but the reviewer posted nothing, log says "Workflow validation failed … identical content to the version on the repository's default branch" | The wrapper isn't on the default branch, or this PR modifies the wrapper | Merge the wrapper to the default branch too. A PR that changes the wrapper is never reviewed by it — that's the App's anti-exfiltration control |
| "workflow was not found" in the Actions log | `v1` tag doesn't exist yet, or (if private) access isn't configured | Redo step 5; if private, redo step 6 |
| Review job doesn't run at all | The PR is a draft, its author is a bot, it has the `skip-ai-review` label, or it's from a fork | Expected behavior — see "When nothing happens" below |
| Comment says "AI review skipped — pull request from a fork" | Expected — forks never get secrets, by GitHub design, so it can't authenticate. Review it manually. |
| Comment says "AI review unavailable" / step fails immediately | `CLAUDE_CODE_OAUTH_TOKEN` missing on that repo, or the token expired (they last a year) | Redo step 2 (mint a new one) and step 3 (re-set the secret on that repo) |
| Runs, finishes, but posts nothing at all | Check the Actions run's **Summary** tab first — it usually explains why (e.g. every changed file was excluded, or the App isn't installed) | Reread the job summary; if genuinely blank, that can also just mean the PR had nothing to flag |
| Reviewer runs but can't post comments | `permissions:` block missing from that repo's wrapper file | Compare against [`templates/wrapper.yml`](../templates/wrapper.yml) and fix |
| `gh secret set` hangs waiting for input | It's waiting for you to paste the token, not run silently | Paste the token, press Enter |
| Wrong GitHub account active in `gh` | You're logged into more than one account | `gh auth switch --hostname github.com --user jdfyras` |

### When nothing happens, by design

The reviewer deliberately does nothing (and spends no cost) when: the PR is a
draft, the author is a bot (Dependabot/Renovate/etc.), the `skip-ai-review`
label is present, every changed file is excluded by config, or the PR is from
a fork. All but the fork case are silent. The fork case always posts an
explanation, or at minimum writes one to the Actions job summary.
