#!/usr/bin/env bash
#
# explain-failure.sh — say why a review did not finish, and what it left behind.
#
# Usage:
#   explain-failure.sh --execution-file FILE [--count-out FILE]
#                      [--status-out FILE]
#
#   --execution-file FILE  The action's execution log: a JSON array of SDK
#                          messages, written even when the run crashes.
#   --count-out FILE       Write the number of inline findings this run posted
#                          to FILE. Default: none.
#   --status-out FILE      Write the HTTP status the API failed with — 429, 401,
#                          5xx — to FILE, and leave FILE empty when the run did
#                          not end on one. Default: none.
#
# WHY --status-out EXISTS. The status was already recovered and printed below,
# and printed only to the run log, which nobody opens. Aileaneprod/korbyx run
# 35266745831 ended on `api_error_status 429`, `terminal_reason api_error` — the
# subscription's usage limit — while the comment the author actually read said
# "The reviewer did not complete", the same sentence a timeout or an expired
# token produces. Four pull requests (korbyx #228-#231) sat unreviewed overnight
# because nobody learned the quota was gone. review.yml turns this file into the
# sentence on the pull request, so the cause has to leave here in a form a shell
# can branch on, not just in prose.
#
# Prints a diagnostic to stdout and exits 0 even when the file is missing or
# unreadable. Nothing here may fail the job: it runs on the path where the
# review has ALREADY failed, and a broken diagnostic that masks the real
# failure is worse than no diagnostic.
#
# WHY THIS IS A SCRIPT AND NOT A `run:` BLOCK. It used to be a heredoc inside
# review.yml. Past a certain size actionlint stops returning on that file — it
# hangs rather than failing, which is the worst way for a check to break,
# because the natural reaction is to assume the linter is fine and move on.
# TUNING.md calls actionlint non-optional, so anything that makes it unusable
# has to go. Logic belongs in scripts/ here anyway; that is where the rest of
# this pipeline keeps it.
#
# Requires: python3.

set -euo pipefail

execution_file=""
count_out=""
status_out=""

die() {
  printf 'explain-failure: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execution-file) [ "$#" -ge 2 ] || die "--execution-file requires a value"; execution_file="$2"; shift 2 ;;
    --count-out)      [ "$#" -ge 2 ] || die "--count-out requires a value";      count_out="$2";      shift 2 ;;
    --status-out)     [ "$#" -ge 2 ] || die "--status-out requires a value";     status_out="$2";     shift 2 ;;
    -h|--help)        sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# The empty answer is on disk before anything can fail to put it there, the same
# discipline review.yml uses for the verdict and the posted witness. Empty means
# "cause unknown", which is the only safe default: it picks the wording that
# blames nothing, rather than naming a token that may be perfectly fine. It
# cannot be left to the python below, which does not run at all when the
# execution file is missing.
if [ -n "$status_out" ]; then
  printf '' > "$status_out"
fi

# A missing execution file is an ordinary outcome — the run may have died before
# the action wrote one. Record zero findings and say so.
if [ -z "$execution_file" ] || [ ! -f "$execution_file" ]; then
  echo "no execution file — the run died before the action wrote one"
  [ -n "$count_out" ] && printf '0' > "$count_out"
  exit 0
fi

python3 - "$execution_file" "$count_out" "$status_out" <<'PY'
import json
import sys

execution_path, count_path, status_path = sys.argv[1], sys.argv[2], sys.argv[3]


def emit_count(value):
    if count_path:
        with open(count_path, "w", encoding="utf-8") as handle:
            handle.write(str(value))


def emit_status(value):
    """The cause, in the one form review.yml can branch on.

    Called only where a status actually exists, unlike emit_count: the caller
    has already put the empty "cause unknown" answer on disk, so every path that
    does not reach here leaves it empty, which is what it means. Writing a guess
    would have the notice name a cause this run has no evidence for — the same
    class of claim the notice exists to stop making.
    """
    if status_path:
        with open(status_path, "w", encoding="utf-8") as handle:
            handle.write(str(value))


try:
    with open(execution_path, encoding="utf-8") as handle:
        messages = json.load(handle)
except (OSError, ValueError) as exc:
    print("unreadable execution file: %s" % exc)
    emit_count(0)
    raise SystemExit(0)

if not isinstance(messages, list):
    print("unexpected execution file shape: %s" % type(messages).__name__)
    emit_count(0)
    raise SystemExit(0)


