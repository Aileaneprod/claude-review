# detect-profile.sh — picking a profile wrongly is not free. The profile is
# appended to the prompt, so a wrong one spends quota on a checklist that cannot
# apply and invites findings grounded in the wrong stack.
#
# The postgres detector originally treated ANY drizzle.config.*, schema.prisma,
# or *.sql under migrations/ as PostgreSQL. Drizzle supports MySQL and SQLite;
# Prisma supports several providers. The dialect cases below fail against that
# version.

_detect() { "$SCRIPTS/detect-profile.sh" "$1" | paste -sd, -; }

_fixture_repo() {
  # Build a throwaway repo shape and echo its path.
  local name="$1"; shift
  local dir="$TESTTMP/repos/$name"
  rm -rf "$dir"; mkdir -p "$dir"
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$content" > "$dir/$path"
  done
  printf '%s' "$dir"
}

# --- postgres must require PostgreSQL evidence -------------------------------

it "detects postgres from a postgres drizzle dialect"
assert_contains "postgres" "drizzle dialect postgresql" -- _detect \
  "$(_fixture_repo pg-drizzle 'drizzle.config.ts' 'export default { dialect: "postgresql", schema: "./src/schema.ts" }')"

it "does NOT detect postgres from a mysql drizzle dialect"
assert_not_contains "postgres" "drizzle dialect mysql is not postgres" -- _detect \
  "$(_fixture_repo mysql-drizzle 'drizzle.config.ts' 'export default { dialect: "mysql", schema: "./src/schema.ts" }')"

it "does NOT detect postgres from a sqlite drizzle dialect"
assert_not_contains "postgres" "drizzle dialect sqlite is not postgres" -- _detect \
  "$(_fixture_repo sqlite-drizzle 'drizzle.config.ts' 'export default { dialect: "sqlite" }')"

it "detects postgres from a postgresql prisma provider"
assert_contains "postgres" "prisma provider postgresql" -- _detect \
  "$(_fixture_repo pg-prisma 'prisma/schema.prisma' 'datasource db { provider = "postgresql" url = env("DATABASE_URL") }')"

it "does NOT detect postgres from a mysql prisma provider"
assert_not_contains "postgres" "prisma provider mysql is not postgres" -- _detect \
  "$(_fixture_repo mysql-prisma 'prisma/schema.prisma' 'datasource db { provider = "mysql" url = env("DATABASE_URL") }')"

# --- pruning: a vendored directory must not decide the profile ---------------

it "ignores a migrations directory vendored under an excluded path"
assert_not_contains "postgres" "vendor/**/migrations does not flip postgres" -- _detect \
  "$(_fixture_repo vendored 'vendor/somelib/migrations/001.sql' 'select 1;')"

it "still detects a real migrations directory carrying postgres syntax"
assert_contains "postgres" "db/migrations with postgres SQL detects" -- _detect \
  "$(_fixture_repo real-migrations 'db/migrations/001.sql' 'create table t (id uuid primary key); alter table t enable row level security;')"

# --- test fixtures describe a simulated stack, not this repository's ---------
# detect-profile.sh already prunes `.claude-review-tooling` because scanning the
# reviewer's own checkout inside a target workspace classified a Next.js app as
# n8n. The same fixtures do it again when claude-review reviews ITSELF: they sit
# at the root, so eval/fixtures/08-*/workflows/*.n8n.json and
# eval/fixtures/10-*/migrations/*.sql made this repository detect as
# `n8n,postgres` and loaded two irrelevant profiles into every self-review.

it "does not take its stack from a fixtures directory"
assert_not_contains "n8n" "an n8n export under fixtures/ is not the repo's stack" -- _detect \
  "$(_fixture_repo fixture-n8n \
      'eval/fixtures/08-n8n/workflows/lead-sync.n8n.json' '{"nodes": [], "connections": {}}' \
      'README.md' '# a prompts repository')"

assert_not_contains "postgres" "postgres SQL under fixtures/ is not the repo's stack" -- _detect \
  "$(_fixture_repo fixture-pg \
      'eval/fixtures/10-migration/migrations/0001.sql' 'create table t (id uuid, doc jsonb);' \
      'README.md' '# a prompts repository')"

it "still reads a real workflows directory at the root"
assert_contains "n8n" "a genuine n8n export still detects" -- _detect \
  "$(_fixture_repo real-n8n 'workflows/sync.json' '{"nodes": [{"x": 1}], "connections": {}}')"

# --- monorepos keep their tsconfig under the package, not at the root --------
# The check was `[ -f "$root/tsconfig.json" ]`. korbyx is a pnpm workspace whose
# tsconfigs live in apps/*, so it detected `postgres` alone and never got the
# TypeScript checklist. It masks this by setting `profile:` explicitly; a repo
# on `profile: auto` would not.

it "detects node-typescript in a workspace layout"
assert_contains "node-typescript" "tsconfig under apps/* detects" -- _detect \
  "$(_fixture_repo ts-monorepo \
      'package.json' '{"name": "root", "private": true}' \
      'pnpm-workspace.yaml' 'packages: ["apps/*"]' \
      'apps/web/tsconfig.json' '{"compilerOptions": {"strict": true}}' \
      'apps/web/src/index.ts' 'export const x = 1')"

it "still detects a single-package layout"
assert_contains "node-typescript" "root tsconfig detects" -- _detect \
  "$(_fixture_repo ts-single 'tsconfig.json' '{}' 'src/index.ts' 'export const x = 1')"

it "does not call a plain JavaScript repo TypeScript"
assert_not_contains "node-typescript" "no tsconfig anywhere" -- _detect \
  "$(_fixture_repo js-only 'package.json' '{"name": "js"}' 'index.js' 'module.exports = 1')"

# --- the fallback still works ------------------------------------------------

it "falls back to generic on an empty repository"
assert_equal "generic" "$(_detect "$(_fixture_repo empty 'README.md' '# nothing here')")" "empty repo is generic"
