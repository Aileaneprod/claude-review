# Stack profile: Node.js / TypeScript

Checks specific to this stack. Base rules still apply — several patterns below
have legitimate forms that look identical without reading the surrounding code.

## Promises and async

- **Floating promises.** An async call whose result is neither awaited, returned,
  nor `.catch()`-ed. On an error path this becomes an unhandled rejection, which
  in modern Node **terminates the process**. *Not a finding if* it is explicitly
  marked `void someAsyncCall()` with a comment, or has a `.catch()` attached.
- **Missing `await` in `try/catch`.** `try { doAsync() } catch {}` catches
  nothing — the promise rejects outside the block. This is the single most
  common way error handling silently stops working.
- `await` inside a loop where the iterations are independent — should be
  `Promise.all`. Conversely, `Promise.all` where the operations must be ordered
  or would exhaust a connection pool.
- `Promise.all` where one rejection should not cancel the rest —
  `Promise.allSettled` is usually meant.
- `forEach` with an async callback: it does not wait, and the caller cannot know
  when the work finishes.

## Type safety

- `any` used to silence the compiler at a boundary — a JSON parse, an API
  response, a `req.body`. `unknown` plus a narrowing check is the correct shape.
- `as` assertions that assert away a real possibility, especially
  `as SomeType` on parsed JSON, and non-null assertions (`!`) on a value that
  genuinely can be absent.
- `@ts-ignore` / `@ts-expect-error` added without a comment explaining why.
- **Non-exhaustive discriminated unions.** A `switch` on a union tag with no
  `default` that either throws or does an `assertNever(x: never)` check. When a
  new variant is added later, the compiler will not catch the gap. *Not a
  finding if* an exhaustiveness guard is present, even indirectly.
- Optional chaining used where the value being absent is itself the bug — `?.`
  can hide a real null rather than handle it.

## Input validation at boundaries

- Route handlers reading `req.body`/`req.query`/`req.params` without a schema
  (zod, valibot, joi, class-validator). TypeScript types are erased at runtime
  and validate nothing.
- Environment variables read and used without validation or a default; `process.env.X`
  is `string | undefined` and is often silently `undefined` in one environment.
- User input reaching a query, a file path, a shell command, or a template
  without escaping or parameterization.

## State and concurrency

- Module-level mutable state (a cache, a counter, an array) mutated per request —
  it is shared across every concurrent request in the process.
- An object passed to a caller and then mutated, or a shared array/object mutated
  in place where a copy was intended.
- `Array.sort()`, `reverse()`, `splice()` on an array the caller still holds —
  these mutate in place.
- Read-modify-write on shared state across an `await` boundary: the state can
  change while suspended.

## Errors and resources

- `catch` blocks that log and continue, or that swallow the error entirely.
- `catch (e) { throw new Error(...) }` discarding the original — attach `cause`.
- Streams, file handles, DB connections, or timers not cleaned up on the error
  path; cleanup that is in the `try` rather than a `finally`.
- `process.exit()` in library code, which skips pending I/O flushes.
