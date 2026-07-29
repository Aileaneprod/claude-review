# Stack profile: n8n workflow JSON

These are exported workflow definitions, not application source. Review the JSON
structurally — node types, connections, parameters — not as prose.

## Credentials

- **Credentials embedded in the export.** Any node whose `parameters` contain a
  literal API key, bearer token, password, connection string, or basic-auth pair
  is a 🔴 finding. Exported workflows get committed, shared, and pasted into
  issues.
- *Not a finding:* a `credentials` block that references a stored credential by
  `id` and `name`. That is the correct pattern and contains no secret material —
  check which form you are looking at before flagging.
- Secrets pasted into an HTTP node's header, query string, or URL rather than
  into a credential.
- Tokens in `Code`/`Function` node bodies.

## Error handling

- **No error branch.** A node with `onError` left at the default in a workflow
  that writes to an external system — the run dies mid-way and leaves partial
  state with no alert.
- `continueOnFail` / `onError: "continueRegularOutput"` set on a node whose
  failure genuinely matters, so a failed step silently produces empty items that
  flow downstream as if they were real.
- No error trigger, notification, or catch path anywhere in a scheduled workflow
  — failures are then invisible until someone notices missing data.
- `alwaysOutputData` masking an empty result as a successful one.

## Loops and volume

- `SplitInBatches` / loop constructs with no termination condition or bound, or
  whose exit connection is missing — these can spin indefinitely.
- A pagination loop with no maximum page count.
- An HTTP node inside a loop with no delay against an API that rate-limits.
- A trigger fetching an unbounded result set on every run rather than filtering
  by a cursor or timestamp.

## Webhooks

- **A `Webhook` node with `authentication: "none"`** that triggers writes, sends
  messages, or spends money. Publicly reachable and unauthenticated.
- No validation of the incoming payload shape before use.
- Missing signature verification where the provider offers it (Stripe, GitHub,
  Shopify).
- `responseMode` returning internal data or error detail to the caller.

## Idempotency

- A webhook or polling handler that creates records without a dedupe key —
  providers retry, and n8n itself retries, so every at-least-once delivery
  creates a duplicate.
- Inserts where an upsert on a natural key is meant.
- Non-idempotent side effects (send email, charge card, post message) on a path
  that can re-run, with nothing recording that it already happened.
- A workflow whose re-run after partial failure would repeat completed steps.
