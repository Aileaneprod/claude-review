/**
 * Test helper: format an amount in minor units the way invoice fixtures print
 * it, so assertions compare strings the reader can check by eye.
 *
 *   cents(4900) === "49.00"
 *   cents(5)    === "0.05"
 */
export function cents(minorUnits: number): string {
  if (!Number.isInteger(minorUnits) || minorUnits < 0) {
    throw new RangeError(`expected a non-negative integer, got ${minorUnits}`);
  }
  const whole = Math.floor(minorUnits / 100);
  const rest = minorUnits % 100;
  return `${whole}.${rest.toString().padStart(2, "0")}`;
}
