#!/usr/bin/env bash
#
# should-fall-back.sh — decide whether a refused review may be retried on the
# fallback credential.
#
# Usage:
#   should-fall-back.sh --execution-file FILE --decision-out FILE
#                       [--fallback-available yes|no]
#
#   --execution-file FILE   The first attempt's execution log.
#   --decision-out FILE     Receives one word, `yes` or `no`.
#   --fallback-available    Whether a fallback credential was passed at all.
#                           Default `no`.
#
# Prints the reason for the decision on stdout and always exits 0: this runs on
# the path where a review has just failed, and it must never add a second
# failure to the one it is deciding about.
#
# WHY THIS EXISTS. The subscription behind CLAUDE_CODE_OAUTH_TOKEN reached its
# weekly limit on 2026-09-17 and again on 2026-09-22, and every review in every
# repository stopped until it reset. A second token on a different subscription
# turns that outage into a non-event — if the retry is allowed to happen, and
# only then.
#
# WHY SO NARROW. A retry is a whole second review, and a review is not
# idempotent: inline comments post the moment the reviewer makes them. So the
# retry is allowed only when the first attempt provably did NOTHING — refused
# on its first turn, at zero cost — and never when a limit arrives halfway
# through. Retrying a half-finished review would post its findings a second
# time, on a pull request whose author has already read the first copy, and
# spend a second account's quota to do it. Measured on the refusal that
# prompted this: `num_turns` 1, `total_cost_usd` 0, `api_error_status` 429.
#
# The statuses that qualify are the ones another account can cure: 429, the
# account's own limit, and 401/403, the account's own credential. A 5xx is
# Anthropic being down, the same for every account, and a retry would only
# spend the fallback's quota on the outage.
#
# Requires: python3.

set -euo pipefail

execution_file=""
decision_out=""
fallback_available="no"

die() { printf 'should-fall-back: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execution-file)     [ "$#" -ge 2 ] || die "--execution-file requires a value";     execution_file="$2";     shift 2 ;;
    --decision-out)       [ "$#" -ge 2 ] || die "--decision-out requires a value";       decision_out="$2";       shift 2 ;;
    --fallback-available) [ "$#" -ge 2 ] || die "--fallback-available requires a value"; fallback_available="$2"; shift 2 ;;
    -h|--help)            sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                    die "unknown argument: $1" ;;
  esac
done

[ -n "$decision_out" ] || die "--decision-out is required"

# The pessimistic answer is on disk before anything below can fail to replace
# it: a decision step that dies must leave `no`, never a stale `yes` from an
# earlier attempt of the same run.
printf 'no' > "$decision_out"

if [ "$fallback_available" != "yes" ]; then
  printf 'should-fall-back: no — no fallback credential was passed\n'
  exit 0
fi

if [ -z "$execution_file" ] || [ ! -f "$execution_file" ]; then
  printf 'should-fall-back: no — no execution file, so nothing proves the first attempt did nothing\n'
  exit 0
fi

python3 - "$execution_file" "$decision_out" <<'PY' || printf 'should-fall-back: no — the execution file could not be read\n'
import json
import sys

path, out = sys.argv[1], sys.argv[2]

# Only the statuses another ACCOUNT can cure. 5xx is the service, not the
# account, and would only spend the fallback on the same outage.
CURABLE = (429, 401, 403)

try:
    with open(path, encoding="utf-8") as handle:
        messages = json.load(handle)
except (OSError, ValueError) as error:
    print("should-fall-back: no — unreadable execution file (%s)" % error)
    raise SystemExit(0)

results = [m for m in messages if isinstance(m, dict) and m.get("type") == "result"] \
    if isinstance(messages, list) else []
if not results:
    print("should-fall-back: no — no result record, the run died before finishing")
    raise SystemExit(0)

last = results[-1]
status = last.get("api_error_status")
turns = last.get("num_turns")
cost = last.get("total_cost_usd")

# A bool is an int in python, and `api_error_status: true` must not read as 1.
if not isinstance(status, int) or isinstance(status, bool) or status not in CURABLE:
    print("should-fall-back: no — status %r is not one another account can cure" % (status,))
    raise SystemExit(0)

# The proof that nothing happened: at most one turn, and nothing spent. Either
# alone is weaker — a first turn can call a tool, and a cost can be unreported —
# so both are required, and a missing value counts as "something happened".
if not isinstance(turns, int) or isinstance(turns, bool) or turns > 1:
    print("should-fall-back: no — %r turn(s) ran; a retry could repost what they posted" % (turns,))
    raise SystemExit(0)
# `False in (0, 0.0)` is True in python, so the bool is excluded here as it is
# for the status and the turn count: it is not a cost, so it is not zero.
if isinstance(cost, bool) or cost not in (0, 0.0):
    print("should-fall-back: no — the first attempt cost %r; something was generated" % (cost,))
    raise SystemExit(0)

with open(out, "w", encoding="utf-8") as handle:
    handle.write("yes")
print("should-fall-back: yes — refused with %d on turn %d at zero cost" % (status, turns))
PY
