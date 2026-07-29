# Stack profile: Python / FastAPI (+ MongoDB)

Checks specific to this stack. Everything in the base rules still applies — in
particular, verify against the actual file before reporting. Several items below
have common legitimate forms that look identical at a glance.

## Async correctness

- **Blocking I/O inside `async def`.** `requests.*`, `time.sleep`, `open().read()`,
  `subprocess.run`, a sync DB driver (`pymongo`, `psycopg2`), or any CPU-heavy
  loop inside an async path stalls the entire event loop, not just that request.
  *Not a finding if* it is wrapped in `run_in_threadpool`, `asyncio.to_thread`,
  `loop.run_in_executor`, or the endpoint is `def` rather than `async def` —
  FastAPI runs sync endpoints in a threadpool automatically.
- **Missing `await`.** A coroutine that is called but not awaited silently
  returns a coroutine object; truthiness checks on it always pass. Watch for
  `motor` calls and any `async def` helper.
- **Fire-and-forget tasks.** `asyncio.create_task(...)` with no reference kept
  can be garbage-collected mid-flight, and exceptions inside it vanish.

## Validation and typing

- Request bodies typed as `dict`, `Any`, or with no model at all — the endpoint
  accepts anything. Pydantic models are the boundary; bypassing them removes it.
- Fields typed `str` where the domain is closed (should be an `Enum` or
  `Literal`), or numeric fields with no `ge`/`le` bound where a negative or
  enormous value would misbehave.
- `response_model` omitted on an endpoint returning a DB document — internal
  fields (`_id`, password hashes, internal flags) leak to the client.
- Path/query parameters interpolated into a query or command without validation.

## Dependency injection

- A dependency that opens a resource without a `yield` teardown, or a `yield`
  dependency whose cleanup is not in a `finally`.
- Auth dependencies declared but not attached — a router with
  `dependencies=[Depends(get_current_user)]` on some routes and not others is
  usually a mistake; check whether the unprotected one is intentional.
- Mutable default arguments and module-level singletons shared across requests.

## MongoDB / motor / PyMongo

- **Unbounded queries.** `find()` with no `.limit()` and no pagination on a
  collection that grows. *Not a finding if* a limit comes from config or a
  parameter with a bound.
- `find().to_list(None)` or `list(cursor)` on an unbounded cursor — loads the
  whole result set into memory.
- A new query path filtering or sorting on a field with no index. Look for a
  migration or index declaration; flag if absent.
- N+1: a `find_one` inside a loop over another query's results, where `$in` or an
  aggregation would do.
- Cursors not exhausted or not closed when iteration is abandoned early.
- Multi-document writes that must be atomic but are not in a transaction/session.
- `ObjectId(user_input)` without a try/except — raises `InvalidId` on malformed
  input and surfaces as a 500 rather than a 400.

## Secrets and configuration

- Secrets read at **import time** (module-level `os.environ["X"]` or
  `Settings()` instantiated at module scope) — this crashes at import in any
  environment missing the var, including test collection, and bakes the value in
  before overrides apply.
- Any literal key, token, connection string, or password in source. A public
  base URL or a documented anon/publishable key is not a secret — check what it
  actually is before flagging.
- `.env` files or credentials added to the repo.

## Error handling

- `except Exception:` (or bare `except:`) that logs and continues where the
  caller cannot detect the failure. Swallowing an error on a write path is a
  data-integrity bug, not a style issue.
- `HTTPException` raised with a message that echoes internal state — stack
  traces, query fragments, or file paths returned to the client.
- Errors caught and re-raised as a generic 500 where a 400/404/409 is correct.
