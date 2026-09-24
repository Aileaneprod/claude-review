# eval/run-eval.sh as a measuring instrument: repeated runs, rates, thresholds,
# and the lessons it injects.
#
# One live run is one sample. On 2026-09-24 fixture 04 at effort `high` found
# its planted defect once in two runs on the same code, so a single run cannot
# tell an improvement from luck. --repeat turns each planted defect and each
# decoy into a rate, and --learnings / --drop-lesson let a lesson be measured
# with and without it.
#
# The model is replaced by a fake `claude` on PATH, so nothing here spends
# quota. The fake answers from a script per case, counts its calls, and keeps
# the prompt it was given.

_EVAL="$SCRIPTS/../eval/run-eval.sh"
_FIX="04-ts-floating-promise"

# _fake SCRIPT — install a fake claude. SCRIPT is python that sets `findings`
# (a list) or `error` (a string), given `run` (1-based call count).
_fake() {
  local dir="$TESTTMP/fakebin" state="$TESTTMP/fakestate"
  rm -rf "$dir" "$state"
  mkdir -p "$dir" "$state"
  printf '%s\n' "$1" >"$state/answer.py"
  cat >"$dir/claude" <<EOF
#!/usr/bin/env bash
count_file="$state/count"
run=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$run" >"\$count_file"
cat >"$state/prompt.\$run"
printf '%s\n' "\$@" >"$state/args.\$run"
python3 - "\$run" "$state/answer.py" <<'PY'
import json, sys
run = int(sys.argv[1])
scope = {"run": run, "findings": [], "error": None}
exec(open(sys.argv[2], encoding="utf-8").read(), scope)
if scope["error"]:
    print(json.dumps({"is_error": True, "subtype": scope["error"]}))
else:
    print(json.dumps({"subtype": "success", "structured_output": {"findings": scope["findings"]}}))
PY
EOF
  chmod +x "$dir/claude"
}

_path_with_fake() {
  local dir="$TESTTMP/fakebin"
  command -v cygpath >/dev/null 2>&1 && dir="$(cygpath -u "$dir")"
  printf '%s:%s' "$dir" "$PATH"
}

# _eval ARGS… — run the harness live against the fake, into its own directory.
_eval() {
  PATH="$(_path_with_fake)" "$_EVAL" --live --fixture "$_FIX" --out-dir "$TESTTMP/eval-out" "$@" 2>&1
}

_calls() { cat "$TESTTMP/fakestate/count" 2>/dev/null || echo 0; }

# The planted defect, in words the fixture's must_find matches.
_HIT='findings = [{"path": "src/orders.ts", "line": 33, "severity": "important", "title": "notifyOps is not awaited", "evidence": "notifyOps(`refund failed`, err);"}]'

# --- one run: the harness as it always was ------------------------------------

it "keeps the single-run table and gate when --repeat is not given"
_fake "$_HIT"
assert_contains "TOTAL" "the classic table is printed" -- _eval
assert_status 0 "a found defect passes" -- _eval
_fake 'findings = []'
assert_status 1 "a missed defect still fails the gate" -- _eval

# --- repeated runs --------------------------------------------------------------

it "reviews each fixture as many times as asked"
_fake "$_HIT"
_eval --repeat 3 >/dev/null
assert_equal "3" "$(_calls)" "three reviews of one fixture"

it "reports a defect found in some runs as a rate, and gates on it"
# Found on odd runs only: 2 of 3. The fake counts calls across invocations, so
# it is reinstalled before each one, or the second would see runs 4 to 6.
_odd() { _fake "findings = [] if run % 2 == 0 else ${_HIT#findings = }"; }
_odd; assert_contains "2/3" "the table shows 2 of 3" -- _eval --repeat 3
_odd; assert_status 1 "below the default threshold of every run, it fails" -- _eval --repeat 3
_odd; assert_status 0 "at a threshold of 0.6 it passes" -- _eval --repeat 3 --min-hit-rate 0.6
_odd; _eval --repeat 3 >/dev/null
_rate() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(round(d["fixtures"][sys.argv[2]]["must_find"]["floating-promise-notifyops"], 2), d["repeat"])' \
    "$TESTTMP/eval-out/summary.json" "$_FIX"
}
assert_equal "0.67 3" "$(_rate)" "summary.json records the rate and the number of runs"

