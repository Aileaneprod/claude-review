export interface LineItem {
  sku: string;
  quantityCents: number;
  unitPriceCents: number;
}

/**
 * Sum line items in minor units. Integer arithmetic throughout — no floats —
 * so totals are exact.
 */
export function subtotalCents(items: readonly LineItem[]): number {
  return items.reduce(
    (sum, item) => sum + item.quantityCents * item.unitPriceCents,
    0,
  );
}

/**
 * Apply a percentage discount expressed in basis points (1% = 100bps).
 * Rounds half-up to the nearest cent and never returns a negative total.
 */
export function applyDiscountCents(
  subtotal: number,
  discountBps: number,
): number {
  if (!Number.isInteger(subtotal) || subtotal < 0) {
    throw new RangeError(`subtotal must be a non-negative integer: ${subtotal}`);
  }
  if (!Number.isInteger(discountBps) || discountBps < 0 || discountBps > 10_000) {
    throw new RangeError(`discountBps must be between 0 and 10000: ${discountBps}`);
  }

  const discount = Math.round((subtotal * discountBps) / 10_000);
  return Math.max(0, subtotal - discount);
}
