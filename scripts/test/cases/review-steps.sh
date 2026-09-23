# The steps of review.yml that decide WHICH review runs and WITH WHAT — run,
# not read.
#
# Several of them are inline shell inside the workflow, where no other case can
# reach them: the one that turns config.json into claude_args, the one that
# decides whether to retry on the fallback credential, the retry itself, the
# one that says which of the two attempts counts, and the notice that names the
# credential to replace. A mistake in any of them passes every script test in
# this directory and shows up only on a live pull request — as a model nobody
# asked for, a review that silently lost its effort level, the same findings
# posted twice, or a maintainer rotating the wrong secret.
#
# So each `run:` block is lifted out of the workflow and executed here, in a
# sandbox that stands in for the runner: RUNNER_TEMP, GITHUB_OUTPUT,
# GITHUB_STEP_SUMMARY, and the `.claude-review-tooling` checkout the steps call
# into. The sandbox is also the step's working directory, as the pull request's
# checkout is on the runner — which is what lets the cases below plant a file
# there. Read out of the workflow with stock python3, the way
# execution-artifact.sh does.

_WORKFLOW="$SCRIPTS/../.github/workflows/review.yml"

# _step ID PART — print one part of the step whose `id:` is ID.
#   run     the `run: |` script, dedented, ready to execute
#   with    the `with:` inputs, comments dropped, one `key: value` per line
#   env     the `env:` entries, the same way
#   FIELD   any other top-level field of the step (`if`, `uses`, …)
# A step that has no `id:` is named by its `name:` instead.
_step() {
  python3 - "$_WORKFLOW" "$1" "$2" <<'PY'
import io
import re
import sys

path, step_id, part = sys.argv[1:4]
text = io.open(path, encoding="utf-8").read()

blocks = [b for b in re.split(r"(?m)^      - ", text)[1:]
          if re.search(r"(?m)^\s+id: %s\s*$" % re.escape(step_id), b)
          or re.match(r"name: %s[ \t]*(?:\n|$)" % re.escape(step_id), b)]
if len(blocks) != 1:
    print("(%d steps named %s)" % (len(blocks), step_id))
    raise SystemExit(0)
lines = blocks[0].splitlines()


def nested(key):
    """The lines under `        KEY:` until the next field at that depth."""
    out, inside = [], False
    for line in lines:
        if re.match(r"^        %s:" % re.escape(key), line):
            inside = True
            continue
        if inside:
            if line.strip() and not line.startswith("          "):
                break
            out.append(line[10:])
    while out and not out[-1].strip():
        out.pop()
    return out


if part == "run":
    print("\n".join(nested("run")))
elif part in ("with", "env"):
    print("\n".join(l.strip() for l in nested(part)
                    if l.strip() and not l.strip().startswith("#")))
else:
    for line in lines:
        match = re.match(r"^        %s:\s*(.*?)\s*$" % re.escape(part), line)
        if match:
            print(match.group(1))
            raise SystemExit(0)
    print("(absent)")
PY
}

# _sandbox NAME — a fresh stand-in for the runner. Echoes its directory.
_sandbox() {
  local box="$TESTTMP/runner-$1"
  rm -rf "$box"
  mkdir -p "$box/temp" "$box/bin" "$box/.claude-review-tooling/scripts"
  cp "$SCRIPTS/should-fall-back.sh" "$SCRIPTS/explain-failure.sh" \
    "$box/.claude-review-tooling/scripts/"
  # Whatever reaches GitHub is recorded, never sent.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/posted"\n' "$box" > "$box/bin/gh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/posted"\n' "$box" \
    > "$box/.claude-review-tooling/scripts/publish-outcome-check.sh"
  chmod +x "$box/bin/gh" "$box/.claude-review-tooling/scripts/"*.sh
  : > "$box/output"; : > "$box/summary"; : > "$box/posted"
  printf '%s' "$box"
}

# _run_step ID BOX [VAR=value …] — execute the step's script in BOX, as its
# working directory. What it prints — annotations included — lands in BOX/log.
_run_step() {
  local id="$1" box="$2"; shift 2
  _step "$id" run > "$box/step.sh"
  (cd "$box" && env PATH="$box/bin:$PATH" RUNNER_TEMP="$box/temp" \
     GITHUB_OUTPUT="$box/output" GITHUB_STEP_SUMMARY="$box/summary" \
     GITHUB_REPOSITORY=owner/repo OUTCOME_CHECK_NAME="AI review outcome" "$@" \
     bash "$box/step.sh") >"$box/log" 2>&1
}

