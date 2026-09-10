# build-prompt.sh — the assembly contract.
#
# The script substitutes ten tokens into prompts/base.md. Its only check ran
# AFTER substitution and listed the tokens still present, which cannot see a
# token DELETED from the template: a deleted token is not left over either.
#
# Measured by Theo on the pull request that added these cases: removing
# `{{LEARNINGS}}` lost 10,790 bytes of prompt and still exited 0, announcing
# "learnings: 2 source(s)" on the way out. Removing `{{CHANGED_FILES}}` left the
# "Review only these files" section empty and still announced "files in scope".
# The reviewer runs without its memory, or without a scope, and nothing says so.
#
# There was no case for this script at all, which is why the criterion that
# claimed it borrowed its proof from a guard that tests the other direction.
#
# The template is mutilated with sed rather than python, so the mutation itself
# never depends on which python is installed.

_bp_tree() {
  local variant="$1" token="${2:-}"
  local tree="$TESTTMP/bp-$variant"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -R "$SCRIPTS" "$tree/scripts"
  cp -R "$SCRIPTS/../prompts" "$tree/prompts"
  if [ -n "$token" ]; then
    sed "s|$token||g" "$tree/prompts/base.md" > "$tree/base.new" \
      && mv "$tree/base.new" "$tree/prompts/base.md"
  fi
  printf 'a.ts\nb.ts\n' > "$tree/changed.txt"
  printf '%s\n' '{"profile": "generic", "max_findings": 12, "language": "auto", "excluded_paths": []}' \
    > "$tree/config.json"
  printf '%s' "$tree"
}

_bp_run() {
  local tree
  tree="$(_bp_tree "$1" "${2:-}")"
  "$tree/scripts/build-prompt.sh" \
    --config "$tree/config.json" --repo test/repo --pr 1 \
    --changed-files "$tree/changed.txt" --profiles generic \
    --out "$tree/prompt.md"
}

# The control. Without it, the refusals below could be red for any other
# reason — a missing profile, an unreadable config — and still look like proof.
it "assembles the prompt when the template is intact"
assert_status 0 "the untouched template still builds" -- _bp_run intact

it "refuses a template that LOST a token instead of writing a short prompt"
assert_status 1 "{{LEARNINGS}} deleted from base.md is a failure, not a silent 10 KB loss" \
  -- _bp_run no-learnings '{{LEARNINGS}}'
assert_contains "missing tokens: {{LEARNINGS}}" "and it names the token that went" \
  -- _bp_run no-learnings '{{LEARNINGS}}'

it "refuses a lost scope token too"
assert_status 1 "{{CHANGED_FILES}} deleted leaves the review with no scope" \
  -- _bp_run no-changed '{{CHANGED_FILES}}'
