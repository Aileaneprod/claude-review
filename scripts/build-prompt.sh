#!/usr/bin/env bash
#
# build-prompt.sh — assemble the final review prompt from base.md, the selected
# stack profile(s), and the resolved config.
#
# Usage:
#   build-prompt.sh --config FILE --repo OWNER/REPO --pr N \
#                   --changed-files FILE [--profiles "a,b"] [--triage] \
#                   [--prior-findings FILE] --out FILE
#
#   --config FILE          JSON from resolve-config.sh.
#   --repo OWNER/REPO      Repository under review.
#   --pr N                 Pull request number.
#   --changed-files FILE   Newline-separated list of files in scope.
#   --profiles "a,b"       Profile names. Default: read from the config's
#                          `profile` key, or auto-detect when that is `auto`.
#   --triage               Mark the review as partial (oversized diff).
#   --prior-findings FILE  Markdown list of findings already posted on this PR.
#   --repo-root DIR        Root of the repo under review, used to pick up its
#                          own .claude-review/learnings.md. Default: current dir.
#   --out FILE             Where to write the assembled prompt.
#
# Memory: the reviewer's learnings come from two files, both optional —
# prompts/learnings.md here (lessons that generalise across repos) and
# .claude-review/learnings.md in the repo under review (its own conventions).
# Both are curated by humans; see docs/TUNING.md.
#
# The PR title and body are deliberately NOT interpolated here. They are
# attacker-controlled on any pull request; the reviewer fetches them itself with
# `gh pr view`, so they arrive as tool output (data) rather than as part of the
# instruction text. See prompts/base.md rule 7.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
prompts_dir="${script_dir}/../prompts"

config_file=""
repo=""
pr_number=""
changed_files=""
profiles=""
prior_findings=""
repo_root="."
out_file=""
triage=0

die() {
  printf 'build-prompt: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)         [ "$#" -ge 2 ] || die "--config requires a value";         config_file="$2";    shift 2 ;;
    --repo)           [ "$#" -ge 2 ] || die "--repo requires a value";           repo="$2";           shift 2 ;;
    --pr)             [ "$#" -ge 2 ] || die "--pr requires a value";             pr_number="$2";      shift 2 ;;
    --changed-files)  [ "$#" -ge 2 ] || die "--changed-files requires a value";  changed_files="$2";  shift 2 ;;
    --profiles)       [ "$#" -ge 2 ] || die "--profiles requires a value";       profiles="$2";       shift 2 ;;
    --prior-findings) [ "$#" -ge 2 ] || die "--prior-findings requires a value"; prior_findings="$2"; shift 2 ;;
    --repo-root)      [ "$#" -ge 2 ] || die "--repo-root requires a value";      repo_root="$2";      shift 2 ;;
    --out)            [ "$#" -ge 2 ] || die "--out requires a value";            out_file="$2";       shift 2 ;;
    --triage)         triage=1; shift ;;
    -h|--help)        sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[ -n "$config_file" ]    || die "--config is required"
[ -n "$repo" ]           || die "--repo is required"
[ -n "$pr_number" ]      || die "--pr is required"
[ -n "$changed_files" ]  || die "--changed-files is required"
[ -n "$out_file" ]       || die "--out is required"
[ -f "$config_file" ]    || die "config file not found: $config_file"
[ -f "$changed_files" ]  || die "changed-files list not found: $changed_files"
[ -f "${prompts_dir}/base.md" ] || die "base prompt not found: ${prompts_dir}/base.md"

# Resolve profiles when the caller did not name them explicitly.
if [ -z "$profiles" ]; then
  configured="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("profile","auto"))' "$config_file")"
  if [ "$configured" = "auto" ] || [ -z "$configured" ]; then
    profiles="$("${script_dir}/detect-profile.sh" "." | paste -sd, -)"
  else
    profiles="$configured"
  fi
fi

python3 - \
  "${prompts_dir}/base.md" \
  "${prompts_dir}/profiles" \
  "$profiles" \
  "$config_file" \
  "$repo" \
  "$pr_number" \
  "$changed_files" \
  "$triage" \
  "$prior_findings" \
  "$out_file" \
  "${prompts_dir}/learnings.md" \
  "${repo_root}/.claude-review/learnings.md" <<'PY'
import json
import os
import sys

(base_path, profiles_dir, profile_csv, config_path, repo, pr_number,
 changed_path, triage_flag, prior_path, out_path,
 global_learnings_path, repo_learnings_path) = sys.argv[1:13]

with open(base_path, encoding="utf-8") as handle:
    template = handle.read()

with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)

# --- profile block -----------------------------------------------------------
names = [n.strip() for n in profile_csv.replace("\n", ",").split(",") if n.strip()]
if not names:
    names = ["generic"]

blocks = []
for name in names:
    candidate = os.path.join(profiles_dir, name + ".md")
    if not os.path.isfile(candidate):
        sys.stderr.write("build-prompt: unknown profile %r, ignoring\n" % name)
        continue
    with open(candidate, encoding="utf-8") as handle:
        blocks.append(handle.read().strip())

if not blocks:
    fallback = os.path.join(profiles_dir, "generic.md")
    with open(fallback, encoding="utf-8") as handle:
        blocks.append(handle.read().strip())

profile_block = "\n\n---\n\n".join(blocks)

