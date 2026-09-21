# An artifact whose path is a hidden directory, uploaded without
# `include-hidden-files`, is an empty artifact and a one-line notice nobody
# reads: "No files were found with the provided path: eval/.out/".
#
# It cost 44 days. The prompt eval gate failed on 2026-08-05 — recall 12/12, one
# decoy hit on `10-generic-migration` — and nobody could say which finding was
# wrong, because the responses that would have named it were dropped by the step
# whose job was to keep them. It was still failing, identically, on 2026-09-18.
#
# The rule is mechanical and belongs here rather than in a reviewer's memory:
# any `actions/upload-artifact` whose `path` has a dot-segment must set
# `include-hidden-files: true`. Nothing else in this repository can notice —
# `if-no-files-found: ignore` is correct for these steps and is exactly what
# keeps the failure quiet.
#
# Parsed with stock python3, the pattern repo-hygiene.sh uses, because PyYAML is
# not a dependency of this repository.

it "keeps an artifact whose path is hidden"

# Takes the tree to scan, defaulting to this repository. Parameterised so the
# same scanner can be pointed at a synthetic workflow: a case that only ever
# runs over files that already comply cannot tell "found nothing wrong" from
# "cannot see anything".
_hidden_uploads_without_the_flag() {
  python3 - "${1:-$(cd -- "$SCRIPTS/.." && pwd)}" <<'PY'
import io
import os
import re
import sys

root = sys.argv[1]
offenders = []

for name in sorted(os.listdir(os.path.join(root, ".github", "workflows"))):
    if not name.endswith((".yml", ".yaml")):
        continue
    path = os.path.join(root, ".github", "workflows", name)
    text = io.open(path, encoding="utf-8").read()

    # Each `uses: actions/upload-artifact` and the `with:` block under it, up to
    # the next step (a line at the same indent starting with `- `) or the end.
    #
    # Four YAML spellings are valid and the first version of this pattern saw
    # ONE of them. `uses: "actions/..."` is quoted, `- uses: actions/...` puts
    # the step's dash on the same line, and the two combine. A guard that reads
    # three of four shapes as "no artifact step here" reports a clean repository
    # for the same reason the step it was written to catch reported a clean
    # upload: it did not look. The other reviewer caught the quoted form on the
    # pull request that added this file; the dash forms turned up on checking it.
    for match in re.finditer(r"""^(\s*)-?\s*uses:\s*['"]?actions/upload-artifact@""",
                             text, re.M):
        start = match.end()
        rest = text[start:]
        stop = re.search(r"^\s*- (?:name|uses):", rest, re.M)
        block = rest[:stop.start()] if stop else rest

        found = re.search(r"^\s*path:\s*(\S.*?)\s*$", block, re.M)
        if not found:
            continue
        artifact_path = found.group(1).strip("'\"")
        # A hidden segment: any component beginning with a dot that is not the
        # `.` or `..` of a relative path. `${{ … }}` is opaque here and is left
        # alone — the expression, not the literal, decides what it points at.
        segments = [s for s in artifact_path.split("/") if s not in ("", ".", "..")]
        if not any(s.startswith(".") for s in segments):
            continue
        if not re.search(r"^\s*include-hidden-files:\s*true\s*$", block, re.M):
            offenders.append("%s: %s" % (name, artifact_path))

print(" ".join(offenders))
PY
}

assert_equal "" "$(_hidden_uploads_without_the_flag)" \
  "no upload of a dot-path forgets include-hidden-files"

# The guard has to be able to see a violation, not merely pass over the one file
# that happens to be correct today. Feed it the shape it exists to catch.

it "sees a hidden path that forgot the flag"

_probe() {
  python3 - "$1" <<'PY'
import io
import re
import sys

block = io.open(sys.argv[1], encoding="utf-8").read()
found = re.search(r"^\s*path:\s*(\S.*?)\s*$", block, re.M)
artifact_path = found.group(1).strip("'\"")
segments = [s for s in artifact_path.split("/") if s not in ("", ".", "..")]
hidden = any(s.startswith(".") for s in segments)
flagged = bool(re.search(r"^\s*include-hidden-files:\s*true\s*$", block, re.M))
print("hidden=%s flagged=%s offender=%s" % (hidden, flagged, hidden and not flagged))
PY
}

printf '          path: eval/.out/\n          if-no-files-found: ignore\n' \
  > "$TESTTMP/upload-bad.yml"
assert_equal "hidden=True flagged=False offender=True" "$(_probe "$TESTTMP/upload-bad.yml")" \
  "a dot-path with no flag is an offender"

printf '          path: eval/.out/\n          include-hidden-files: true\n' \
  > "$TESTTMP/upload-good.yml"
assert_equal "hidden=True flagged=True offender=False" "$(_probe "$TESTTMP/upload-good.yml")" \
  "and the same path with the flag is not"

printf '          path: ${{ steps.claude.outputs.execution_file }}\n' \
  > "$TESTTMP/upload-expr.yml"
assert_equal "hidden=False flagged=False offender=False" "$(_probe "$TESTTMP/upload-expr.yml")" \
  "an expression is not read as a hidden path"

# --- the scanner has to see every spelling of `uses:` ------------------------
#
# YAML accepts four, and the first version of this pattern read one. A guard
# blind to `uses: "actions/..."` or to `- uses: actions/...` answers "no
# artifact step here" and reports a clean repository — the same way the step it
# exists to catch reported a clean upload. It did not look.
#
# Runs the REAL scanner over a synthetic tree, not a copy of its regex: a copy
# would keep passing while the workflow's own pattern stayed blind.

it "sees an upload step however its uses: line is spelled"

_forms_tree() {
  local root="$TESTTMP/uses-forms"
  rm -rf "$root"; mkdir -p "$root/.github/workflows"
  {
    printf 'jobs:\n  j:\n    steps:\n'
    printf '      - name: plain\n        uses: actions/upload-artifact@v4\n'
    printf '        with:\n          path: a/.out/\n'
    printf '      - name: quoted\n        uses: "actions/upload-artifact@v4"\n'
    printf '        with:\n          path: b/.out/\n'
    printf "      - uses: actions/upload-artifact@v4\n"
    printf '        with:\n          path: c/.out/\n'
    printf "      - uses: 'actions/upload-artifact@v4'\n"
    printf '        with:\n          path: d/.out/\n'
  } > "$root/.github/workflows/four.yml"
  printf '%s' "$root"
}

_seen() { _hidden_uploads_without_the_flag "$(_forms_tree)" | tr ' ' '\n' | grep -c 'four.yml' || true; }
assert_equal "4" "$(_seen)" "all four spellings are inspected, not just the bare one"
