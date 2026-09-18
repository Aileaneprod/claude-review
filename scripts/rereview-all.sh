#!/usr/bin/env bash
#
# rereview-all.sh — run the outage catch-up across a list of repositories.
#
# Usage:
#   rereview-all.sh [--repos FILE] [--rerun] [--budget N] [--limit N]
#                   [--check NAME]
#
#   --repos FILE  The repository list. Default: config/rereview-repos.txt.
#   --rerun       Replay the runs. Without it this only reports. Needs --budget.
#   --budget N    Replay at most N runs across the WHOLE pass.
#   --limit N     Replay at most N per repository. Default: whatever is left of
#                 the budget.
#   --check NAME  Outcome check to read. Passed through unchanged.
#
# Writes a Markdown report on stdout, to be appended to $GITHUB_STEP_SUMMARY.
#
# THE LIST IS DATA. One repository per line; `#` comments and blank lines are
# ignored:
#
#     OWNER/REPO [path to that repository's wrapper workflow]
#
# The second field is optional and defaults to .github/workflows/ai-review.yml,
# the path install-wrapper.sh writes. It is not hypothetical: this repository's
# own wrapper is .github/workflows/self-review.yml.
#
# A plain list, rather than a key in config/defaults.yml — the other way this
# repository stores configuration. Three reasons, and the third decided it:
#
#   * defaults.yml is documented as the source of truth for every key IN IT,
#     and every one of those tunes a single review. A fleet roster is not a
#     review setting.
#   * resolve-config.sh validates against a fixed SCHEMA, drops unknown keys
#     with a warning, and emits JSON. The roster would need a schema entry and
#     a JSON hop only to come back out as the lines of text it started as.
#   * defaults.yml is deliberately overridable by the .claude-review.yml of the
#     repository BEING REVIEWED, which wins over it. A roster living there
#     could be extended by any repository this system reviews: one line in its
#     own config, and the catch-up points at a repository it chose, holding the
#     token below. The roster has to live where reviewed repositories cannot
#     reach it.
#
# WHY A WRAPPER AND NOT A `for` LOOP IN YAML. Three things a pass over N
# repositories needs that one `--repo` invocation does not:
#
#   * A budget for the PASS. `--limit` bounds one repository; eight of them
#     each allowed five is forty reviews, and quota is the scarce resource in
#     this whole design (docs/ARCHITECTURE.md). What is left of the budget
#     becomes the next repository's `--limit`, and when it runs out the pass
#     stops and NAMES the repositories it never reached — an unannounced skip
#     reads exactly like a clean bill of health, which is the failure mode this
#     tool exists to avoid.
#   * Surviving one repository. rereview-open-prs.sh exits non-zero when a
#     repository has no wrapper at the expected path. That is right for a
#     command a person typed and wrong for entry three of eight at 06:17.
#   * The blind spot in the SUMMARY. A repository whose wrapper lacks
#     `checks: write` publishes no outcome check, so every pull request on it
#     looks reviewed. rereview-open-prs.sh says so on stderr; unattended, the
#     log is exactly what nobody reads, so it is hoisted above the report.
#
# Exit status: 1 if any listed repository did not come back clean — out of
# reach entirely (archived, renamed, the token's access gone), or checked with
# something in it left uninspected, which rereview-open-prs.sh also reports by
# exiting 1. The premise of this tool is that nobody is watching the run, so
# either has to reach a person somehow, and a failed scheduled run is the only
# channel that does. Which one it was is in that repository's own block.
#
# Requires: gh (authenticated), python3, rereview-open-prs.sh beside it.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

repos_file="${script_dir}/../config/rereview-repos.txt"
rerun=0
budget=0
limit=0
check_name=""

die() { printf 'rereview-all: %s\n' "$1" >&2; exit 1; }

