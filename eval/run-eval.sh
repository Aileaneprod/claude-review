#!/usr/bin/env bash
#
# run-eval.sh — prompt regression harness.
#
# Usage:
#   run-eval.sh [--live] [--fixture NAME] [--verbose]
#
#   --live          Call the real model instead of replaying stubs. Spends
#                   Claude subscription quota. Off by default.
#   --fixture NAME  Run a single fixture (directory name under eval/fixtures).
#   --verbose       Print every finding and how it was classified.
#
# Each fixture carries a planted defect AND at least one decoy — something that
# looks wrong but is correctly handled elsewhere in the same file. `must_find`
# measures recall; `must_not_find` measures precision. The decoys are the point:
# without them the harness would happily reward a reviewer that flags
# everything. Fixture 11 has no defect at all, so any finding on it is wrong.
#
# Exit status is non-zero if any expected finding was missed or any decoy was
# hit, so this is usable as a gate.
#
# NOTE on live runs: `claude --bare` would give reproducible context but does
# not read CLAUDE_CODE_OAUTH_TOKEN, so we cannot use it on subscription auth.
# That means a local --live run inherits this machine's CLAUDE.md, MCP servers
# and hooks. Local live scores are advisory; the authoritative baseline is
# .github/workflows/eval.yml on a clean runner. See docs/TUNING.md.

set -euo pipefail

eval_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${eval_dir}/.." && pwd)"

live=0
only_fixture=""
verbose=0

die() {
  printf 'run-eval: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --live)    live=1; shift ;;
    --verbose) verbose=1; shift ;;
    --fixture) [ "$#" -ge 2 ] || die "--fixture requires a value"; only_fixture="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
if [ "$live" -eq 1 ]; then
  command -v claude >/dev/null 2>&1 || die "--live needs the claude CLI on PATH"
fi

out_dir="${eval_dir}/.out"
rm -rf "$out_dir"
mkdir -p "$out_dir"

# Schema for the model's structured output in live mode. Draft-07 only.
cat >"${out_dir}/schema.json" <<'JSON'
{
  "type": "object",
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "line": { "type": "integer" },
          "severity": { "type": "string" },
          "title": { "type": "string" },
          "evidence": { "type": "string" },
          "why_it_matters": { "type": "string" },
          "suggested_fix": { "type": "string" }
        },
        "required": ["path", "severity", "title", "evidence"]
      }
    }
  },
  "required": ["findings"]
}
JSON

"${repo_root}/scripts/resolve-config.sh" >"${out_dir}/config.json"

# ---------------------------------------------------------------------------
# Produce one response JSON per fixture.
# ---------------------------------------------------------------------------
fixtures=()
while IFS= read -r expected_path; do
  name="$(basename "$expected_path" .json)"
  if [ -n "$only_fixture" ] && [ "$name" != "$only_fixture" ]; then
    continue
  fi
  fixtures+=("$name")
done <<EOF
$(find "${eval_dir}/expected" -maxdepth 1 -type f -name '*.json' | sort)
EOF

[ "${#fixtures[@]}" -gt 0 ] || die "no fixtures matched"

for name in "${fixtures[@]}"; do
  fixture_dir="${eval_dir}/fixtures/${name}"
  [ -d "$fixture_dir" ] || die "fixture directory missing: $fixture_dir"

  if [ "$live" -eq 0 ]; then
    stub="${eval_dir}/stubs/${name}.json"
    [ -f "$stub" ] || die "stub missing for ${name}: $stub (run with --live, or add it)"
    cp "$stub" "${out_dir}/${name}.response.json"
    continue
  fi

  profile="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("profile","generic"))' \
    "${eval_dir}/expected/${name}.json")"

  # Files in scope: everything in the fixture except the diff itself.
  ( cd "$fixture_dir" && find . -type f ! -name 'changes.diff' \
      | sed 's|^\./||' | sort ) >"${out_dir}/${name}.files.txt"

  "${repo_root}/scripts/build-prompt.sh" \
    --config "${out_dir}/config.json" \
    --repo "eval/${name}" \
    --pr 0 \
    --changed-files "${out_dir}/${name}.files.txt" \
    --profiles "$profile" \
    --out "${out_dir}/${name}.prompt.md"

  # The real prompt tells the reviewer to post via GitHub tools that do not
  # exist here, so redirect the output contract without touching the analysis.
  cat >>"${out_dir}/${name}.prompt.md" <<'EOF'