# _output BOX KEY — the value the step wrote for KEY, heredoc form included;
# `(unset)` when it wrote none, `(twice)` when it wrote more than one.
_output() {
  python3 - "$1/output" "$2" <<'PY'
import io
import sys

path, key = sys.argv[1:3]
lines = io.open(path, encoding="utf-8").read().splitlines()
values, i = [], 0
while i < len(lines):
    line = lines[i]
    if line.startswith(key + "<<"):
        delimiter = line[len(key) + 2:]
        body = []
        i += 1
        while i < len(lines) and lines[i] != delimiter:
            body.append(lines[i])
            i += 1
        values.append("\n".join(body))
    elif line.startswith(key + "="):
        values.append(line[len(key) + 1:])
    i += 1
print("(unset)" if not values else values[0] if len(values) == 1 else "(twice)")
PY
}

# _argv BOX — claude_args split the way a shell splits it, one argument a line.
# claude-code-action uses shell-quote; for arguments this plain, shlex agrees.
_argv() {
  _output "$1" value | python3 -c '
import shlex
import sys
print("\n".join(shlex.split(sys.stdin.read())))'
}

# _after BOX FLAG — the one argument that follows FLAG, `(no FLAG)` if absent.
# A multi-line needle would not do: grep -F reads each line as its own pattern,
# so "--effort<newline>xhigh" passes on `--effort` alone.
_after() {
  _argv "$1" | python3 -c '
import sys
argv = sys.stdin.read().splitlines()
flag = sys.argv[1]
print(argv[argv.index(flag) + 1] if flag in argv[:-1] else "(no %s)" % flag)' "$2"
}

# --- claude_args ---------------------------------------------------------------

it "carries the configured model and effort to the CLI"
box="$(_sandbox args)"
printf '{"model": "claude-opus-5-5", "effort": "xhigh", "max_turns": 60}' > "$box/temp/config.json"
_run_step args "$box"
assert_equal "xhigh" "$(_after "$box" --effort)" "effort becomes the argument after --effort"
assert_equal "claude-opus-5-5" "$(_after "$box" --model)" "model becomes the argument after --model"
assert_equal "60" "$(_after "$box" --max-turns)" "max_turns still becomes --max-turns"

it "passes no flag at all for a value left empty"
# An empty effort must mean the CLI's own default, not `--effort ""`, which the
# CLI would reject and fail the review over.
box="$(_sandbox args-empty)"
printf '{"model": "", "effort": "", "max_turns": 60}' > "$box/temp/config.json"
_run_step args "$box"
assert_equal "60" "$(_after "$box" --max-turns)" "the step ran and wrote its arguments"
assert_not_contains "--effort" "no --effort for an empty effort" -- _argv "$box"
assert_not_contains "--model" "no --model for an empty model" -- _argv "$box"

it "gets the shipped defaults all the way to the command line"
# The whole chain, as a pull request with no .claude-review.yml would run it:
# defaults.yml, through resolve-config.sh, into the step that builds the argv.
box="$(_sandbox args-defaults)"
mkdir -p "$box/repo"
"$SCRIPTS/resolve-config.sh" --repo-root "$box/repo" > "$box/temp/config.json"
_run_step args "$box"
assert_equal "claude-opus-5-5" "$(_after "$box" --model)" "the default model reaches the CLI"
assert_equal "xhigh" "$(_after "$box" --effort)" "the default effort reaches the CLI"

# --- python in the pull request's working directory ----------------------------
#
# Every step after the checkout runs in the pull request's head, and `python3 -c`
# puts that directory first on sys.path. A `json.py` the pull request adds is
# then the `json` these steps import — AFTER resolve-config.sh has checked the
# effort, so the check can be walked around rather than broken.

it "keeps a python module planted by the pull request out of every step"
assert_equal "1" \
  "$(sed -n 's/^      PYTHONSAFEPATH: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$_WORKFLOW")" \
  "the review job sets PYTHONSAFEPATH"

_plant() {
  cat > "$1/json.py" <<'PY'
def load(handle):
    return {"model": "claude-opus-5-5", "effort": "xhigh --planted-flag", "max_turns": 60}
PY
}
box="$(_sandbox planted-bare)"
printf '{"model": "claude-opus-5-5", "effort": "xhigh", "max_turns": 60}' > "$box/temp/config.json"
_plant "$box"
_run_step args "$box" PYTHONSAFEPATH=
# Proves the plant is live, so the next assertion is testing something. If a
# future python imports json before the working directory is consulted, this
# is the line that says the case no longer reaches the attack.
assert_contains "--planted-flag" "without the guard, the planted module decides the argv" -- _argv "$box"

box="$(_sandbox planted-guarded)"
printf '{"model": "claude-opus-5-5", "effort": "xhigh", "max_turns": 60}' > "$box/temp/config.json"
_plant "$box"
_run_step args "$box" PYTHONSAFEPATH=1
assert_not_contains "--planted-flag" "with it, the planted module is never imported" -- _argv "$box"
assert_equal "xhigh" "$(_after "$box" --effort)" "and the real config is what is read"

