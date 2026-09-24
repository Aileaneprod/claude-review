/**
 * Page the on-call channel. Resolves once the webhook has accepted the
 * message; rejects when it does not — a timeout, a 5xx, a revoked URL.
 */
export async function notifyOps(message: string, err: unknown): Promise<void> {
  const response = await fetch(process.env.OPS_WEBHOOK_URL ?? "", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message, error: String(err) }),
  });
  if (!response.ok) {
    throw new Error(`ops webhook refused: ${response.status}`);
  }
}
