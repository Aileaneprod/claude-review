# Every script this repository invokes as a command must be committed
# executable. On Windows the filesystem carries no executable bit, so `chmod +x`
# succeeds locally, changes nothing git records, and the file lands as 100644.
# Nothing notices until Linux runs it.
#
# It had already happened four times when this case was written:
#
#   * scripts/test/run-tests.sh   — CI, exit 126, Permission denied
#   * scripts/explain-failure.sh  — invoked by review.yml on the failure path,
#     where the call is `|| true`. So it did not fail the job; it silently did
#     nothing, and the denied-tool diagnostic it exists to print never appeared.
#     Two self-reviews died of error_max_turns with 8 and 15 denials while the
#     tool that would have named them was unable to start.
#   * scripts/harvest-feedback.sh and scripts/propose-learnings.sh — documented
#     in TUNING.md as `./scripts/...` commands.
#
# The `|| true` is correct: a broken diagnostic must not mask the failure it is
# diagnosing. That is exactly why the mode needs its own check — the safety net
# also hides the breakage.

# Only files invoked AS COMMANDS. The case files under scripts/test/cases/ are
# sourced by the runner, so they need neither the bit nor a shebang, and a git
# pathspec glob matches across directories — which is how they got swept in
# here on the first run.
it "commits every script executable"

_modes() {
  git -C "$(cd -- "$SCRIPTS/.." && pwd)" ls-files -s -- \
      'scripts/*.sh' 'scripts/test/run-tests.sh' 'eval/*.sh' \
    | grep -v 'scripts/test/cases/'
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  mode="$(printf '%s' "$line" | awk '{print $1}')"
  file="$(printf '%s' "$line" | awk '{print $4}')"
  assert_equal "100755" "$mode" "$file is committed executable"
done <<EOF
$(_modes)
EOF

it "keeps every script's shebang"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  file="$(printf '%s' "$line" | awk '{print $4}')"
  full="$(cd -- "$SCRIPTS/.." && pwd)/$file"
  first="$(head -c 2 "$full" 2>/dev/null)"
  assert_equal "#!" "$first" "$file starts with a shebang"
done <<EOF
$(_modes)
EOF