# Evaluation mode

There is no GitHub in this environment and no comment tools are available. Do
NOT attempt to post anything. Return your findings through the structured
output schema instead, one entry per finding you would have posted inline.
Every grounding rule above still applies — especially the second pass, and
especially the rule that a finding already handled elsewhere in the file is
invalid. An empty findings array is a valid answer.
EOF

  printf 'run-eval: [live] %s (profile: %s)\n' "$name" "$profile" >&2
  if ! ( cd "$fixture_dir" && claude -p \
          --output-format json \
          --json-schema "$(cat "${out_dir}/schema.json")" \
          --max-turns 15 \
          --allowedTools "Read,Grep,Glob" \
          <"${out_dir}/${name}.prompt.md" ) >"${out_dir}/${name}.response.json" 2>"${out_dir}/${name}.err"; then
    printf 'run-eval: %s: the claude CLI exited non-zero\n' "$name" >&2
    sed 's/^/run-eval:   /' "${out_dir}/${name}.err" >&2 || true
    printf '{"is_error": true, "subtype": "cli_failure"}\n' >"${out_dir}/${name}.response.json"
  fi
done

# ---------------------------------------------------------------------------
# Score.
# ---------------------------------------------------------------------------
printf '%s\n' "${fixtures[@]}" >"${out_dir}/names.txt"

python3 - "$eval_dir" "$out_dir" "$verbose" <<'PY'
import json
import os
import sys

eval_dir, out_dir, verbose_flag = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

with open(os.path.join(out_dir, "names.txt"), encoding="utf-8") as fh:
    names = [ln.strip() for ln in fh if ln.strip()]


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def haystack(finding, subject_only=False):
    """Text to match an expectation against.

    `subject_only` narrows to what the finding is *about* — its title and the
    line it quotes. Decoy detection uses it, because a good finding often
    mentions the decoy by way of contrast ("unlike fetch_logo, which is
    threadpooled"). Naming the decoy while explaining a real defect is exactly
    the reasoning we want; it must not be scored as a false positive.
    """
    parts = [str(finding.get("title") or ""), str(finding.get("evidence") or "")]
    if not subject_only:
        parts.append(str(finding.get("why_it_matters") or ""))
        parts.append(str(finding.get("suggested_fix") or ""))
    return " ".join(parts).lower()


def path_matches(finding_path, expected_path):
    fp = (finding_path or "").replace("\\", "/").lstrip("./").lower()
    ep = (expected_path or "").replace("\\", "/").lstrip("./").lower()
    return fp == ep or fp.endswith("/" + ep) or ep.endswith("/" + fp)


def entry_matches(finding, entry, subject_only=False):
    if not path_matches(finding.get("path"), entry.get("path")):
        return False
    keys = entry.get("any_of") or []
    if "*" in keys:
        return True
    text = haystack(finding, subject_only=subject_only)
    return any(k.lower() in text for k in keys)


rows = []
tot_tp = tot_fp = tot_fn = tot_extra = 0
tot_matched = tot_expected = 0
infra_failures = []

