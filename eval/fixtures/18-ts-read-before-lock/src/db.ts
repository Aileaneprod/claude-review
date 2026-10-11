/** Every request runs in one PostgreSQL transaction. */
export interface Tx {
  one<T>(sql: string, params: unknown[]): Promise<T>;
  none(sql: string, params: unknown[]): Promise<void>;
}

export class UnchangedDueDate extends Error {}
