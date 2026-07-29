#!/usr/bin/env bash
#
# resolve-config.sh — merge config/defaults.yml with a target repo's optional
# .claude-review.yml and emit the result as JSON on stdout. Repo values win.
#
# Usage:
#   resolve-config.sh [--repo-root DIR] [--defaults FILE] [--repo-config FILE]
#                     [--overrides FILE]
#
#   --repo-root DIR     Root of the repo being reviewed. Its .claude-review.yml
#                       is picked up automatically. Default: current directory.
#   --defaults FILE     Override the defaults file. Default: ../config/defaults.yml
#                       relative to this script.
#   --repo-config FILE  Override the per-repo file explicitly.
#   --overrides FILE    JSON of workflow inputs, applied between the two.
#
# Precedence, least to most specific:
#
#   config/defaults.yml  <  workflow inputs  <  target repo .claude-review.yml
#
# The wrapper workflow sets org-wide policy; the file living next to the code
# being reviewed knows more about that code, so it wins.
#
# Only a deliberately small YAML subset is accepted — top-level `key: scalar`
# and `key:` followed by a block list of scalars. Anything else is a hard error
# rather than a silent misparse. This keeps the whole pipeline dependent on
# nothing beyond stock python3, which is guaranteed on every runner image and is
# also what we can test against locally. See docs/ARCHITECTURE.md.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

repo_root="."
defaults_file="${script_dir}/../config/defaults.yml"
repo_config=""
repo_config_explicit=0
overrides_file=""

die() {
  printf 'resolve-config: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      [ "$#" -ge 2 ] || die "--repo-root requires a value"
      repo_root="$2"
      shift 2
      ;;
    --defaults)
      [ "$#" -ge 2 ] || die "--defaults requires a value"
      defaults_file="$2"
      shift 2
      ;;
    --repo-config)
      [ "$#" -ge 2 ] || die "--repo-config requires a value"
      repo_config="$2"
      repo_config_explicit=1
      shift 2
      ;;
    --overrides)
      [ "$#" -ge 2 ] || die "--overrides requires a value"
      overrides_file="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -f "$defaults_file" ] || die "defaults file not found: $defaults_file"

if [ "$repo_config_explicit" -eq 0 ]; then
  repo_config="${repo_root}/.claude-review.yml"
fi

# An absent per-repo config is the normal case, not an error. Pass an empty
# string so the reader knows to skip it.
if [ ! -f "$repo_config" ]; then
  repo_config=""
fi

if [ -n "$overrides_file" ] && [ ! -f "$overrides_file" ]; then
  die "overrides file not found: $overrides_file"
fi

python3 - "$defaults_file" "$repo_config" "$overrides_file" <<'PY'
import json
import sys

# --- The accepted YAML subset ------------------------------------------------
#
#   key: scalar          scalar is a quoted string, bare string, int, float,
#                        bool (true/false/yes/no/on/off), or null (~/null)
#   key:                 followed by zero or more block-list items
#     - scalar
#
# Everything else is rejected with a file:line message.

SCHEMA = {
    "profile": str,
    "model": str,
    "max_turns": int,
    "max_findings": int,
    "max_diff_lines": int,
    "fail_on_blocking": bool,
    "exclude_paths": list,
}


def fail(path, lineno, msg):
    sys.stderr.write("resolve-config: %s:%d: %s\n" % (path, lineno, msg))
    sys.exit(1)


def strip_comment(text):
    """Remove a trailing # comment, respecting quoted strings."""
    out = []
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if ch == "\\" and quote == '"' and i + 1 < len(text):
                out.append(ch)
                out.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            out.append(ch)
        elif ch in ('"', "'"):
            quote = ch
            out.append(ch)
        elif ch == "#" and (not out or out[-1] in " \t"):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).rstrip()