# "1 repositories" in an unattended summary is how a reader learns to stop
# reading it.
plural() { if [ "$1" -eq 1 ]; then printf '%s' "$2"; else printf '%s' "$3"; fi; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repos)  [ "$#" -ge 2 ] || die "--repos requires a value";  repos_file="$2"; shift 2 ;;
    --budget) [ "$#" -ge 2 ] || die "--budget requires a value"; budget="$2";     shift 2 ;;
    --limit)  [ "$#" -ge 2 ] || die "--limit requires a value";  limit="$2";      shift 2 ;;
    --check)  [ "$#" -ge 2 ] || die "--check requires a value";  check_name="$2"; shift 2 ;;
    --rerun)  rerun=1; shift ;;
    -h|--help) sed -n '2,68p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        die "unknown argument: $1" ;;
  esac
done

case "$budget" in *[!0-9]*) die "--budget must be a whole number (got '${budget}')" ;; esac
case "$limit"  in *[!0-9]*) die "--limit must be a whole number (got '${limit}')" ;; esac

# An unbounded fleet replay is the one mistake here with no undo: by the time
# the summary says forty, the quota is gone. --limit does not prevent it,
# because it bounds a repository and not the pass, so the pass has to state its
# own ceiling out loud.
if [ "$rerun" -eq 1 ] && [ "$budget" -eq 0 ]; then
  die "--rerun needs --budget N — every replay costs a full review, and a pass over a list has to say how much it may spend"
fi

[ -f "$repos_file" ] || die "repository list not found: ${repos_file}"

# --- the list ----------------------------------------------------------------
#
# Parsed in full before anything runs. A malformed line is a hard error, not a
# line quietly dropped from a roster whose whole job is to be complete — the
# same trade resolve-config.sh makes with its YAML subset.
#
# The validation is not pedantry: both fields become arguments to a child
# script. A line reading `--rerun` would otherwise arrive as a flag, and this
# is the kind of file that gets edited in a hurry during an outage.

entries=""
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  line="${raw%%#*}"
  read -r repo workflow extra <<EOF
$line
EOF
  [ -n "${repo:-}" ] || continue

  case "$repo" in
    */*/*|-*|*[!A-Za-z0-9._/-]*) die "${repos_file}:${lineno}: not a repository name: '${repo}'" ;;
    */*) ;;
    *)   die "${repos_file}:${lineno}: expected OWNER/REPO, got '${repo}'" ;;
  esac
  [ -z "${extra:-}" ] || die "${repos_file}:${lineno}: the format is 'OWNER/REPO [wrapper path]' — a third field, '${extra}', is not one"

  if [ -n "${workflow:-}" ]; then
    case "$workflow" in
      -*|*[!A-Za-z0-9._/-]*) die "${repos_file}:${lineno}: not a workflow path: '${workflow}'" ;;
    esac
  else
    workflow=".github/workflows/ai-review.yml"
  fi

  entries="${entries}${repo} ${workflow}
"
done < "$repos_file"

count="$(printf '%s' "$entries" | grep -c . || true)"
if [ "$count" -eq 0 ]; then
  printf '### Review catch-up\n\n'
  printf 'No repositories are configured in `%s`, so there was nothing to check.\n' \
    "$(basename "$repos_file")"
  exit 0
fi

# --- the pass ----------------------------------------------------------------

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

body="${work_dir}/body.md"
blind="${work_dir}/blind.md"
: > "$body"
: > "$blind"

spent=0
remaining="$budget"
failed=0
skipped=0

