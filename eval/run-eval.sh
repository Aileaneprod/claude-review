#!/usr/bin/env bash
#
# run-eval.sh — prompt regression harness.
#
# Usage:
#   run-eval.sh [--live] [--fixture NAME] [--verbose] [--repeat N]
#               [--learnings FILE|none] [--drop-lesson K]
#               [--min-hit-rate R] [--max-decoy-rate R] [--out-dir DIR]
#
#   --live            Call the real model instead of replaying stubs. Spends
#                     Claude subscription quota. Off by default.
#   --fixture NAME    Run a single fixture (directory name under eval/fixtures).
#   --verbose         Print every finding and how it was classified.
#   --repeat N        Review each fixture N times. One live run is one sample:
#                     fixture 04 at `high` found its defect once in two runs on
#                     the same code. With N > 1 every planted defect and every
#                     decoy is reported as a rate, k of N. Default 1.
#   --learnings FILE  The lessons to inject instead of prompts/learnings.md.
#                     `none` injects no lesson at all.
#   --drop-lesson K   Inject prompts/learnings.md minus its K-th lesson (the
#                     K-th `## ` heading). With --repeat, the way to ask what
#                     one lesson is worth, and whether it hides a real defect.
#   --min-hit-rate R  With --repeat, the share of runs that must find each
#                     planted defect. Default 1: every run.
#   --max-decoy-rate R  With --repeat, the share of runs allowed to hit a
#                     decoy. Default 0: none.
#   --out-dir DIR     Where responses and summary.json go. Default eval/.out,
#                     which every run empties first.
#
# Each fixture carries a planted defect AND at least one decoy — something that
# looks wrong but is correctly handled elsewhere in the same file. `must_find`
# measures recall; `must_not_find` measures precision. The decoys are the point:
# without them the harness would happily reward a reviewer that flags
# everything. Fixture 11 has no defect at all, so any finding on it is wrong.
#
# Exit status is non-zero if any expected finding was missed or any decoy was
# hit (with --repeat: if a rate crosses its threshold), so this is usable as a
# gate. `.out/summary.json` records every rate, the model, the effort and which
# lessons were injected, so two runs can be compared.
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
repeat=1
learnings=""
drop_lesson=""
min_hit_rate="1"
max_decoy_rate="0"
out_dir="${eval_dir}/.out"

die() {
  printf 'run-eval: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --live)           live=1; shift ;;
    --verbose)        verbose=1; shift ;;
    --fixture)        [ "$#" -ge 2 ] || die "--fixture requires a value";        only_fixture="$2";   shift 2 ;;
    --repeat)         [ "$#" -ge 2 ] || die "--repeat requires a value";         repeat="$2";         shift 2 ;;
    --learnings)      [ "$#" -ge 2 ] || die "--learnings requires a value";      learnings="$2";      shift 2 ;;
    --drop-lesson)    [ "$#" -ge 2 ] || die "--drop-lesson requires a value";    drop_lesson="$2";    shift 2 ;;
    --min-hit-rate)   [ "$#" -ge 2 ] || die "--min-hit-rate requires a value";   min_hit_rate="$2";   shift 2 ;;
    --max-decoy-rate) [ "$#" -ge 2 ] || die "--max-decoy-rate requires a value"; max_decoy_rate="$2"; shift 2 ;;
    --out-dir)        [ "$#" -ge 2 ] || die "--out-dir requires a value";        out_dir="$2";      shift 2 ;;
    -h|--help)        sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

# A value that is not a positive integer, or a rate outside [0, 1], would be
# read by python below and fail far from the flag that caused it.
case "$repeat" in ''|*[!0-9]*|0) die "--repeat must be a positive integer, got '${repeat}'" ;; esac
for rate in "$min_hit_rate" "$max_decoy_rate"; do
  python3 -c 'import sys; v = float(sys.argv[1]); sys.exit(0 if 0 <= v <= 1 else 1)' "$rate" 2>/dev/null \
    || die "a rate must be a number between 0 and 1, got '${rate}'"
done
if [ -n "$learnings" ] && [ -n "$drop_lesson" ]; then
  die "--learnings and --drop-lesson are exclusive: --drop-lesson edits prompts/learnings.md"
fi

if [ "$live" -eq 1 ]; then
  command -v claude >/dev/null 2>&1 || die "--live needs the claude CLI on PATH"
fi