# --- files in scope ----------------------------------------------------------
with open(changed_path, encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
changed_block = "\n".join("- `%s`" % f for f in files) if files else "_(none)_"

# --- triage note -------------------------------------------------------------
if triage_flag == "1":
    triage_note = (
        "> **This review is partial.** The diff exceeded %s changed lines, so "
        "review was narrowed to the highest-risk files (auth, payments, "
        "migrations, database access, configuration, dependency manifests, and "
        "anything matching secret/token/password/key). You MUST say so in the "
        "Reviewed / Skipped line of the summary, and say why."
        % config.get("max_diff_lines", "the configured limit")
    )
else:
    triage_note = ""

# --- excluded paths ----------------------------------------------------------
excluded = config.get("exclude_paths") or []
excluded_text = ", ".join("`%s`" % p for p in excluded) if excluded else "nothing"

# --- prior findings ----------------------------------------------------------
prior_text = ""
if prior_path and os.path.isfile(prior_path):
    with open(prior_path, encoding="utf-8") as handle:
        prior_text = handle.read().strip()
if not prior_text:
    prior_text = "_(none — this is the first review of this pull request.)_"

# --- learnings (the reviewer's memory) ---------------------------------------
# Two optional sources: lessons that generalise across repositories, and lessons
# belonging to the repository under review. Both are human-curated; an absent or
# empty file simply contributes nothing.
def read_learnings(path, label):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as handle:
        text = handle.read().strip()
    if not text:
        return ""
    # Everything before the first lesson heading is guidance for maintainers,
    # not for the reviewer, so drop it rather than spend prompt on it.
    marker = text.find("\n## ")
    if marker != -1:
        text = text[marker + 1:]
    return "### %s\n\n%s" % (label, text.strip())


learning_blocks = [
    read_learnings(global_learnings_path, "Lessons that apply everywhere"),
    read_learnings(repo_learnings_path, "Lessons specific to this repository"),
]
learning_blocks = [b for b in learning_blocks if b]
learnings_block = "\n\n".join(learning_blocks) if learning_blocks else (
    "_(No learnings recorded yet. Apply the grounding rules above as written.)_"
)

# --- output language ---------------------------------------------------------
# Only governs what the reviewer WRITES. It reads code and comments in any
# language regardless. Empty means: match the repository.
language = (config.get("language") or "").strip()
if language:
    _lang_body = (
        "Write every finding and the summary in **%s**, whatever language the "
        "code and its comments are in. Keep identifiers, file paths and quoted "
        "code exactly as they appear — translate your prose, never the evidence."
        % language
    )
else:
    _lang_body = (
        "Write in the language this repository uses. Judge it from the code "
        "comments, the README and the pull request description, not from this "
        "prompt — these instructions are in English, the project may not be. "
        "If the team writes in French, review in French. Keep identifiers, file "
        "paths and quoted code exactly as they appear."
    )
language_note = "# Language\n\n" + _lang_body

replacements = {
    "{{LANGUAGE_NOTE}}": language_note,
    "{{LEARNINGS}}": learnings_block,
    "{{REPO}}": repo,
    "{{PR_NUMBER}}": str(pr_number),
    "{{MAX_FINDINGS}}": str(config.get("max_findings", 12)),
    "{{PROFILE_BLOCK}}": profile_block,
    "{{TRIAGE_NOTE}}": triage_note,
    "{{EXCLUDED_PATHS}}": excluded_text,
    "{{PRIOR_FINDINGS}}": prior_text,
    "{{CHANGED_FILES}}": changed_block,
}

# Every token this script substitutes must be PRESENT in the template, and that
# is checked BEFORE any replacement. The check further down, on what is left
# over afterwards, only catches a token that SURVIVED — it cannot see one that
# was DELETED from base.md, because a deleted token is not left over either.
#
# Measured by Theo on this branch, before this check existed — his figures, not
# re-measured here, because build-prompt.sh cannot run on the machine this was
# written on: it hands its own POSIX path to python, and the python here is a
# native Windows build. Removing {{LEARNINGS}} lost 10,790 bytes of prompt and
# still exited 0, announcing "learnings: 2 source(s)" on the way out; removing
# {{CHANGED_FILES}} left the "Review only these files" section empty and still
# announced "files in scope". The reviewer then runs without its memory, or
# without a scope, and nothing says so. The case in
# scripts/test/cases/build-prompt.sh is what re-proves this in CI.
#
# So the assembly contract is explicit: base.md carries all of these, and a
# section removed there is removed from `replacements` in the same commit.
missing = [t for t in replacements if t not in template]
if missing:
    sys.stderr.write(
        "build-prompt: template is missing tokens: %s\n"
        % ", ".join(sorted(missing)))
    sys.exit(1)

for token, value in replacements.items():
    template = template.replace(token, value)

leftover = [t for t in replacements if t in template]
if leftover:
    sys.stderr.write("build-prompt: unsubstituted tokens: %s\n" % ", ".join(leftover))
    sys.exit(1)

with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(template)

sys.stderr.write(
    "build-prompt: wrote %s (%d bytes, profiles: %s, %d files in scope, "
    "learnings: %d source(s))\n"
    % (out_path, len(template.encode("utf-8")), ",".join(names), len(files),
       len(learning_blocks))
)
PY
