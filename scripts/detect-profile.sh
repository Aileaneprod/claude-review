#!/usr/bin/env bash
#
# detect-profile.sh — choose prompt profile(s) by inspecting a repository.
#
# Usage:
#   detect-profile.sh [REPO_ROOT]
#
# Prints one profile name per line, in a stable order. When several stacks are
# present all matching profiles are printed and the caller concatenates them —
# a React Native app written in TypeScript genuinely wants both checklists.
# Prints `generic` when nothing matches.
#
# Detection rules:
#   python-fastapi   pyproject.toml or requirements.txt naming fastapi, or a
#                    `import fastapi` / `from fastapi` in tracked Python source
#   node-typescript  tsconfig.json present
#   react-native     package.json mentioning react-native
#   n8n              a *.n8n.json file, or a workflows/ directory holding JSON
#                    with both "nodes" and "connections" keys
#   postgres         a Drizzle config, a Prisma schema, or *.sql under a
#                    migrations/ directory
#   generic          fallback

set -euo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  printf 'detect-profile: not a directory: %s\n' "$root" >&2
  exit 1
fi

# Directories that never contain first-party source and can be enormous.
#
# `.claude-review-tooling` is where review.yml checks this repo out inside the
# target repo's workspace. Without pruning it, detection scans OUR files and
# reports the reviewer's own stack instead of the project's — a Next.js app was
# classified `node-typescript,n8n` because eval/fixtures contains an n8n
# workflow export. Anything scanning from the workspace root must skip it.
prune_dirs=(.git node_modules .venv venv site-packages dist build .next vendor
            .claude-review-tooling)

# grep -r across the repo, skipping the prune list. Returns 1 when nothing
# matches, which is an ordinary outcome here rather than an error.
scan() {
  local pattern="$1" include="$2"
  local args=(-rlEi --include="$include")
  local dir
  for dir in "${prune_dirs[@]}"; do
    args+=(--exclude-dir="$dir")
  done
  grep "${args[@]}" -- "$pattern" "$root" 2>/dev/null | head -n 1
}

# Find files by name, skipping the prune list.
find_named() {
  local name="$1"
  local args=("$root")
  local dir first=1
  args+=(-type d "(")
  for dir in "${prune_dirs[@]}"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      args+=(-o)
    fi
    args+=(-name "$dir")
  done
  args+=(")" -prune -o -type f -name "$name" -print)
  find "${args[@]}" 2>/dev/null | head -n 1
}

profiles=()

# --- python-fastapi ----------------------------------------------------------
is_fastapi=0
for dep_file in pyproject.toml requirements.txt; do
  if [ -f "${root}/${dep_file}" ] && grep -qiE '(^|[^[:alnum:]_])fastapi' "${root}/${dep_file}"; then
    is_fastapi=1
    break
  fi
done
if [ "$is_fastapi" -eq 0 ] && { [ -f "${root}/pyproject.toml" ] || [ -f "${root}/requirements.txt" ]; }; then
  if [ -n "$(scan '^[[:space:]]*(from|import)[[:space:]]+fastapi' '*.py')" ]; then
    is_fastapi=1
  fi
fi
[ "$is_fastapi" -eq 1 ] && profiles+=("python-fastapi")

# --- node-typescript ---------------------------------------------------------
if [ -f "${root}/tsconfig.json" ]; then
  profiles+=("node-typescript")
fi

# --- react-native ------------------------------------------------------------
if [ -f "${root}/package.json" ] && grep -qi 'react-native' "${root}/package.json"; then
  profiles+=("react-native")
fi

# --- n8n ---------------------------------------------------------------------
is_n8n=0
if [ -n "$(find_named '*.n8n.json')" ]; then
  is_n8n=1
elif [ -d "${root}/workflows" ]; then
  # An n8n export is a JSON object carrying both "nodes" and "connections".
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if grep -q '"nodes"' "$candidate" && grep -q '"connections"' "$candidate"; then
      is_n8n=1
      break
    fi
  done <<EOF
$(find "${root}/workflows" -type f -name '*.json' 2>/dev/null)
EOF
fi
[ "$is_n8n" -eq 1 ] && profiles+=("n8n")

# --- postgres ----------------------------------------------------------------
# Additive, like every other profile here: a Drizzle/TypeScript project gets
# node-typescript AND postgres, because both checklists genuinely apply.
#
# The SQL test goes through find_migration_sql rather than a hand-rolled find,
# so it honours the same prune_dirs as every other detector. Rebuilding the
# exclusion list by hand missed vendor/, dist/, build/, .next/ and the virtualenv
# directories, and a migrations/ folder vendored under any of them would have
# flipped this on for a repo that does not own a schema at all.
find_migration_sql() {
  local args=("$root")
  local dir first=1
  args+=(-type d "(")
  for dir in "${prune_dirs[@]}"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      args+=(-o)
    fi
    args+=(-name "$dir")
  done
  args+=(")" -prune -o -type f -name '*.sql' -print)
  find "${args[@]}" 2>/dev/null | grep -Ei '/(migrations|drizzle)/' | head -n 1
}

is_postgres=0
if [ -n "$(find_named 'drizzle.config.ts')" ] || [ -n "$(find_named 'drizzle.config.js')" ] \
   || [ -n "$(find_named 'drizzle.config.mjs')" ] || [ -n "$(find_named 'schema.prisma')" ]; then
  is_postgres=1
elif [ -n "$(find_migration_sql)" ]; then
  is_postgres=1
fi
[ "$is_postgres" -eq 1 ] && profiles+=("postgres")

# --- fallback ----------------------------------------------------------------
if [ "${#profiles[@]}" -eq 0 ]; then
  profiles=("generic")
fi

printf '%s\n' "${profiles[@]}"
