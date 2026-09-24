/**
 * Append one line to the audit trail.
 */
export async function auditLog(event: string, orderId: string): Promise<void> {
  const response = await fetch(process.env.AUDIT_URL ?? "", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ event, orderId, at: new Date().toISOString() }),
  });
  if (!response.ok) {
    throw new Error(`audit refused: ${response.status}`);
  }
}
