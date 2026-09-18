# The reviewer's execution trace has to survive the run that made it.
#
# `steps.claude.outputs.execution_file` is the only record of what the reviewer
# did rather than what it was given: the result record, the turn count, the
# denied tools, and every tool call. Four steps in review.yml read it and none
# of them kept it, so it died with the runner. The run log does not stand in —
# it expires after 38 days and carries no `tool_use` records at all, so a file
# being in the prompt is provable and the reviewer having read it is not. An
# audit of 23 missed findings had to leave 11 undecidable on that alone.
#
# What this case guards is not "a step exists". It is the three ways the step
# is easy to get wrong, each of which leaves it looking entirely correct:
#
#   * `if: always()` — runs on a CANCELLED run too, so a push superseded by
#     cancel-in-progress races the run that replaced it. review.yml refuses
#     `always()` everywhere else for this reason; see "Classify the review
#     outcome", which solves the same ordering problem.
#   * gating on the reviewer having succeeded — that skips the archive in the
#     one case the trace is worth having.
#   * a short retention — a copy that expires no later than the log it exists
#     to outlive is a copy of nothing.
#
# Read out of the workflow with stock python3, the way repo-hygiene.sh does.

it "keeps the reviewer's execution trace after the run"

_archive_step() {
  python3 - "$SCRIPTS/../.github/workflows/review.yml" <<'PY'
import io
import re
import sys

text = io.open(sys.argv[1], encoding="utf-8").read()

# Every step in the file, split on the 6-space list marker that begins one.
# The step we want is the one that hands the execution file to an upload as a
# `path:`, not one of the several that read it through `env:`.
found = []
for block in re.split(r"(?m)^      - ", text)[1:]:
    for line in block.splitlines():
        stripped = line.strip()
        if (stripped.startswith("path:")
                and "steps.claude.outputs.execution_file" in stripped):
            found.append(block)
            break

if len(found) != 1:
    print("steps-uploading-the-execution-file=%d" % len(found))
    raise SystemExit(0)

block = found[0]


def field(key, default="(absent)"):
    match = re.search(r"(?m)^\s*%s:\s*(.*?)\s*$" % re.escape(key), block)
    return match.group(1) if match else default


print("steps-uploading-the-execution-file=1")
print("uses=%s" % field("uses"))
print("if=%s" % field("if"))
print("continue-on-error=%s" % field("continue-on-error"))
print("retention-days=%s" % field("retention-days"))
print("if-no-files-found=%s" % field("if-no-files-found"))
PY
}

assert_contains "steps-uploading-the-execution-file=1" \
  "exactly one step archives the execution file" -- _archive_step
assert_contains "uses=actions/upload-artifact" \
  "it archives it with upload-artifact" -- _archive_step

# --- it must not be able to fail the job -------------------------------------

it "cannot turn a bad archive into a bad review"

assert_contains "continue-on-error=true" \
  "the archive step is continue-on-error" -- _archive_step
assert_contains "if-no-files-found=ignore" \
  "a reviewer that wrote no trace is a skip, not a warning" -- _archive_step

# --- it must run when the review failed --------------------------------------
#
# The reviewer step is continue-on-error, which keeps the implicit success()
# true for later steps — so naming nothing but the scope guard already covers a
# failed review, and `always()` would additionally cover a cancelled one, which
# must not be covered.

it "archives the trace of a review that failed, and not of one that was cancelled"

_condition() { _archive_step | sed -n 's/^if=//p'; }

# Stated positively first, so a missing step fails here rather than passing the
# three negatives below by having no condition to find anything in.
assert_contains "if=steps.scope.outputs.has_files == 'true'" \
  "the archive runs under the scope guard and nothing stricter" -- _archive_step
assert_equal "" "$(_condition | grep -o 'always()')" \
  "the archive condition does not reach for always()"
assert_equal "" "$(_condition | grep -o 'steps.claude.outcome')" \
  "nor gates the archive on the reviewer's exit status"
assert_equal "" "$(_condition | grep -o 'steps.verdict')" \
  "nor on the verdict, which is computed after it"

# --- it must outlive the run log ---------------------------------------------

it "keeps the trace longer than the log it replaces"

_retention_ok() {
  python3 - "$(_archive_step | sed -n 's/^retention-days=//p')" <<'PY'
import sys

raw = sys.argv[1]
if not raw.isdigit():
    print("retention-days is %r, not a number of days" % raw)
    raise SystemExit(1)
days = int(raw)
# 38 is when the run log goes. 90 is the most a repository allows without a
# settings change, so it is also the most that is valid on every caller.
if not 38 < days <= 90:
    print("retention-days is %d; it must outlive the 38-day log and fit the 90-day ceiling" % days)
    raise SystemExit(1)
print("retention-days %d outlives the run log" % days)
PY
}

assert_status 0 "the retention outlives the 38-day run log and fits the 90-day ceiling" \
  -- _retention_ok