# The directory is emptied first, so it must be one this script made. An
# --out-dir mistyped onto a real directory would otherwise be deleted whole.
if [ "$out_dir" != "${eval_dir}/.out" ] && [ -d "$out_dir" ] && [ ! -f "${out_dir}/.run-eval" ] \
   && [ -n "$(ls -A "$out_dir" 2>/dev/null)" ]; then
  die "refusing to empty ${out_dir}: it is not empty and run-eval did not create it"
fi
rm -rf "$out_dir"
mkdir -p "$out_dir"
: >"${out_dir}/.run-eval"

# The lessons the prompt carries. Default: the ones reviews carry.
learnings_file="${repo_root}/prompts/learnings.md"
learnings_label="prompts/learnings.md"
if [ "$learnings" = "none" ]; then
  learnings_file="${out_dir}/learnings.none.md"
  : >"$learnings_file"
  learnings_label="none"
elif [ -n "$learnings" ]; then
  [ -f "$learnings" ] || die "--learnings: no such file: $learnings"
  learnings_file="$learnings"
  learnings_label="$learnings"
elif [ -n "$drop_lesson" ]; then
  case "$drop_lesson" in ''|*[!0-9]*|0) die "--drop-lesson must be a positive integer, got '${drop_lesson}'" ;; esac
  learnings_file="${out_dir}/learnings.minus-${drop_lesson}.md"
  learnings_label="$(python3 - "${repo_root}/prompts/learnings.md" "$drop_lesson" "$learnings_file" <<'PY'
import io
import re
import sys

source, index, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
text = io.open(source, encoding="utf-8").read()
# Split on lesson headings, keeping each heading with its body. Part 0 is the
# preamble, which build-prompt.sh drops anyway.
parts = re.split(r"(?m)^(?=## )", text)
lessons = parts[1:]
if index > len(lessons):
    sys.stderr.write("run-eval: --drop-lesson %d: prompts/learnings.md has %d lesson(s)\n"
                     % (index, len(lessons)))
    raise SystemExit(1)
dropped = lessons[index - 1].splitlines()[0][3:].strip()
kept = parts[:1] + lessons[:index - 1] + lessons[index:]
io.open(out, "w", encoding="utf-8", newline="\n").write("".join(kept))
print("prompts/learnings.md without lesson %d: %s" % (index, dropped))
PY
)" || die "--drop-lesson ${drop_lesson} could not be applied"
fi

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

# The model and effort a review actually runs on, from the same resolved
# config review.yml reads. Without them a live run scored the CLI's own default
# model, so the eval could pass while measuring a reviewer nobody ships — and
# the one change it most needs to gate, a new model, was invisible to it.
model_args=()
cfg_model="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("model",""))' "${out_dir}/config.json")"
cfg_effort="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("effort",""))' "${out_dir}/config.json")"
[ -n "$cfg_model" ] && model_args+=(--model "$cfg_model")
[ -n "$cfg_effort" ] && model_args+=(--effort "$cfg_effort")
if [ "$live" -eq 1 ]; then
  printf 'run-eval: [live] model=%s effort=%s repeat=%s learnings=%s\n' \
    "${cfg_model:-(CLI default)}" "${cfg_effort:-(model default)}" "$repeat" "$learnings_label" >&2
fi

# ---------------------------------------------------------------------------
# Produce one response JSON per fixture and run. Run 1 keeps the name it has
# always had, `<name>.response.json`; run i > 1 is `<name>.r<i>.response.json`.
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

response_path() {
  if [ "$2" -eq 1 ]; then
    printf '%s/%s.response.json' "$out_dir" "$1"
  else
    printf '%s/%s.r%s.response.json' "$out_dir" "$1" "$2"
  fi
}