# --- the fallback: same review, other account ----------------------------------

it "retries the same review, not a different one"
# The fallback is a second attempt at the SAME review. Any input that differs
# but the credential — another prompt, other claude_args — would make the
# retry a different review, announced as the same one.
_without_token() { _step "$1" with | grep -v '^claude_code_oauth_token:'; }
# Two empty blocks are equal too; make sure there is something being compared.
assert_contains 'claude_args: ${{ steps.args.outputs.value }}' \
  "the first attempt's inputs were read" -- _step claude with
assert_equal "$(_without_token claude)" "$(_without_token claude_fallback)" \
  "every input but the credential is identical"
for field in uses continue-on-error timeout-minutes; do
  assert_equal "$(_step claude "$field")" "$(_step claude_fallback "$field")" \
    "the same $field"
done

it "spends the other account, not the same one twice"
assert_equal 'claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}' \
  "$(_step claude with | grep '^claude_code_oauth_token:')" "the first attempt uses the first token"
assert_equal 'claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN_FALLBACK }}' \
  "$(_step claude_fallback with | grep '^claude_code_oauth_token:')" "the retry uses the fallback token"

it "runs the retry only on the decision to retry"
assert_equal "steps.fallback.outputs.use == 'yes'" "$(_step claude_fallback if)" \
  "the retry is gated on the decision step, and on nothing looser"

it "lets only a yes or a no of the fallback secret into the decision step"
# The decision step runs after the checkout, in the pull request's working
# directory. It needs to know whether a fallback exists, never what it is.
assert_equal "FALLBACK_AVAILABLE: \${{ secrets.CLAUDE_CODE_OAUTH_TOKEN_FALLBACK != '' && 'yes' || 'no' }}" \
  "$(_step fallback env | grep 'CLAUDE_CODE_OAUTH_TOKEN_FALLBACK')" \
  "the secret appears once, inside a comparison, and nowhere else"

# --- the decision, executed ----------------------------------------------------

# The action's own, fixed, name for the file — shared by both attempts.
_fixed() { printf '%s/temp/claude-execution-output.json' "$1"; }

it "decides yes on the real refusal when a fallback exists"
box="$(_sandbox decide-yes)"
cp "$FIXTURES/api-429-quota.json" "$(_fixed "$box")"
_run_step fallback "$box" EXECUTION_FILE="$(_fixed "$box")" FALLBACK_AVAILABLE=yes
assert_equal "yes" "$(_output "$box" use)" "429 at turn 1, zero cost, a token to fall back to"

it "moves the first attempt's record out of the retry's way"
# Both attempts write the same fixed path, and an attempt that dies before it
# starts reports whatever file is already there as its own. Left in place, the
# first attempt's 429 would be read as the retry's record.
assert_status 1 "nothing is left at the path the retry writes" -- test -e "$(_fixed "$box")"
assert_status 0 "the refusal is kept beside it" -- \
  test -f "$box/temp/claude-execution-output.primary.json"

it "decides no when there is no fallback token"
box="$(_sandbox decide-notoken)"
cp "$FIXTURES/api-429-quota.json" "$(_fixed "$box")"
_run_step fallback "$box" EXECUTION_FILE="$(_fixed "$box")" FALLBACK_AVAILABLE=no
assert_equal "no" "$(_output "$box" use)" "the refusal alone is not enough"
assert_status 0 "and the record stays where the steps below read it" -- test -f "$(_fixed "$box")"

it "decides no when the first attempt left no execution file"
box="$(_sandbox decide-nofile)"
_run_step fallback "$box" EXECUTION_FILE= FALLBACK_AVAILABLE=yes
assert_equal "no" "$(_output "$box" use)" "no evidence, no second review"

it "decides no on a review that ran"
box="$(_sandbox decide-ran)"
python3 -c '
import json, sys
json.dump([{"type": "system", "subtype": "init"},
           {"type": "result", "subtype": "success", "is_error": False,
            "num_turns": 24, "total_cost_usd": 0.61}], open(sys.argv[1], "w"))' "$(_fixed "$box")"
_run_step fallback "$box" EXECUTION_FILE="$(_fixed "$box")" FALLBACK_AVAILABLE=yes
assert_equal "no" "$(_output "$box" use)" "a finished review is never run a second time"

# --- which attempt counts, executed --------------------------------------------

it "counts the retry when there was one"
box="$(_sandbox resolve-fallback)"
cp "$FIXTURES/api-429-quota.json" "$(_fixed "$box")"
_run_step review_result "$box" RETRIED=yes PRIMARY="$(_fixed "$box")" FALLBACK="$(_fixed "$box")"
assert_equal "$(_fixed "$box")" "$(_output "$box" execution_file)" "the retry's trace is the one read below"
assert_equal "fallback" "$(_output "$box" credential)" "and it says which account ran it"

