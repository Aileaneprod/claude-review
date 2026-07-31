#!/usr/bin/env bash
#
# install-wrapper.sh — add the AI review wrapper workflow to a target repo.
#
# Usage:
#   install-wrapper.sh OWNER/REPO [--confirm] [--path PATH] [--branch NAME]
#                                 [--base BRANCH] [--template FILE]
#
#   --confirm        Actually write. WITHOUT THIS THE SCRIPT ONLY PRINTS A DIFF.
#   --path PATH      Where to install. Default .github/workflows/ai-review.yml
#   --branch NAME    Branch to create. Default chore/add-ai-review
#   --base BRANCH    Base branch. Default: the repo's default branch.
#   --template FILE  Wrapper source. Default ../templates/wrapper.yml
#
# Idempotent: if the target already has an identical wrapper, this exits 0
# without touching anything. If it has a *different* wrapper, the dry run shows
# the diff and --confirm updates it.
#
# Requires: gh (authenticated with repo scope), python3.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

target=""
confirm=0
dest_path=".github/workflows/ai-review.yml"
branch="chore/add-ai-review"
base_branch=""
template="${script_dir}/../templates/wrapper.yml"

die() {
  printf 'install-wrapper: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm)  confirm=1; shift ;;
    --path)     [ "$#" -ge 2 ] || die "--path requires a value";     dest_path="$2";   shift 2 ;;
    --branch)   [ "$#" -ge 2 ] || die "--branch requires a value";   branch="$2";      shift 2 ;;
    --base)     [ "$#" -ge 2 ] || die "--base requires a value";     base_branch="$2"; shift 2 ;;
    --template) [ "$#" -ge 2 ] || die "--template requires a value"; template="$2";    shift 2 ;;
    -h|--help)  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)
      [ -z "$target" ] || die "unexpected extra argument: $1"
      target="$1"
      shift
      ;;
  esac
done