for name in names:
    expected = load(os.path.join(eval_dir, "expected", name + ".json"), {}) or {}
    response = load(os.path.join(out_dir, name + ".response.json"), {}) or {}

    # Infrastructure problems must not be scored as prompt regressions.
    subtype = response.get("subtype")
    if response.get("is_error") or subtype in (
        "cli_failure",
        "error_max_structured_output_retries",
        "error_during_execution",
    ):
        infra_failures.append((name, subtype or "is_error"))
        rows.append((name, "-", "-", "-", "-", "ERROR", "ERROR"))
        continue

    structured = response.get("structured_output") or {}
    findings = structured.get("findings")
    if findings is None:
        infra_failures.append((name, "no structured_output"))
        rows.append((name, "-", "-", "-", "-", "ERROR", "ERROR"))
        continue

    must_find = expected.get("must_find") or []
    must_not = expected.get("must_not_find") or []

    matched_entries = set()
    tp = fp = extra = 0
    hit_decoys = []

    for finding in findings:
        # Decoys are checked FIRST and win ties. A must_not_find entry is a
        # precise statement that reporting this thing is wrong, so a finding
        # that trips one is a false positive even if it also happens to contain
        # a must_find keyword — otherwise a reviewer could score a true positive
        # for flagging exactly the code we planted to catch it out.
        decoy = [e for e in must_not if entry_matches(finding, e, subject_only=True)]
        if decoy:
            fp += 1
            hit_decoys.append(decoy[0].get("id"))
            if verbose_flag:
                print("  [DECOY] %-28s %s  <- %s"
                      % (name, finding.get("title"), decoy[0].get("id")))
            continue
        hit = [e for e in must_find if entry_matches(finding, e)]
        if hit:
            tp += 1
            for e in hit:
                matched_entries.add(e.get("id"))
            if verbose_flag:
                print("  [TP]    %-28s %s" % (name, finding.get("title")))
            continue
        extra += 1
        if verbose_flag:
            print("  [extra] %-28s %s" % (name, finding.get("title")))

    missed = [e.get("id") for e in must_find if e.get("id") not in matched_entries]
    fn = len(missed)

    # Precision is per finding; recall is per expected entry. Several findings
    # can legitimately cover one entry, so counting findings on both sides would
    # let recall exceed 1.
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    recall = (len(matched_entries) / len(must_find)) if must_find else 1.0

    tot_tp += tp
    tot_fp += fp
    tot_fn += fn
    tot_extra += extra
    tot_matched += len(matched_entries)
    tot_expected += len(must_find)

    rows.append((name, str(tp), str(fn), str(fp), str(extra),
                 "%.2f" % precision, "%.2f" % recall))

    if missed:
        print("  MISSED  %-28s %s" % (name, ", ".join(missed)))
    for decoy_id in hit_decoys:
        print("  DECOY   %-28s %s" % (name, decoy_id))

header = ("fixture", "found", "missed", "decoy", "extra", "prec", "recall")
width = max([len(r[0]) for r in rows] + [len(header[0])])

print()
print("%-*s  %5s  %6s  %5s  %5s  %5s  %6s" % (width, *header))
print("-" * (width + 42))
for row in rows:
    print("%-*s  %5s  %6s  %5s  %5s  %5s  %6s" % (width, *row))
print("-" * (width + 42))

precision = tot_tp / (tot_tp + tot_fp) if (tot_tp + tot_fp) else 1.0
recall = (tot_matched / tot_expected) if tot_expected else 1.0
print("%-*s  %5d  %6d  %5d  %5d  %5.2f  %6.2f"
      % (width, "TOTAL", tot_tp, tot_fn, tot_fp, tot_extra, precision, recall))
print()

if infra_failures:
    print("Infrastructure failures (not scored as regressions):")
    for name, reason in infra_failures:
        print("  %-28s %s" % (name, reason))
    print()

if tot_fn or tot_fp:
    print("REGRESSION: %d expected finding(s) missed, %d decoy(s) hit."
          % (tot_fn, tot_fp))
    sys.exit(1)

if infra_failures:
    print("Prompt scoring clean, but %d fixture(s) failed to run."
          % len(infra_failures))
    sys.exit(2)

print("All fixtures pass: every planted defect found, no decoy triggered.")
PY