def parse_scalar(token, path, lineno):
    tok = token.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ('"', "'"):
        body = tok[1:-1]
        if tok[0] == '"':
            body = body.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
        else:
            body = body.replace("''", "'")
        return body
    if not tok:
        return None
    if tok[0] in "[{|>&*!":
        fail(path, lineno,
             "unsupported YAML syntax %r — only plain scalars and block lists "
             "are accepted" % tok[0])
    low = tok.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if low in ("null", "~"):
        return None
    try:
        return int(tok)
    except ValueError:
        pass
    try:
        return float(tok)
    except ValueError:
        pass
    return tok


def parse(path):
    with open(path, encoding="utf-8") as handle:
        raw_lines = handle.read().splitlines()

    data = {}
    list_key = None

    for lineno, raw in enumerate(raw_lines, 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            fail(path, lineno, "tab used for indentation; use spaces")

        line = strip_comment(raw)
        stripped = line.strip()
        if not stripped:
            continue
        if stripped in ("---", "..."):
            continue

        indent = len(line) - len(line.lstrip(" "))

        if stripped.startswith("- ") or stripped == "-":
            if list_key is None:
                fail(path, lineno, "list item does not belong to any key")
            if stripped == "-":
                fail(path, lineno, "empty list item")
            data[list_key].append(parse_scalar(stripped[2:], path, lineno))
            continue

        if indent != 0:
            fail(path, lineno,
                 "nested mappings are not supported; only top-level keys and "
                 "block lists are accepted")

        if ":" not in stripped:
            fail(path, lineno, "expected 'key: value'")

        key, _, rest = stripped.partition(":")
        key = key.strip()
        if not key:
            fail(path, lineno, "empty key")
        if key in data:
            fail(path, lineno, "duplicate key %r" % key)

        rest = rest.strip()
        if rest == "":
            # A bare `key:` introduces a block list. If no items follow it stays
            # an empty list, which is the sane reading for every key we define.
            data[key] = []
            list_key = key
        else:
            data[key] = parse_scalar(rest, path, lineno)
            list_key = None

    return data


def validate(data, path):
    for key, value in list(data.items()):
        expected = SCHEMA.get(key)
        if expected is None:
            sys.stderr.write(
                "resolve-config: %s: warning: unknown key %r (ignored)\n" % (path, key)
            )
            del data[key]
            continue
        if expected is list and not isinstance(value, list):
            # A single glob written as a scalar is an easy mistake and an
            # unambiguous intent, so accept it rather than being pedantic.
            data[key] = [value]
            continue
        if expected is bool and not isinstance(value, bool):
            sys.stderr.write(
                "resolve-config: %s: key %r must be true or false\n" % (path, key)
            )
            sys.exit(1)
        if expected is int and not isinstance(value, int):
            sys.stderr.write(
                "resolve-config: %s: key %r must be an integer\n" % (path, key)
            )
            sys.exit(1)
        if expected is str and value is None:
            data[key] = ""
        elif expected is str and not isinstance(value, str):
            data[key] = str(value)
    return data


defaults_path = sys.argv[1]
repo_path = sys.argv[2]
overrides_path = sys.argv[3] if len(sys.argv) > 3 else ""

merged = validate(parse(defaults_path), defaults_path)

missing = [k for k in SCHEMA if k not in merged]
if missing:
    sys.stderr.write(
        "resolve-config: %s: missing required key(s): %s\n"
        % (defaults_path, ", ".join(sorted(missing)))
    )
    sys.exit(1)

# Workflow inputs sit between the shipped defaults and the per-repo file. Only
# keys actually present are applied, so an input the caller left alone does not
# stomp a value the reviewed repo set for itself.
if overrides_path:
    with open(overrides_path, encoding="utf-8") as handle:
        overrides = json.load(handle)
    if not isinstance(overrides, dict):
        sys.stderr.write("resolve-config: %s: expected a JSON object\n" % overrides_path)
        sys.exit(1)
    merged.update(validate(overrides, overrides_path))

if repo_path:
    merged.update(validate(parse(repo_path), repo_path))

json.dump(merged, sys.stdout, sort_keys=True, indent=2)
sys.stdout.write("\n")
PY