[ -n "$target" ] || die "a target repository is required (OWNER/REPO)"
case "$target" in
  */*/*|/*|*/) die "target must be exactly OWNER/REPO, got: $target" ;;
  */*) : ;;
  *)   die "target must be OWNER/REPO, got: $target" ;;
esac

[ -f "$template" ] || die "template not found: $template"
command -v gh >/dev/null 2>&1      || die "gh is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

# The template ships with a placeholder on purpose. Installing it unreplaced
# would produce a workflow that fails at dispatch time with a confusing error,
# so refuse early and say exactly what to do.
if grep -q '\[GITHUB_OWNER\]' "$template"; then
  die "template still contains [GITHUB_OWNER].
  Replace it first, e.g.:
    grep -rl '\[GITHUB_OWNER\]' . | xargs sed -i 's/\[GITHUB_OWNER\]/jdfyras/g'
  See docs/SETUP.md."
fi

work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# --- resolve the base branch -------------------------------------------------
if ! gh api "repos/${target}" >"${work_dir}/repo.json" 2>"${work_dir}/repo.err"; then
  sed 's/^/install-wrapper:   /' "${work_dir}/repo.err" >&2 || true
  die "cannot read repos/${target} — check the name and your gh auth"
fi
default_branch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["default_branch"])' "${work_dir}/repo.json")"

if [ -z "$base_branch" ]; then
  base_branch="$default_branch"
fi

# The Claude GitHub App refuses to run a workflow whose content differs from the
# copy on the default branch — that is what prevents a pull request from
# rewriting the workflow to exfiltrate the token. Installing onto some other
# branch therefore produces a workflow that is present, valid, and permanently
# silent, which is a miserable thing to debug. Say so up front.
if [ "$base_branch" != "$default_branch" ]; then
  printf 'install-wrapper: WARNING: installing onto "%s", but the default branch is "%s".\n' \
    "$base_branch" "$default_branch" >&2
  printf 'install-wrapper:   The Claude GitHub App only runs a workflow that matches the\n' >&2
  printf 'install-wrapper:   copy on the default branch, so reviews will NOT run until this\n' >&2
  printf 'install-wrapper:   file also lands on "%s" with identical content.\n' "$default_branch" >&2
  printf 'install-wrapper:   Install onto "%s" as well:\n' "$default_branch" >&2
  printf 'install-wrapper:     %s %s --base %s --confirm\n' \
    "$(basename "${BASH_SOURCE[0]}")" "$target" "$default_branch" >&2
fi

# --- compare against what is already there -----------------------------------
remote_state="absent"
if gh api "repos/${target}/contents/${dest_path}?ref=${base_branch}" \
     >"${work_dir}/remote.json" 2>/dev/null; then
  python3 - "${work_dir}/remote.json" "${work_dir}/remote.yml" <<'PY'
import base64
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

content = base64.b64decode(payload.get("content", "")).decode("utf-8", "replace")
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as handle:
    handle.write(content)
PY
  if diff -q "${work_dir}/remote.yml" "$template" >/dev/null 2>&1; then
    remote_state="identical"
  else
    remote_state="different"
  fi
fi

if [ "$remote_state" = "identical" ]; then
  printf 'install-wrapper: %s already has an identical %s — nothing to do.\n' \
    "$target" "$dest_path"
  exit 0
fi

# --- dry run -----------------------------------------------------------------
if [ "$confirm" -eq 0 ]; then
  printf 'install-wrapper: DRY RUN — nothing will be written. Re-run with --confirm to apply.\n\n'
  printf '  repo    %s\n  base    %s\n  branch  %s\n  path    %s\n  state   %s\n\n' \
    "$target" "$base_branch" "$branch" "$dest_path" "$remote_state"
  if [ "$remote_state" = "different" ]; then
    printf '  --- diff (remote -> template) ---\n'
    diff -u "${work_dir}/remote.yml" "$template" | sed 's/^/  /' || true
  else
    printf '  --- file to be created ---\n'
    sed 's/^/  /' "$template"
  fi
  printf '\n  Would: create branch %s from %s, commit %s, open a pull request.\n' \
    "$branch" "$base_branch" "$dest_path"
  exit 0
fi

# --- apply -------------------------------------------------------------------
printf 'install-wrapper: applying to %s\n' "$target" >&2

if gh api "repos/${target}/git/ref/heads/${branch}" >/dev/null 2>&1; then
  printf 'install-wrapper: branch %s already exists, reusing it\n' "$branch" >&2
else
  gh api "repos/${target}/git/ref/heads/${base_branch}" >"${work_dir}/baseref.json"
  base_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["object"]["sha"])' "${work_dir}/baseref.json")"
  python3 - "${work_dir}/newref.json" "refs/heads/${branch}" "$base_sha" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"ref": sys.argv[2], "sha": sys.argv[3]}, handle)
PY
  gh api "repos/${target}/git/refs" --method POST --input "${work_dir}/newref.json" >/dev/null
  printf 'install-wrapper: created branch %s\n' "$branch" >&2
fi

# The contents API needs the blob sha when replacing an existing file.
existing_sha=""
if gh api "repos/${target}/contents/${dest_path}?ref=${branch}" \
     >"${work_dir}/onbranch.json" 2>/dev/null; then
  existing_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sha",""))' "${work_dir}/onbranch.json")"
fi

python3 - "$template" "${work_dir}/put.json" "$branch" "$existing_sha" <<'PY'
import base64
import json
import sys

with open(sys.argv[1], "rb") as handle:
    content = handle.read()

payload = {
    "message": "ci: add AI code review workflow",
    "content": base64.b64encode(content).decode("ascii"),
    "branch": sys.argv[3],
}
if sys.argv[4]:
    payload["sha"] = sys.argv[4]

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY

gh api "repos/${target}/contents/${dest_path}" \
  --method PUT --input "${work_dir}/put.json" >/dev/null
printf 'install-wrapper: committed %s\n' "$dest_path" >&2

# --- open the pull request ---------------------------------------------------
if gh api "repos/${target}/pulls?head=${target%%/*}:${branch}&state=open" \
     >"${work_dir}/pulls.json" 2>/dev/null; then
  open_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${work_dir}/pulls.json")"
else
  open_count=0
fi

if [ "$open_count" != "0" ]; then
  printf 'install-wrapper: a pull request for %s is already open — not opening another.\n' "$branch" >&2
  exit 0
fi

python3 - "${work_dir}/pr.json" "$branch" "$base_branch" <<'PY'
import json
import sys

body = (
    "Adds AI code review on pull requests, delegated to the central "
    "`claude-review` reusable workflow.\n\n"
    "This repo needs a `CLAUDE_CODE_OAUTH_TOKEN` secret (repo or org level) "
    "for the review to run. Without it the job fails closed and does not "
    "block merges.\n\n"
    "Add the `skip-ai-review` label to any PR you want the reviewer to ignore."
)

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "title": "ci: add AI code review workflow",
        "head": sys.argv[2],
        "base": sys.argv[3],
        "body": body,
    }, handle)
PY

gh api "repos/${target}/pulls" --method POST --input "${work_dir}/pr.json" \
  >"${work_dir}/created.json"
python3 -c 'import json,sys; print("install-wrapper: opened", json.load(open(sys.argv[1]))["html_url"])' \
  "${work_dir}/created.json"
