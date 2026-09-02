# Stack profile: PostgreSQL (schema, migrations, isolation)

Checks for repositories where PostgreSQL carries the schema — Drizzle, Prisma,
raw SQL migrations. Several patterns below have legitimate forms that look
identical without reading the surrounding code, so the base grounding rules
apply with full force: open the migration, open the schema, open the test.

## Row-level security and tenant isolation

- **A guard proved by a test the guard does not apply to is not proved.** When a
  change adds RLS, a permission check or a tenant scope, find out which
  principal the tests connect as. A superuser bypasses RLS **even under
  `FORCE ROW LEVEL SECURITY`**; so does the table owner unless `FORCE` is set.
  A green test under either proves the test runs, not that the policy holds.
  *Not a finding if* the test explicitly switches role (`SET ROLE`, a distinct
  connection string, a role the policy names) before asserting.
- **`ENABLE ROW LEVEL SECURITY` without `FORCE`** leaves the owner exempt. If
  the application connects as the owner, the policy is decoration.
- **A policy that reads a session setting** (`current_setting('app.org_id')`)
  needs that setting written per transaction. `set_config(name, value, true)` is
  transaction-local; `false` leaks into the next statement on a pooled
  connection. Check which one the writer passes, and check that every access
  path sets it — one repository method that forgets is the hole.
- **A tenant column with an index but no policy** is isolation by convention.
  Say so plainly, at the severity the repository's own scope decision supports:
  if the project has a named ticket deferring RLS, this is not a finding to
  repeat on every PR.
- **Read every call site a mechanical substitution touched.** A value correct
  where the substitution started is not necessarily the one in scope where it
  ended — a helper that receives its own tenant id as a parameter is the classic
  case.

## Polymorphic roots and composite keys

- **A foreign key proves the row exists, not that it is the right kind.** When a
  table extends a polymorphic root — a `business_object` carrying an
  `object_type`, a `node` carrying a `kind` — a foreign key on
  `(id, tenant_id)` lets an extension of type A attach to a root declared type
  B. Look for the invariant that binds the extension to its discriminator: a
  unique/foreign key that includes the type column, or a check constraint, plus
  a negative test inserting under a root of the wrong type. *Not a finding if*
  either already exists.
- A composite foreign key whose target has no matching unique constraint does
  not compile as intended — check the target side, not just the referencing one.
- Cross-tenant references: a foreign key on `id` alone lets a row point at
  another tenant's row. The composite `(id, tenant_id)` form is what prevents
  it, and a repository that uses it in one place and not another is worth a
  comment.

## Migrations

- **Not idempotent, or not reviewable.** Prefer `IF NOT EXISTS` / `IF EXISTS`.
  A migration that already has them is correct — do not flag it.
- **Generated migrations are not hand-written code.** When the schema is
  declared in TypeScript/Prisma and the SQL is produced by a generator, the
  generated file is an artefact: do not ask for it to be refactored, renamed or
  commented. Check that it matches the declaration it came from.
- Destructive statements (drop column, drop table, type narrowing, a backfill
  that rewrites in place) with no rollback path or staged rollout.
- A schema change and the code depending on it in one deploy step: old
  instances run against the new schema for the length of the rollout.
- Long-held locks on a large table — `ALTER TABLE … SET NOT NULL`, adding a
  foreign key, a non-concurrent index build — on a path that must stay online.
- A migration that creates a role or grants privileges: check what happens when
  the role already exists, and whether the documented behaviour matches the
  branch the code actually takes.

## Queries and constraints

- A `CHECK` that admits the empty string where the column's meaning forbids it —
  `NOT NULL` does not imply non-blank.
- Nullable columns whose null carries meaning, with no comment saying what it
  means; and the symmetric case, a `NOT NULL` added without a default over a
  populated table.
- Missing index on a column a new query path filters, joins or orders by —
  state which query, and check it is not already covered by a composite index's
  leading column.
- `SELECT` without `LIMIT` on a path that grows with tenant data; N+1 issued
  inside a loop where a single statement with `IN` or a join would do.
- Money as `float`/`double precision`, timestamps without time zone on a path
  that crosses zones, `text` where an enum or a foreign key is meant.

## Tests against a real database

- An integration test that asserts on a stubbed repository proves the stub, not
  the schema. Constraints, defaults, triggers and policies only exist in the
  database.
- A test that never fails: no assertion after the write, or an assertion on the
  value it just passed in rather than on what came back.
- Deleting or weakening a negative test — the one that inserts the forbidden row
  and expects a rejection — in the same PR as the constraint it covered.
