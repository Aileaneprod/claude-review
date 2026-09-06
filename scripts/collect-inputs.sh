#!/usr/bin/env bash
#
# collect-inputs.sh — turn the workflow's inputs into an overrides file.
#
# Usage:
#   collect-inputs.sh --out FILE
#
# Reads IN_PROFILE, IN_MODEL, IN_MAX_TURNS, IN_MAX_FINDINGS, IN_MAX_DIFF_LINES,
# IN_EXCLUDE_PATHS, IN_LANGUAGE and IN_FAIL_ON_BLOCKING from the environment and
# writes the JSON that resolve-config.sh layers over config/defaults.yml.
#
# ONLY NON-EMPTY VALUES ARE EMITTED, and that is the whole design. Precedence is
#
#     config/defaults.yml  <  workflow inputs  <  the repo's .claude-review.yml
#
# so anything this file emits SHADOWS the central defaults. GitHub substitutes an
# input's default whenever a caller omits it, so an input carrying a non-empty
# default is indistinguishable from a caller who asked for that value — and the
# central file is then never read at all.
#
# That is not hypothetical. review.yml gave profile, max_turns, max_findings,
# max_diff_lines and fail_on_blocking non-empty defaults, so for those five keys
# config/defaults.yml had never once been consulted, while docs/TUNING.md told
# people to edit it "for everywhere". Two sources of truth kept in step by a
# comment, and the comment was the only thing holding them together.
#
# The rule that follows: an input that mirrors a config key defaults to EMPTY.
# The value lives in config/defaults.yml, once. scripts/test/cases/collect-inputs.sh
# asserts that review.yml keeps to it.
#
# Requires: python3.

set -euo pipefail

out_file=""

die() { printf 'collect-inputs: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || die "--out requires a value"; out_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$out_file" ] || die "--out is required"

python3 <<'PY' > "$out_file"
import json
import os

out = {}

for env_name, key in (("IN_PROFILE", "profile"),
                      ("IN_MODEL", "model"),
                      ("IN_LANGUAGE", "language")):
    value = (os.environ.get(env_name) or "").strip()
    if value:
        out[key] = value

for env_name, key in (("IN_MAX_TURNS", "max_turns"),
                      ("IN_MAX_FINDINGS", "max_findings"),
                      ("IN_MAX_DIFF_LINES", "max_diff_lines")):
    value = (os.environ.get(env_name) or "").strip()
    if value:
        try:
            out[key] = int(float(value))
        except ValueError:
            # A caller who writes nonsense should hear about it from
            # resolve-config's type check, not have it silently dropped.
            out[key] = value

flag = (os.environ.get("IN_FAIL_ON_BLOCKING") or "").strip().lower()
if flag in ("true", "false"):
    out["fail_on_blocking"] = flag == "true"

globs = [line.strip()
         for line in (os.environ.get("IN_EXCLUDE_PATHS") or "").splitlines()
         if line.strip()]
if globs:
    out["exclude_paths"] = globs

print(json.dumps(out, sort_keys=True))
PY
