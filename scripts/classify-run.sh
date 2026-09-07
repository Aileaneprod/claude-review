#!/usr/bin/env bash
#
# classify-run.sh — decide, once, whether the reviewer actually completed.
#
# Usage:
#   classify-run.sh --execution-file FILE [--verdict-out FILE]
#
# Prints a human-readable line and writes one word — `completed` or
# `unavailable` — to --verdict-out. It never fails the job.
#
# WHY THIS EXISTS. review.yml used to branch on `steps.claude.outcome`: summary
# on success, "review unavailable" on failure. That reads the action's exit
# code, and the action's exit code is not the same question as "did the review
# happen". `claude-code-action` validates the turn count AFTER the run and fails
# the step when `num_turns` exceeds `--max-turns`, even when the CLI itself
# reported success:
#
#   {"type":"result","subtype":"success","is_error":false,"num_turns":43,
#    "terminal_reason":"completed","total_cost_usd":0.87}
#   ##[error]Claude reported a successful result after 43 turns, exceeding the
#            configured maximum of 40
#
# That is Aileaneprod/korbyx#110, run 34058925818. A finished review, five
# minutes and $0.87 of it, was announced to the author as "AI review
# unavailable" and thrown away. The action writes the execution file BEFORE it
# runs that assertion — 20:50:22.4330005Z against 20:50:22.4373406Z — so the
# evidence of success is on disk while the step goes red.
#
# The decision is computed HERE, once, and both later steps read the result. A
# GitHub `if:` expression cannot read a file, so the alternative — two steps
# each doing their own shell test — would let the two drift apart and produce
# the two failure modes that matter: both branches speaking, or neither.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM. A `success` result record does not prove
# the findings reached GitHub. The action buffers inline comments and flushes
# them in a later step, which starts ~9 ms after the execution file is written,
# so no field in that file can witness the flush. This script answers "did the
# reviewer finish", nothing more. Whether anything was actually POSTED is
# decided downstream by post-review.sh, which is the only thing that knows —
# and the "unavailable" notice keys off that, not off this verdict.
#
# Requires: python3.

set -euo pipefail

execution_file=""
verdict_out=""

die() { printf 'classify-run: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execution-file) [ "$#" -ge 2 ] || die "--execution-file requires a value"; execution_file="$2"; shift 2 ;;
    --verdict-out)    [ "$#" -ge 2 ] || die "--verdict-out requires a value";    verdict_out="$2";    shift 2 ;;
    -h|--help)        sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

emit() {
  # `unavailable` is the answer to every question this script cannot answer.
  # A crash, an unreadable file, an argument nobody anticipated: all of them
  # must land on the branch that speaks to the author, never on the branch that
  # claims a review happened.
  printf '%s' "$1" > "${verdict_out:-/dev/null}"
  printf 'classify-run: %s — %s\n' "$1" "$2"
}

if [ -z "$execution_file" ] || [ ! -f "$execution_file" ]; then
  emit unavailable "no execution file; the action never wrote one"
  exit 0
fi

python3 - "$execution_file" "${verdict_out:-}" <<'PY'
import json
import sys

execution_path, verdict_path = sys.argv[1], sys.argv[2]


def emit(verdict, reason):
    if verdict_path:
        with open(verdict_path, "w", encoding="utf-8") as handle:
            handle.write(verdict)
    print("classify-run: %s — %s" % (verdict, reason))
    raise SystemExit(0)


try:
    with open(execution_path, encoding="utf-8") as handle:
        messages = json.load(handle)
except (OSError, ValueError) as exc:
    emit("unavailable", "unreadable execution file: %s" % exc)

if not isinstance(messages, list):
    emit("unavailable",
         "unexpected execution file shape: %s" % type(messages).__name__)

results = [m for m in messages if isinstance(m, dict) and m.get("type") == "result"]

if not results:
    emit("unavailable", "no result record; the run died before finishing")

# The LAST one, not any one. Nothing documents whether a file can hold more than
# one result record, and "contains a success record" would let an early success
# followed by a real failure pass. explain-failure.sh already reads results[-1];
# match it rather than inventing a second reading of the same file.
last = results[-1]
subtype = last.get("subtype")
is_error = last.get("is_error")

# `is False`, not `not is_error`. A record missing the field would otherwise
# read as a pass, and this gate exists precisely to stop an absent fact from
# being taken for a good one.
if subtype == "success" and is_error is False:
    emit("completed",
         "the CLI finished (subtype=success, num_turns=%s)"
         % last.get("num_turns", "?"))

emit("unavailable",
     "the CLI did not finish (subtype=%s, is_error=%s)" % (subtype, is_error))
PY
