# collect-inputs.sh — and the structural rule it depends on.
#
# Precedence is: config/defaults.yml < workflow inputs < the repo's own
# .claude-review.yml. Anything the workflow emits therefore SHADOWS the central
# file, and GitHub substitutes an omitted input's default — so an input carrying
# a non-empty default means the central file is never read for that key.
#
# For five keys it never was. profile, max_turns, max_findings, max_diff_lines
# and fail_on_blocking all had defaults in review.yml, while docs/TUNING.md told
# people to set config/defaults.yml "for everywhere". The last case below is the
# one that catches that, and it fails against the workflow as it was.

_out() { printf '%s' "$TESTTMP/overrides.json"; }
_collect() { env "$@" "$SCRIPTS/collect-inputs.sh" --out "$(_out)" && cat "$(_out)"; }

it "emits nothing when every input is empty"
# The case that matters: a caller setting no inputs must leave defaults.yml
# untouched, which means an EMPTY object, not a populated one.
assert_equal "{}" "$(_collect IN_PROFILE= IN_MODEL= IN_MAX_TURNS= IN_MAX_FINDINGS= \
                              IN_MAX_DIFF_LINES= IN_EXCLUDE_PATHS= IN_LANGUAGE= \
                              IN_FAIL_ON_BLOCKING=)" "all-empty yields {}"

it "emits nothing when the variables are absent altogether"
assert_equal "{}" "$("$SCRIPTS/collect-inputs.sh" --out "$(_out)" >/dev/null && cat "$(_out)")" \
  "unset yields {}"

it "emits what a caller actually asked for"
assert_contains '"max_turns": 12' "an explicit number is carried" -- \
  _collect IN_MAX_TURNS=12
assert_contains '"profile": "generic"' "an explicit profile is carried" -- \
  _collect IN_PROFILE=generic
assert_contains '"fail_on_blocking": true' "an explicit true is carried" -- \
  _collect IN_FAIL_ON_BLOCKING=true

it "carries an explicit false, which is not the same as absent"
assert_contains '"fail_on_blocking": false' "explicit false is carried" -- \
  _collect IN_FAIL_ON_BLOCKING=false

it "splits the newline-separated globs"
assert_contains '"exclude_paths": ["a/**", "b/**"]' "globs become a list" -- \
  _collect "IN_EXCLUDE_PATHS=a/**
b/**"

it "ignores whitespace-only values"
assert_equal "{}" "$(_collect 'IN_PROFILE=   ' 'IN_MAX_TURNS= ')" "blank strings are not values"

# --- the structural rule -----------------------------------------------------

it "keeps every config-mirroring input defaulting to empty in review.yml"
# An input that mirrors a config key must NOT carry a default. If it does,
# config/defaults.yml is dead for that key and docs/TUNING.md is lying.
# tooling_ref, tooling_repo and use_github_app are exempt: they configure the
# workflow itself, not the review, and have no entry in config/defaults.yml.
#
# review_drafts is exempt for a stronger reason than the other three: it CANNOT
# have an entry there. It gates a job-level `if:`, which GitHub evaluates before
# anything is checked out, so `.claude-review.yml` has not been read and cannot
# be. A default here is therefore not shadowing config — it is the only place
# the value can come from apart from the caller's `with:`.
_defaults_report() {
  python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
# PyYAML reads a bare \`on:\` key as the YAML 1.1 boolean True, so the
# workflow trigger block is doc[True], not doc['on'].
trigger = doc.get('on', doc.get(True))
inputs = trigger['workflow_call']['inputs']
exempt = {'tooling_ref', 'tooling_repo', 'use_github_app', 'review_drafts'}
bad = [n for n, spec in inputs.items()
       if n not in exempt and str(spec.get('default', '')) not in ('', 'None')]
print(' '.join(sorted(bad)) if bad else 'none')
" "$1"
}
assert_equal "none" "$(_defaults_report "$SCRIPTS/../.github/workflows/review.yml")" \
  "no config-mirroring input carries a default"
