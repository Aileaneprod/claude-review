# Stack profile: generic

No stack-specific profile matched this repository, so apply the base priorities
with extra care about context: you know less about the conventions here than
usual. Read more before concluding, and lean harder toward silence.

## Language-independent failure modes

- **Injection.** Any user-controlled value concatenated into SQL, a shell
  command, a file path, an HTTP URL, an LDAP filter, or a template. Look for
  string building where a parameterized API exists. *Not a finding if* the value
  is a validated enum, a bounded integer, or comes from a closed internal set —
  trace where it originates before flagging.
- **Authorization gaps.** An object fetched by id from a request parameter with
  no check that the caller owns or may access it. Authentication answers *who*;
  this is *whether* — they are separate and the second is often missing.
- **Secrets in source.** Literal keys, tokens, passwords, private keys, or
  connection strings. Distinguish real secrets from public identifiers,
  publishable keys, and example values before flagging.
- **Swallowed errors.** A catch/rescue/`if err != nil` branch that logs and
  continues where the caller cannot detect the failure, especially on a write.
- **Resource leaks.** Files, sockets, connections, or locks released only on the
  happy path rather than in a `finally`/`defer`/context manager.
- **Unbounded work.** Queries with no limit, reads of a whole file or table into
  memory, recursion with no depth bound, retries with no cap or backoff.
- **Concurrency.** Shared mutable state without synchronization; check-then-act
  sequences that are not atomic.

## Migrations and data changes

- Irreversible operations (drop column, drop table, destructive backfill) with no
  rollback path and no staged rollout.
- A schema change deployed in one step with the code that depends on it — old
  instances run against the new schema during the deploy.
- Backfills that rewrite rows without batching or without being resumable.
- Non-idempotent migrations: re-running should be safe, so prefer
  `IF NOT EXISTS` / `IF EXISTS` guards. A migration that already has them is
  correct — do not flag it.

## Infrastructure and config as code

- Containers running as root, or a `Dockerfile` that copies secrets into a layer.
- Overly permissive network rules, IAM policies, CORS origins, or bucket ACLs.
- CI workflows with broad `permissions:`, or that check out and execute untrusted
  code in a job holding secrets.
- Third-party actions or images pinned to a mutable tag on a security-sensitive
  path.
- A changed default in config that alters production behaviour without anyone
  asking for it.

## Tests

- Behaviour changed with no test covering the new branch.
- A test weakened, skipped, or deleted in the same PR as the change it covered —
  always worth a comment.
- Assertions that cannot fail (`assert True`, no assertion at all, a snapshot
  regenerated without review).