for name in "${fixtures[@]}"; do
  fixture_dir="${eval_dir}/fixtures/${name}"
  [ -d "$fixture_dir" ] || die "fixture directory missing: $fixture_dir"

  if [ "$live" -eq 0 ]; then
    stub="${eval_dir}/stubs/${name}.json"
    [ -f "$stub" ] || die "stub missing for ${name}: $stub (run with --live, or add it)"
    for run in $(seq 1 "$repeat"); do
      cp "$stub" "$(response_path "$name" "$run")"
    done
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
    --learnings "$learnings_file" \
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

  for run in $(seq 1 "$repeat"); do
    response="$(response_path "$name" "$run")"
    printf 'run-eval: [live] %s run %s/%s (profile: %s)\n' "$name" "$run" "$repeat" "$profile" >&2
    if ! ( cd "$fixture_dir" && claude -p \
            --output-format json \
            --json-schema "$(cat "${out_dir}/schema.json")" \
            --max-turns 15 \
            ${model_args[@]+"${model_args[@]}"} \
            --allowedTools "Read,Grep,Glob" \
            <"${out_dir}/${name}.prompt.md" ) >"$response" 2>"${out_dir}/${name}.r${run}.err"; then
      printf 'run-eval: %s run %s: the claude CLI exited non-zero\n' "$name" "$run" >&2
      sed 's/^/run-eval:   /' "${out_dir}/${name}.r${run}.err" >&2 || true
      printf '{"is_error": true, "subtype": "cli_failure"}\n' >"$response"
    fi
  done
done

# ---------------------------------------------------------------------------
# Score.
# ---------------------------------------------------------------------------
printf '%s\n' "${fixtures[@]}" >"${out_dir}/names.txt"

python3 - "$eval_dir" "$out_dir" "$verbose" "$repeat" "$min_hit_rate" "$max_decoy_rate" \
  "${cfg_model:-}" "${cfg_effort:-}" "$learnings_label" "$live" <<'PY'
import json
import os
import sys

(eval_dir, out_dir, verbose_flag, repeat, min_hit_rate, max_decoy_rate,
 cfg_model, cfg_effort, learnings_label, live) = sys.argv[1:11]
verbose_flag = verbose_flag == "1"
repeat = int(repeat)
min_hit_rate = float(min_hit_rate)
max_decoy_rate = float(max_decoy_rate)

with open(os.path.join(out_dir, "names.txt"), encoding="utf-8") as fh:
    names = [ln.strip() for ln in fh if ln.strip()]


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def response_path(name, run):
    if run == 1:
        return os.path.join(out_dir, name + ".response.json")
    return os.path.join(out_dir, "%s.r%d.response.json" % (name, run))


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


def score_run(name, expected, response):
    """One review of one fixture. `infra` is set when there is nothing to score."""
    subtype = response.get("subtype")
    # Infrastructure problems must not be scored as prompt regressions.
    if response.get("is_error") or subtype in (
        "cli_failure",
        "error_max_structured_output_retries",
        "error_during_execution",
    ):
        return {"infra": subtype or "is_error"}
    structured = response.get("structured_output") or {}
    findings = structured.get("findings")
    if findings is None:
        return {"infra": "no structured_output"}

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
    return {"infra": None, "tp": tp, "fp": fp, "extra": extra,
            "matched": matched_entries, "missed": missed, "decoys": hit_decoys,
            "must_find": len(must_find)}


summary = {"model": cfg_model, "effort": cfg_effort, "learnings": learnings_label,
           "repeat": repeat, "live": live == "1", "min_hit_rate": min_hit_rate,
           "max_decoy_rate": max_decoy_rate, "fixtures": {}}
infra_failures = []

if repeat == 1:
    # One sample per fixture: the table and the gate this harness has always had.
    rows = []
    tot_tp = tot_fp = tot_fn = tot_extra = 0
    tot_matched = tot_expected = 0
    for name in names:
        expected = load(os.path.join(eval_dir, "expected", name + ".json"), {}) or {}
        result = score_run(name, expected, load(response_path(name, 1), {}) or {})
        if result["infra"]:
            infra_failures.append((name, result["infra"]))
            rows.append((name, "-", "-", "-", "-", "ERROR", "ERROR"))
            summary["fixtures"][name] = {"runs_scored": 0, "infra": [result["infra"]]}
            continue
        # Precision is per finding; recall is per expected entry. Several
        # findings can legitimately cover one entry, so counting findings on both
        # sides would let recall exceed 1.
        tp, fp, extra = result["tp"], result["fp"], result["extra"]
        fn = len(result["missed"])
        precision = tp / (tp + fp) if (tp + fp) else 1.0
        recall = (len(result["matched"]) / result["must_find"]) if result["must_find"] else 1.0
        tot_tp += tp
        tot_fp += fp
        tot_fn += fn
        tot_extra += extra
        tot_matched += len(result["matched"])
        tot_expected += result["must_find"]
        rows.append((name, str(tp), str(fn), str(fp), str(extra),
                     "%.2f" % precision, "%.2f" % recall))
        must_ids = [e.get("id") for e in (expected.get("must_find") or [])]
        summary["fixtures"][name] = {
            "runs_scored": 1,
            "must_find": {i: (1.0 if i in result["matched"] else 0.0) for i in must_ids},
            "decoys": {d: 1.0 for d in result["decoys"]},
            "extra_mean": float(extra),
        }
        if result["missed"]:
            print("  MISSED  %-28s %s" % (name, ", ".join(result["missed"])))
        for decoy_id in result["decoys"]:
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
    failed = bool(tot_fn or tot_fp)
    failure_line = ("REGRESSION: %d expected finding(s) missed, %d decoy(s) hit."
                    % (tot_fn, tot_fp))
