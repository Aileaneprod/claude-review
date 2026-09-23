# The steps of review.yml that decide what reaches the reviewer's command line
# — run, not read.
#
# They are inline shell inside the workflow, where no other case can reach
# them. A mistake in one passes every script test in this directory and shows
# up only on a live pull request: as a model nobody asked for, or as a flag the
# pull request itself chose.
#
# So each `run:` block is lifted out of the workflow and executed here, in a
# sandbox that stands in for the runner: RUNNER_TEMP and GITHUB_OUTPUT. The
# sandbox is also the step's working directory, as the pull request's checkout
# is on the runner — which is what lets the cases below plant a file there.
# Read out of the workflow with stock python3, the way execution-artifact.sh
# does.

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
  mkdir -p "$box/temp"
  : > "$box/output"
  printf '%s' "$box"
}

# _run_step ID BOX [VAR=value …] — execute the step's script in BOX, as its
# working directory. What it prints lands in BOX/log.
_run_step() {
  local id="$1" box="$2"; shift 2
  _step "$id" run > "$box/step.sh"
  (cd "$box" && env RUNNER_TEMP="$box/temp" GITHUB_OUTPUT="$box/output" "$@" \
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
# so "--model<newline>x" passes on `--model` alone.
_after() {
  _argv "$1" | python3 -c '
import sys
argv = sys.stdin.read().splitlines()
flag = sys.argv[1]
print(argv[argv.index(flag) + 1] if flag in argv[:-1] else "(no %s)" % flag)' "$2"
}

# --- claude_args ---------------------------------------------------------------

it "carries the configured model to the CLI"
box="$(_sandbox args)"
printf '{"model": "claude-opus-5-5", "max_turns": 60}' > "$box/temp/config.json"
_run_step args "$box"
assert_equal "claude-opus-5-5" "$(_after "$box" --model)" "model becomes the argument after --model"
assert_equal "60" "$(_after "$box" --max-turns)" "max_turns becomes the argument after --max-turns"

it "passes no --model at all for a model left empty"
# Empty means "the action's own default", not `--model ""`.
box="$(_sandbox args-empty)"
printf '{"model": "", "max_turns": 60}' > "$box/temp/config.json"
_run_step args "$box"
assert_equal "60" "$(_after "$box" --max-turns)" "the step ran and wrote its arguments"
assert_not_contains "--model" "no --model for an empty model" -- _argv "$box"

it "gets the shipped defaults all the way to the command line"
# The whole chain, as a pull request with no .claude-review.yml would run it:
# defaults.yml, through resolve-config.sh, into the step that builds the argv.
box="$(_sandbox args-defaults)"
mkdir -p "$box/repo"
"$SCRIPTS/resolve-config.sh" --repo-root "$box/repo" > "$box/temp/config.json"
_run_step args "$box"
assert_equal "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["max_turns"])' "$box/temp/config.json")" \
  "$(_after "$box" --max-turns)" "the default turn budget reaches the CLI"

# --- python in the pull request's working directory ----------------------------
#
# Every step after the checkout runs in the pull request's head, and `python3 -c`
# puts that directory first on sys.path. A `json.py` the pull request adds is
# then the `json` these steps import — AFTER resolve-config.sh has checked the
# model, so the check can be walked around rather than broken.

it "keeps a python module planted by the pull request out of every step"
assert_equal "1" \
  "$(sed -n 's/^      PYTHONSAFEPATH: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$_WORKFLOW")" \
  "the review job sets PYTHONSAFEPATH"

_plant() {
  cat > "$1/json.py" <<'PY'
def load(handle):
    return {"model": "claude-opus-5-5 --planted-flag", "max_turns": 60}
PY
}
box="$(_sandbox planted-bare)"
printf '{"model": "claude-opus-5-5", "max_turns": 60}' > "$box/temp/config.json"
_plant "$box"
_run_step args "$box" PYTHONSAFEPATH=
# Proves the plant is live, so the next assertion is testing something. If a
# future python imports json before the working directory is consulted, this
# is the line that says the case no longer reaches the attack.
assert_contains "--planted-flag" "without the guard, the planted module decides the argv" -- _argv "$box"

box="$(_sandbox planted-guarded)"
printf '{"model": "claude-opus-5-5", "max_turns": 60}' > "$box/temp/config.json"
_plant "$box"
_run_step args "$box" PYTHONSAFEPATH=1
assert_not_contains "--planted-flag" "with it, the planted module is never imported" -- _argv "$box"
assert_equal "claude-opus-5-5" "$(_after "$box" --model)" "and the real config is what is read"