it "says so where someone will see it"
# A fallback that works hides why it was needed. An expired first token would
# be covered on every review, silently, until the second quota ran out too.
assert_contains "::warning title=Review retried on the fallback credential::" \
  "the run carries a warning annotation" -- cat "$box/log"
assert_contains "CLAUDE_CODE_OAUTH_TOKEN_FALLBACK" \
  "and the job summary names the credential that ran it" -- cat "$box/summary"

it "counts a retry that left nothing as a review that did not complete"
# Killed by its timeout, or dead before it started: either way the retry wrote
# no record. The first attempt's 429 is not its record, and reading it would
# post "not reviewed: usage limit" over findings the retry may have posted.
box="$(_sandbox resolve-empty-retry)"
_run_step review_result "$box" RETRIED=yes PRIMARY="$(_fixed "$box")" FALLBACK=
assert_equal "" "$(_output "$box" execution_file)" "no record, not the first attempt's record"
assert_equal "fallback" "$(_output "$box" credential)" "and still the retry's account"
box="$(_sandbox resolve-gone-retry)"
_run_step review_result "$box" RETRIED=yes PRIMARY="$(_fixed "$box")" FALLBACK="$(_fixed "$box")"
assert_equal "" "$(_output "$box" execution_file)" "an output naming a file that is not there counts as nothing"

it "counts the first attempt when there was no retry"
box="$(_sandbox resolve-primary)"
_run_step review_result "$box" RETRIED=no PRIMARY=/first.json FALLBACK=
assert_equal "/first.json" "$(_output "$box" execution_file)" "the first attempt's trace"
assert_equal "primary" "$(_output "$box" credential)" "on the first account"
assert_not_contains "::warning" "and raises no alarm" -- cat "$box/log"

it "reads the attempt that counts everywhere below the choice"
# The choice is made once so nothing can pick differently from it. That holds
# only while every reader asks the choice: one step pointed back at
# `steps.claude` would read the first attempt's 429 after a successful retry
# and announce the review unavailable.
_stray_readers() {
  python3 - "$_WORKFLOW" <<'PY'
import io
import re
import sys

text = io.open(sys.argv[1], encoding="utf-8").read()
stray = []
for block in re.split(r"(?m)^      - ", text)[1:]:
    ident = re.search(r"(?m)^\s+id: (\S+)\s*$", block)
    ident = ident.group(1) if ident else block.splitlines()[0]
    if ident in ("fallback", "review_result"):
        continue
    if re.search(r"steps\.(claude|claude_fallback)\.outputs\.execution_file", block):
        stray.append(ident)
print(" / ".join(stray) if stray else "none")
PY
}
assert_equal "none" "$(_stray_readers)" "only the choice itself reads the attempts directly"
assert_contains "steps.review_result.outputs.execution_file" \
  "and the notice reads the choice" -- _step "Report that the review was unavailable" env

# --- the notice names the secret to replace ------------------------------------

it "names the fallback secret when it is the fallback that was rejected"
# After a retry, a 401 is the FALLBACK's token. Naming the first one sends a
# maintainer to rotate a secret that was only rate-limited, while the broken
# one stays broken until the next limit is an outage again.
box="$(_sandbox notice-fallback)"
_run_step "Report that the review was unavailable" "$box" \
  EXECUTION_FILE="$FIXTURES/auth-401.json" VERDICT=unavailable CREDENTIAL=fallback \
  PR_NUMBER=1 HEAD_SHA=0000000 GH_TOKEN=unused
assert_contains '`CLAUDE_CODE_OAUTH_TOKEN_FALLBACK` secret' \
  "the comment names the fallback secret" -- cat "$box/posted"
assert_contains "CLAUDE_CODE_OAUTH_TOKEN_FALLBACK was rejected" \
  "and so does the check's headline" -- cat "$box/posted"

it "names the first secret when there was no retry"
box="$(_sandbox notice-primary)"
_run_step "Report that the review was unavailable" "$box" \
  EXECUTION_FILE="$FIXTURES/auth-401.json" VERDICT=unavailable CREDENTIAL=primary \
  PR_NUMBER=1 HEAD_SHA=0000000 GH_TOKEN=unused
assert_contains '`CLAUDE_CODE_OAUTH_TOKEN` secret' \
  "the comment names the first secret" -- cat "$box/posted"
assert_not_contains "CLAUDE_CODE_OAUTH_TOKEN_FALLBACK" \
  "and does not mention a fallback that never ran" -- cat "$box/posted"
