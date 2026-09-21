# `case "$n" in *[!0-9]*) die ...` reads like a check that a value is a number.
# It is not. The EMPTY string contains no non-digit character, so it passes, and
# then reaches whatever the script does next with it:
#
#   * `int("")` in a python heredoc — a traceback where the caller expected one
#     diagnostic line (lesson-overlap.sh, --min-overlap);
#   * `[ "$n" -gt 0 ]` in bash — "integer expected" on stderr and a FALSE branch,
#     so an empty --limit reads as no limit at all (rereview-open-prs.sh).
#
# This repository has written that guard four times and got it right once:
# report.sh, whose `--since` carries "refuses an empty --since instead of
# ignoring it" as its own case. The lesson existed, in this directory, and was
# not applied to the next three scripts — so it belongs in a check rather than
# in anyone's memory.
#
# Stock python3, the repo-hygiene.sh pattern, because PyYAML is not a dependency.

it "lets no numeric guard admit the empty string"

_numeric_guards_admitting_empty() {
  python3 - "${1:-$(cd -- "$SCRIPTS/.." && pwd)}" <<'PY'
import io
import os
import re
import sys

root = sys.argv[1]
scripts = os.path.join(root, "scripts")
offenders = []

for name in sorted(os.listdir(scripts)):
    if not name.endswith(".sh"):
        continue
    text = io.open(os.path.join(scripts, name), encoding="utf-8").read()
    # Every `case "$var" in … esac` that tests for a non-digit. Non-greedy to
    # the nearest `esac`, so two guards in one file are two matches.
    for match in re.finditer(r'case\s+"\$(\w+)"\s+in(.*?)esac', text, re.S):
        var, body = match.group(1), match.group(2)
        if "[!0-9]" not in body:
            continue
        # An empty-string arm, in any of the shapes bash accepts for one — and
        # bash accepts BOTH quote styles. The first version of this looked for
        # `""` alone and accused report.sh, which spells it `''` and is the one
        # script in this repository that has always been right about this. A
        # check whose only finding is a false positive on the correct
        # implementation is worse than no check at all.
        empty = r"""(?:''|"")"""
        guarded = (re.search(r"^\s*\|?\s*" + empty + r"\s*\)", body, re.M)
                   or re.search(empty + r"\s*\|", body)
                   or re.search(r"\|\s*" + empty + r"\s*\)", body))
        if not guarded:
            offenders.append("%s: $%s" % (name, var))

print(" ".join(offenders))
PY
}

assert_equal "" "$(_numeric_guards_admitting_empty)" \
  "every numeric guard rejects an empty value explicitly"

# The check must be able to see a violation, not merely pass over scripts that
# already comply. Build one, and its corrected twin, and require it to tell them
# apart — otherwise "no offenders" would also be the answer on a repository it
# cannot read at all.

it "sees a guard that forgot the empty case"

_probe_tree() {
  local root="$TESTTMP/numguard/$1"
  rm -rf "$root"; mkdir -p "$root/scripts"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$root/scripts/probe.sh"
  printf '%s' "$root"
}

assert_equal "probe.sh: \$n" \
  "$(_numeric_guards_admitting_empty "$(_probe_tree bad 'case "$n" in *[!0-9]*) die "nope" ;; esac')")" \
  "a bare non-digit test is named"

assert_equal "" \
  "$(_numeric_guards_admitting_empty "$(_probe_tree good 'case "$n" in
  "")       die "empty" ;;
  *[!0-9]*) die "nope" ;;
esac')")" \
  "and the same guard with an empty arm is not"

assert_equal "" \
  "$(_numeric_guards_admitting_empty "$(_probe_tree oneline 'case "$n" in ""|*[!0-9]*) die "nope" ;; esac')")" \
  "nor the one-line form that folds the empty case into the pattern"

# A `case` that is not about digits at all must not be dragged in: --repo's
# OWNER/REPO check and the verdict vocabularies are all `case` statements too.
assert_equal "" \
  "$(_numeric_guards_admitting_empty "$(_probe_tree unrelated 'case "$repo" in */*) ;; *) die "nope" ;; esac')")" \
  "and a case that tests no digits is left alone"

# Both quote styles. report.sh writes its empty arm as '' and is the one script
# here that has always been right about this; a check that flagged it would have
# been a check nobody could keep.
_singlequote_tree() {
  local root="$TESTTMP/numguard/sq"
  rm -rf "$root"; mkdir -p "$root/scripts"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$n" in\n'
    printf "  ''|*[!0-9]*) die 'nope' ;;\n"
    printf 'esac\n'
  } > "$root/scripts/probe.sh"
  printf '%s' "$root"
}
assert_equal "" "$(_numeric_guards_admitting_empty "$(_singlequote_tree)")" \
  "an empty arm written with single quotes counts as one"
