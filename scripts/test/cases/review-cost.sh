# review-cost.sh — what each reviewer cost over a window.
#
# The comparison trial ends on cost as well as findings, and neither cost was
# recorded where the comparison page reads. Ours is in each run's execution
# record, theirs in GitHub's billing API. What has to hold:
#
#   * a review is counted once, from its record, and a run that reviewed
#     nothing is not a review;
#   * a record that expired or could not be read is named, never a zero;
#   * Copilot's usage is read only for Copilot, and a refused read prints no
#     total at all, because a partial total would read as the cost.
#
# `gh` is an exported shell function serving synthetic fixtures. Nothing here
# is real data.

_rc_zip() {
  # $1 = output zip, $2 = total_cost_usd, or "none" for a record with no result
  python3 - "$1" "$2" <<'PY'
import json, sys, zipfile
out, cost = sys.argv[1], sys.argv[2]
entries = [{"type": "system"}, {"type": "assistant"}]
if cost != "none":
    entries.append({"type": "result", "subtype": "success", "total_cost_usd": float(cost)})
with zipfile.ZipFile(out, "w") as zf:
    zf.writestr("claude-execution-output.json", json.dumps(entries))
PY
}

_rc_setup() {
  export RC_FIX="$TESTTMP/rc" RC_LOG="$TESTTMP/rc.log" RC_BREAK="${1:-}"
  rm -rf "$RC_FIX"; mkdir -p "$RC_FIX"; : > "$RC_LOG"
  # Run 11 and 12 reviewed; 13 reviewed nothing; 14's record expired.
  printf '11\n12\n13\n14\n' > "$RC_FIX/runs"
  printf '101 false\n' > "$RC_FIX/art-11"
  printf '102 false\n' > "$RC_FIX/art-12"
  : > "$RC_FIX/art-13"
  printf '104 true\n' > "$RC_FIX/art-14"
  _rc_zip "$RC_FIX/101.zip" 0.75
  _rc_zip "$RC_FIX/102.zip" 0.25
  python3 - "$RC_FIX/usage.json" <<'PY'
import json, sys
# The real shape on a seat plan: credits used, valued at list price, then
# discounted by the credits the seats include, so the net is often 0.
json.dump({"usageItems": [
    {"product": "Copilot", "model": "GPT-X", "grossQuantity": 30, "grossAmount": 0.30,
     "discountQuantity": 30, "discountAmount": 0.30, "netQuantity": 0, "netAmount": 0},
    {"product": "Copilot", "model": "GPT-Y", "grossQuantity": 10, "grossAmount": 0.10,
     "discountQuantity": 5, "discountAmount": 0.05, "netQuantity": 5, "netAmount": 0.05},
    {"product": "Actions", "model": "", "grossQuantity": 999, "grossAmount": 9.99,
     "discountQuantity": 0, "discountAmount": 0, "netQuantity": 999, "netAmount": 9.99}]},
    open(sys.argv[1], "w", encoding="utf-8"))
PY

  gh() {
    echo "$*" >> "$RC_LOG"
    local id
    case "$*" in
      *actions/workflows/*/runs*)
        [ "${RC_BREAK:-}" = "runs" ] && return 1
        cat "$RC_FIX/runs" ;;
      *actions/runs/*/artifacts*)
        id="$(printf '%s' "$*" | sed -n 's|.*actions/runs/\([0-9]*\)/artifacts.*|\1|p')"
        cat "$RC_FIX/art-$id" ;;
      *actions/artifacts/*/zip*)
        id="$(printf '%s' "$*" | sed -n 's|.*actions/artifacts/\([0-9]*\)/zip.*|\1|p')"
        cat "$RC_FIX/$id.zip" ;;
      *ai_credit/usage*)
        [ "${RC_BREAK:-}" = "billing" ] && return 1
        cat "$RC_FIX/usage.json" ;;
      *)
        echo '{}' ;;
    esac
  }
  export -f gh
}

_rc() { "$SCRIPTS/review-cost.sh" --repo o/r --since 2026-11-01 --until 2026-11-02 "$@" 2>&1; }

# --- arguments ----------------------------------------------------------------

it "refuses a window it cannot read"
_rc_setup
assert_status 2 "a date that does not exist is refused" -- \
  "$SCRIPTS/review-cost.sh" --repo o/r --since 2026-02-31
assert_status 2 "an end before the start is refused" -- \
  "$SCRIPTS/review-cost.sh" --repo o/r --since 2026-11-02 --until 2026-11-01
assert_status 2 "a bare repository name is refused" -- \
  "$SCRIPTS/review-cost.sh" --repo korbyx --since 2026-11-01

# --- ours -----------------------------------------------------------------------

it "sums each review once, from its own record"
_rc_setup
assert_contains "| reviews with a readable execution record | 2 |" "two runs carried a record" -- _rc --no-copilot
assert_contains "| API-equivalent cost, total | \$1.00 |" "0.75 + 0.25" -- _rc --no-copilot
assert_contains "| API-equivalent cost, per review | \$0.50 |" "over the two reviews only" -- _rc --no-copilot
assert_contains "created=2026-11-01..2026-11-02" "the run list is asked for the window" -- cat "$RC_LOG"

it "does not count a run that reviewed nothing as a review"
_rc_setup
assert_contains "| runs with no execution record (nothing reviewed) | 1 |" "run 13 is counted apart" -- _rc --no-copilot

it "names an expired record instead of reading it as zero"
_rc_setup
assert_contains "| records expired before this read | 1 |" "run 14 is counted" -- _rc --no-copilot
assert_contains "the total above is short by their cost.** Runs: 14." "and named, with what it means" -- _rc --no-copilot
assert_not_contains "artifacts/104/zip" "and its archive is never downloaded" -- cat "$RC_LOG"

it "says a record without a result is unreadable"
_rc_setup
_rc_zip "$RC_FIX/102.zip" none
assert_contains "| records present but unreadable | 1 |" "a record with no result entry" -- _rc --no-copilot
assert_contains "| API-equivalent cost, total | \$0.75 |" "and it adds nothing to the total" -- _rc --no-copilot

it "exits 1 and names the read when the run list fails"
_rc_setup runs
assert_status 1 "a failed read is not a complete answer" -- _rc --no-copilot
assert_contains "runs of ai-review.yml in o/r" "and the page says which read" -- _rc --no-copilot

# --- theirs ---------------------------------------------------------------------

it "counts only Copilot's usage, per model, over every day of the window"
_rc_setup
assert_contains "| GPT-X | 60 | \$0.60 | \$0.00 |" "two days of 30 credits, all covered by the seats" -- _rc
assert_contains "| **total** | **80** | **\$0.80** | **\$0.10** |" "Actions usage is left out" -- _rc

it "shows what the reviewer used, not only the zero the seats leave to pay"
_rc_setup
assert_not_contains "| GPT-X | 0 |" "a fully discounted model is not reported as unused" -- _rc
assert_contains "day=1" "the first day is read" -- cat "$RC_LOG"
assert_contains "day=2" "and the last" -- cat "$RC_LOG"
assert_contains "a ceiling on what the reviewer cost" "and the page says what the figure is" -- _rc

it "prints no Copilot total when its usage cannot be read"
_rc_setup billing
assert_status 1 "a refused read is a failure" -- _rc
assert_contains "**Unreadable.**" "says it" -- _rc
assert_not_contains "| **total** |" "and prints no total" -- _rc

it "does not read billing with --no-copilot"
_rc_setup
_rc --no-copilot >/dev/null
assert_not_contains "ai_credit" "no billing call is made" -- cat "$RC_LOG"
