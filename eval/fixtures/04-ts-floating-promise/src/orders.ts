import { auditLog } from "./audit";
import { notifyOps } from "./notify";
import { db } from "./db";

export interface Order {
  id: string;
  total: number;
  status: "pending" | "paid" | "refunded";
}

/**
 * Best-effort telemetry. Deliberately not awaited — the caller must not block
 * on it and a failure here must not fail the order. The rejection is handled.
 */
function trackAsync(event: string, orderId: string): void {
  void auditLog(event, orderId).catch((err) => {
    console.error("audit failed", err);
  });
}

export async function refundOrder(orderId: string): Promise<Order> {
  const order = await db.orders.findById(orderId);
  if (!order) {
    throw new Error(`order ${orderId} not found`);
  }

  trackAsync("refund.started", orderId);

  try {
    const refunded = await db.orders.update(orderId, { status: "refunded" });
    return refunded;
  } catch (err) {
    notifyOps(`refund failed for ${orderId}`, err);
    throw err;
  }
}
