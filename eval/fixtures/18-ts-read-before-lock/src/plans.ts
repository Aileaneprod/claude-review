import { Tx, UnchangedDueDate } from "./db";

/**
 * Move an occurrence to a new due date.
 *
 * Two people can reschedule occurrences of the same plan at the same time. The
 * plan row lock serialises them: whoever gets it second waits, then sees the
 * first one's change. A request for the date the occurrence already has is
 * refused, and every real move writes exactly one `due_reported` event.
 */
export async function rescheduleOccurrence(
  tx: Tx,
  occurrenceId: string,
  newDueOn: string,
): Promise<void> {
  const before = await tx.one<{ plan_id: string; due_on: string }>(
    "SELECT plan_id, due_on FROM occurrences WHERE id = $1",
    [occurrenceId],
  );

  await tx.none("SELECT id FROM plans WHERE id = $1 FOR UPDATE", [before.plan_id]);

  if (before.due_on === newDueOn) {
    throw new UnchangedDueDate(occurrenceId);
  }

  await tx.none("UPDATE occurrences SET due_on = $2 WHERE id = $1", [occurrenceId, newDueOn]);
  await tx.none(
    "INSERT INTO plan_events (plan_id, kind, from_due_on, to_due_on) VALUES ($1, 'due_reported', $2, $3)",
    [before.plan_id, before.due_on, newDueOn],
  );
}

/**
 * Cancel an occurrence. Same lock, and the occurrence is read once the lock is
 * held, so a concurrent reschedule is seen.
 */
export async function cancelOccurrence(tx: Tx, planId: string, occurrenceId: string): Promise<void> {
  await tx.none("SELECT id FROM plans WHERE id = $1 FOR UPDATE", [planId]);
  const current = await tx.one<{ due_on: string; cancelled: boolean }>(
    "SELECT due_on, cancelled FROM occurrences WHERE id = $1 AND plan_id = $2",
    [occurrenceId, planId],
  );
  if (current.cancelled) {
    return;
  }
  await tx.none("UPDATE occurrences SET cancelled = true WHERE id = $1", [occurrenceId]);
  await tx.none(
    "INSERT INTO plan_events (plan_id, kind, from_due_on, to_due_on) VALUES ($1, 'cancelled', $2, NULL)",
    [planId, current.due_on],
  );
}