while read -r repo workflow; do
  [ -n "$repo" ] || continue

  # Out of budget. Say which repositories never got looked at, by name, in the
  # summary. They are the ones a person has to decide about.
  if [ "$rerun" -eq 1 ] && [ "$remaining" -le 0 ]; then
    skipped=$((skipped + 1))
    printf '#### %s\n\nNot reached — the pass had already spent its budget of %s replay(s).\n\n' \
      "$repo" "$budget" >> "$body"
    continue
  fi

  args=(--repo "$repo" --workflow "$workflow")
  [ -z "$check_name" ] || args+=(--check "$check_name")
  if [ "$rerun" -eq 1 ]; then
    # What is LEFT of the budget, never the configured per-repository limit on
    # its own. `--limit 0` means "all of them" to rereview-open-prs.sh, so an
    # exhausted budget arriving here as a limit would replay everything — which
    # is why the guard above is `-le 0` and this line is only ever reached with
    # something positive to spend.
    effective="$remaining"
    if [ "$limit" -gt 0 ] && [ "$limit" -lt "$effective" ]; then
      effective="$limit"
    fi
    args+=(--rerun --limit "$effective")
  fi

  out="${work_dir}/out.txt"
  # stdin from /dev/null: this loop reads the roster on ITS stdin, and a child
  # that read a byte of it — `gh` prompting for something, most plausibly —
  # would swallow the repositories below it. The classic way a loop over a list
  # silently processes half of one.
  if "${script_dir}/rereview-open-prs.sh" "${args[@]}" > "$out" 2>&1 < /dev/null; then
    status=0
  else
    status=$?
    failed=$((failed + 1))
  fi

  # Keyed on two words of the child's warning rather than the sentence around
  # them, because the sentence is prose and prose gets rewritten. If this ever
  # stops matching, the report loses the one warning it must never lose.
  if grep -qE 'WARNING.*checks: write' "$out"; then
    printf -- '- `%s` — its wrapper (`%s`) does not grant `checks: write`, so an unreviewed push there publishes no outcome check and leaves nothing for this pass to find.\n' \
      "$repo" "$workflow" >> "$blind"
  fi

  if [ "$rerun" -eq 1 ]; then
    # The one line of the child's output this depends on. It is the only place
    # the count of ACTUAL replays exists — a target that refuses `gh run rerun`
    # is listed and not replayed, and charging the budget for it would spend
    # the pass on failures.
    got="$(sed -n 's/^rereview-open-prs: replayed \([0-9][0-9]*\) of .*/\1/p' "$out" | tail -1)"
    case "${got:-}" in ''|*[!0-9]*) got=0 ;; esac
    spent=$((spent + got))
    remaining=$((budget - spent))
  fi

  {
    printf '#### %s\n\n' "$repo"
    [ "$status" -eq 0 ] || printf 'Did not come back clean (exit %s) — the output below says whether it was out of reach or checked with something left uninspected.\n\n' "$status"
    printf '```\n'
    cat "$out"
    printf '```\n\n'
  } >> "$body"
done <<EOF
$entries
EOF

# --- the report --------------------------------------------------------------
#
# Header first, and the blind spot above everything else: this runs unattended,
# so whatever sits below the fold is not read.

printf '### Review catch-up\n\n'
if [ "$rerun" -eq 1 ]; then
  printf 'Replayed **%s** review(s) of a **%s** budget, across %s %s.\n\n' \
    "$spent" "$budget" "$count" "$(plural "$count" repository repositories)"
else
  printf 'Report only — nothing was replayed. Read %s %s.\n\n' \
    "$count" "$(plural "$count" repository repositories)"
fi

if [ -s "$blind" ]; then
  printf '**Blind spot — this pass cannot see everything.**\n\n'
  cat "$blind"
  printf '\nWhatever those repositories report below is a floor, not a count. Add `checks: write` to the `permissions:` block of their wrapper; docs/SETUP.md step 7 has the block.\n\n'
fi

if [ "$failed" -gt 0 ]; then
  # Two different things exit non-zero, and the header must not pick one and
  # call it the other. rereview-open-prs.sh stops outright when a repository is
  # out of reach — archived, renamed, the token without access — AND it exits 1
  # after a pass it completed in which some pull request could not be fully
  # inspected. The first needs the roster edited; the second is often a read
  # that will work tomorrow. Which one it was is in that repository's own
  # output, printed below, so this line says only what is true of both.
  printf '**%s %s in the list did not come back clean** — either out of reach entirely (archived, renamed, or the token lost access) or checked with something in it left uninspected. The block for each one below says which. This run is marked failed so that it reaches somebody.\n\n' \
    "$failed" "$(plural "$failed" repository repositories)"
fi

if [ "$skipped" -gt 0 ]; then
  printf '**%s %s was not reached**, because the budget of %s ran out first. The next pass starts from the top of the same list, so raise the budget or reorder `%s` if the same name keeps missing out.\n\n' \
    "$skipped" "$(plural "$skipped" repository repositories)" "$budget" "$(basename "$repos_file")"
fi

cat "$body"

[ "$failed" -eq 0 ] || exit 1
