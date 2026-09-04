#!/usr/bin/env bash
#
# run-tests.sh — exercise the scripts in scripts/ against fixtures.
#
# Usage:
#   scripts/test/run-tests.sh [--case NAME] [--verbose]
#
#   --case NAME   Run one case file (e.g. resolve-config). Default: all.
#   --verbose     Print every assertion, not just failures.
#
# WHY THIS EXISTS. Until it did, scripts/ had eight scripts and no tests, and
# eval/ covered prompts only. Three defects reached commits in a single session
# because the verification was ad hoc and the person writing it chose the
# inputs: a `language` guard that refused a 65-character payload and admitted a
# 30-character one, a denial reporter whose fixture used a block shape the API
# never emits, and a counter that counted attempts as successes. Every one of
# those is a test that could not fail.
#
# So the rule for this directory: a case is only worth adding if it FAILS
# against the code that had the bug. Write it, watch it go red, then fix.
#
# No framework, by the same rule as the rest of the pipeline: bash and stock
# python3, nothing to install. See docs/ARCHITECTURE.md.

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
export SCRIPTS="${repo_root}/scripts"
export FIXTURES="${script_dir}/fixtures"

only_case=""
verbose=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --case)    [ "$#" -ge 2 ] || { echo "--case requires a value" >&2; exit 2; }; only_case="$2"; shift 2 ;;
    --verbose) verbose=1; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
CURRENT=""

# --- assertions --------------------------------------------------------------
# Each records a result and never exits, so one failure does not hide the rest.

_ok()   { PASS=$((PASS + 1)); [ "$verbose" -eq 1 ] && printf '    ok   %s\n' "$1"; return 0; }
_bad()  { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; return 0; }

it() { CURRENT="$1"; }

# assert_status EXPECTED DESCRIPTION -- command...
assert_status() {
  local expected="$1" desc="$2"; shift 3
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ "$status" -eq "$expected" ]; then
    _ok "$desc"
  else
    _bad "$desc" "expected exit $expected, got $status: $(printf '%s' "$out" | head -1)"
  fi
}

# assert_contains NEEDLE DESCRIPTION -- command...
assert_contains() {
  local needle="$1" desc="$2"; shift 3
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    _ok "$desc"
  else
    _bad "$desc" "expected to contain '$needle', got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  fi
}

# assert_not_contains NEEDLE DESCRIPTION -- command...
assert_not_contains() {
  local needle="$1" desc="$2"; shift 3
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    _bad "$desc" "expected NOT to contain '$needle', got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  else
    _ok "$desc"
  fi
}

# assert_equal EXPECTED ACTUAL DESCRIPTION
assert_equal() {
  if [ "$1" = "$2" ]; then
    _ok "$3"
  else
    _bad "$3" "expected '$1', got '$2'"
  fi
}

export -f _ok _bad it assert_status assert_contains assert_not_contains assert_equal

# --- run ---------------------------------------------------------------------

cases=()
if [ -n "$only_case" ]; then
  cases=("${script_dir}/cases/${only_case}.sh")
  [ -f "${cases[0]}" ] || { echo "no such case: $only_case" >&2; exit 2; }
else
  while IFS= read -r f; do cases+=("$f"); done < <(find "${script_dir}/cases" -name '*.sh' | sort)
fi

for case_file in "${cases[@]}"; do
  printf '  %s\n' "$(basename "$case_file" .sh)"
  # shellcheck source=/dev/null
  . "$case_file"
done

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
