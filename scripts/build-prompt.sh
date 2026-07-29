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
#   --out FILE             Where to write the assembled prompt.
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
    --out)            [ "$#" -ge 2 ] || die "--out requires a value";            out_file="$2";       shift 2 ;;
    --triage)         triage=1; shift ;;
    -h|--help)        sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  "$out_file" <<'PY'
import json
import os
import sys

(base_path, profiles_dir, profile_csv, config_path, repo, pr_number,
 changed_path, triage_flag, prior_path, out_path) = sys.argv[1:11]

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

replacements = {
    "{{REPO}}": repo,
    "{{PR_NUMBER}}": str(pr_number),
    "{{MAX_FINDINGS}}": str(config.get("max_findings", 12)),
    "{{PROFILE_BLOCK}}": profile_block,
    "{{TRIAGE_NOTE}}": triage_note,
    "{{EXCLUDED_PATHS}}": excluded_text,
    "{{PRIOR_FINDINGS}}": prior_text,
    "{{CHANGED_FILES}}": changed_block,
}

for token, value in replacements.items():
    template = template.replace(token, value)

leftover = [t for t in replacements if t in template]
if leftover:
    sys.stderr.write("build-prompt: unsubstituted tokens: %s\n" % ", ".join(leftover))
    sys.exit(1)

with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(template)

sys.stderr.write(
    "build-prompt: wrote %s (%d bytes, profiles: %s, %d files in scope)\n"
    % (out_path, len(template.encode("utf-8")), ",".join(names), len(files))
)
PY