it "counts a decoy by the share of runs that hit it"
_decoy_once() { _fake 'findings = [{"path": "src/orders.ts", "line": 16, "severity": "important", "title": "trackAsync is not awaited", "evidence": "void auditLog(event, orderId)"}] if run == 1 else []'; }
_decoy_once; assert_status 1 "one decoy hit in three fails the default of none" -- _eval --repeat 3 --min-hit-rate 0
_decoy_once; assert_status 0 "and passes a tolerance of 0.4" -- _eval --repeat 3 --min-hit-rate 0 --max-decoy-rate 0.4

it "leaves a run that failed to execute out of the rate"
# Run 2 is an infrastructure failure. Counting it as a miss would call a
# network blip a prompt regression.
_blip() { _fake "error = 'cli_failure' if run == 2 else None
${_HIT}"; }
_blip; assert_contains "2/3" "two of three runs were scored" -- _eval --repeat 3
_blip; _eval --repeat 3 >/dev/null
assert_equal "1.0" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fixtures"][sys.argv[2]]["must_find"]["floating-promise-notifyops"])' "$TESTTMP/eval-out/summary.json" "$_FIX")" \
  "found in both scored runs is a rate of 1"

# --- which lessons the prompt carries --------------------------------------------

it "injects the shipped lessons by default"
_fake "$_HIT"
_eval >/dev/null
assert_contains "## Judge a finding against the commit it was made on" \
  "the first lesson is in the prompt" -- cat "$TESTTMP/fakestate/prompt.1"

it "injects no lesson with --learnings none"
_fake "$_HIT"
_eval --learnings none >/dev/null
assert_not_contains "## Judge a finding against the commit it was made on" \
  "no lesson is in the prompt" -- cat "$TESTTMP/fakestate/prompt.1"
assert_contains "No learnings recorded" "and the prompt says so" -- cat "$TESTTMP/fakestate/prompt.1"

it "drops exactly one lesson with --drop-lesson"
_fake "$_HIT"
_eval --drop-lesson 1 >/dev/null
assert_not_contains "## Judge a finding against the commit it was made on" \
  "lesson 1 is gone" -- cat "$TESTTMP/fakestate/prompt.1"
assert_contains "## Fixtures can be referentially and temporally valid while still lying" \
  "lesson 2 is still there" -- cat "$TESTTMP/fakestate/prompt.1"
assert_contains "without lesson 1: Judge a finding against the commit it was made on" \
  "summary.json names what was dropped" -- cat "$TESTTMP/eval-out/summary.json"

# --- refusals ---------------------------------------------------------------------

it "refuses what it cannot measure"
_fake "$_HIT"
assert_status 1 "--repeat 0 is refused" -- _eval --repeat 0
assert_status 1 "--repeat abc is refused" -- _eval --repeat abc
assert_status 1 "a rate above 1 is refused" -- _eval --repeat 2 --min-hit-rate 2
assert_status 1 "a lesson that does not exist is refused" -- _eval --drop-lesson 99
assert_status 1 "--learnings and --drop-lesson together are refused" -- _eval --learnings none --drop-lesson 1

it "does not empty a directory it did not create"
mkdir -p "$TESTTMP/precious"
printf 'keep me' >"$TESTTMP/precious/notes.txt"
assert_status 1 "a foreign, non-empty --out-dir is refused" -- \
  env PATH="$(_path_with_fake)" "$_EVAL" --live --fixture "$_FIX" --out-dir "$TESTTMP/precious"
assert_equal "keep me" "$(cat "$TESTTMP/precious/notes.txt")" "and its content is untouched"