else:
    # N samples per fixture. Every planted defect and every decoy becomes a
    # rate over the runs that could be scored; a run that failed to execute is
    # left out of the denominator rather than counted as a miss.
    rows = []
    below = []
    above = []
    for name in names:
        expected = load(os.path.join(eval_dir, "expected", name + ".json"), {}) or {}
        must_ids = [e.get("id") for e in (expected.get("must_find") or [])]
        decoy_ids = [e.get("id") for e in (expected.get("must_not_find") or [])]
        results = [score_run(name, expected, load(response_path(name, run), {}) or {})
                   for run in range(1, repeat + 1)]
        failed_runs = [r["infra"] for r in results if r["infra"]]
        scored = [r for r in results if not r["infra"]]
        for reason in failed_runs:
            infra_failures.append((name, reason))
        n = len(scored)
        entry = {"runs_scored": n, "infra": failed_runs}
        if n == 0:
            rows.append((name, "0/%d" % repeat, "-", "-", "-"))
            summary["fixtures"][name] = entry
            continue
        find_rates = {i: sum(1 for r in scored if i in r["matched"]) / n for i in must_ids}
        decoy_rates = {d: sum(r["decoys"].count(d) > 0 for r in scored) / n for d in decoy_ids}
        extra_mean = sum(r["extra"] for r in scored) / n
        entry.update({"must_find": find_rates, "decoys": decoy_rates, "extra_mean": extra_mean})
        summary["fixtures"][name] = entry
        for i, rate in find_rates.items():
            if rate < min_hit_rate:
                below.append((name, i, rate, n))
        for d, rate in decoy_rates.items():
            if rate > max_decoy_rate:
                above.append((name, d, rate, n))
        found_cell = " ".join("%d/%d" % (round(r * n), n) for r in find_rates.values()) or "-"
        decoy_cell = " ".join("%d/%d" % (round(r * n), n) for r in decoy_rates.values()) or "-"
        rows.append((name, "%d/%d" % (n, repeat), found_cell, decoy_cell, "%.1f" % extra_mean))

    header = ("fixture", "runs", "found", "decoy", "extra")
    width = max([len(r[0]) for r in rows] + [len(header[0])])
    print()
    print("%-*s  %5s  %-12s  %-12s  %5s" % (width, *header))
    print("-" * (width + 44))
    for row in rows:
        print("%-*s  %5s  %-12s  %-12s  %5s" % (width, *row))
    print("-" * (width + 44))
    print("found: runs that found each planted defect; decoy: runs that hit each decoy.")
    print()
    for name, i, rate, n in below:
        print("  UNSTABLE %-28s %s found in %d/%d runs (threshold %.2f)"
              % (name, i, round(rate * n), n, min_hit_rate))
    for name, d, rate, n in above:
        print("  DECOY    %-28s %s hit in %d/%d runs (threshold %.2f)"
              % (name, d, round(rate * n), n, max_decoy_rate))
    if below or above:
        print()
    failed = bool(below or above)
    failure_line = ("REGRESSION: %d planted defect(s) below the hit-rate threshold, "
                    "%d decoy(s) above the decoy-rate threshold." % (len(below), len(above)))

with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)

if infra_failures:
    print("Infrastructure failures (not scored as regressions):")
    for name, reason in infra_failures:
        print("  %-28s %s" % (name, reason))
    print()

if failed:
    print(failure_line)
    sys.exit(1)

if infra_failures:
    print("Prompt scoring clean, but %d fixture run(s) failed to run."
          % len(infra_failures))
    sys.exit(2)

print("All fixtures pass: every planted defect found, no decoy triggered.")
PY