def content_blocks(message):
    """The SDK nests content under `message` on some records and not others.

    And on one record it is neither: the `system`/`init` line that opens every
    execution file carries `"message": "Claude Code initialized"`, a plain
    string. `(message.get("message") or {})` let that string through the `or`
    and the following `.get` raised AttributeError on the first record of every
    real run — so this diagnostic died before printing the finding count, on
    every invocation, unnoticed because the workflow calls it with `|| true`.
    Check the type; do not lean on truthiness to stand in for it.
    """
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if content is None:
        nested = message.get("message")
        content = nested.get("content") if isinstance(nested, dict) else None
    return content if isinstance(content, list) else []


results = [m for m in messages if isinstance(m, dict) and m.get("type") == "result"]

if not results:
    print("no result record — the run died before finishing")
else:
    last = results[-1]
    for key in ("subtype", "is_error", "num_turns", "duration_ms",
                "total_cost_usd", "api_error_status", "terminal_reason",
                "permission_denials_count"):
        if key in last:
            print("  %-18s %s" % (key, last[key]))

    # api_error_status is the single most useful field: 401 means the token is
    # bad, 429 means quota, 5xx means Anthropic-side.
    status = last.get("api_error_status")
    hint = {
        401: "CLAUDE_CODE_OAUTH_TOKEN is invalid or expired - regenerate with `claude setup-token`.",
        403: "The token is not authorised for this use.",
        429: "Rate limited or subscription quota exhausted.",
    }.get(status)
    # The same field, out of the log and into the notice. Only a bare integer
    # crosses: it is read back into a shell `case` in review.yml, and a
    # diagnostic that runs on the failure path is the last place that should be
    # handing a shell something it did not expect. `bool` is excluded because
    # `isinstance(True, int)` is true in python and `api_error_status: true`
    # would otherwise arrive as "True" — a cause nobody can act on.
    if isinstance(status, int) and not isinstance(status, bool):
        emit_status(status)

    if hint:
        print("  hint               %s" % hint)
    elif last.get("subtype") == "error_max_turns":
        print("  hint               the review ran out of turns. Raising max_turns"
              " is one answer; the denied-tool line below is usually the better"
              " one, because a denied call burns a turn and produces nothing.")
    elif (last.get("is_error") and not (last.get("num_turns") or 0) > 1
            and not last.get("total_cost_usd")):
        print("  hint               errored on turn 1 at zero cost, which almost"
              " always means the credential was rejected. Regenerate it with"
              " `claude setup-token` and re-set the repository secret.")

# Which tools did it reach for and not have?
#
# This reads `permission_denials` off the result record, which the CLI itself
# documents as "the authoritative record" of denials. Two earlier versions of
# this tried to infer it from the message stream instead and both were wrong:
# reading `name` off a `tool_result` block always yields nothing (the name lives
# on the `tool_use`, joined by `tool_use_id`), and treating `is_error` as a
# denial counts every ordinary tool failure — a Read of a missing file, a grep
# that matches nothing — as a permissions problem. Each printed a confident line
# that was noise. The field is right here; use it.
#
# Names only, never the tool input: inputs carry repository content and these
# logs are public on a public repository.
denied = {}
for result in results:
    entries = result.get("permission_denials")
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = entry.get("tool_name") or "unknown"
        denied[name] = denied.get(name, 0) + 1

if denied:
    print("  denied tools       %s"
          % ", ".join("%s x%d" % pair for pair in sorted(denied.items())))
elif results and results[-1].get("permission_denials_count"):
    # The count is present but the list is not — say so rather than staying
    # silent, so the gap is visible instead of looking like zero denials.
    print("  denied tools       %s denial(s), tool names not recorded in this run"
          % results[-1]["permission_denials_count"])

# Inline comments post the moment they are made, so a run that dies late has
# usually already put real findings on the diff.
#
# Count the calls that SUCCEEDED, not the calls that were made. A comment can be
# rejected — GitHub refuses an anchor outside the diff hunks, which happened
# twice on this repository's own first pull request — and reporting it as posted
# sends the author looking for a comment that is not there. That is the exact
# failure this whole notice exists to prevent, so it must not commit it itself.
#
# A call whose result never arrived (the run died between the two) is NOT
# counted: under-reporting costs the author a comment they will find anyway,
# over-reporting costs them a search for one that does not exist.
inline_calls = set()
for message in messages:
    for block in content_blocks(message):
        if (isinstance(block, dict)
                and block.get("type") == "tool_use"
                and "create_inline_comment" in str(block.get("name", ""))):
            inline_calls.add(block.get("id"))

posted = 0
for message in messages:
    for block in content_blocks(message):
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        if block.get("tool_use_id") in inline_calls and not block.get("is_error"):
            posted += 1

attempted = len(inline_calls)
if attempted != posted:
    print("  findings posted    %d (of %d attempted; the rest were rejected or"
          " unconfirmed)" % (posted, attempted))
else:
    print("  findings posted    %d" % posted)
emit_count(posted)
PY
