/**
 * Every request runs in one PostgreSQL transaction at the default isolation
 * level, READ COMMITTED: each statement sees the rows committed before that
 * statement began, not before the transaction began.
 */
export interface Tx {
  one<T>(sql: string, params: unknown[]): Promise<T>;
  none(sql: string, params: unknown[]): Promise<void>;
}

export class UnchangedDueDate extends Error {}
