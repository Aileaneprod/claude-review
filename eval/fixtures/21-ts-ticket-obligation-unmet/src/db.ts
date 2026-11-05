// Data access for workspace content. Every row a starter pack writes is tagged
// `source: "pack"`; the editor switches it to "user" the first time a person
// saves a change, and rows a person creates start as "user".

export type Source = "pack" | "user";

export interface DashboardRow {
  workspaceId: string;
  key: string;
  title: string;
  layout: unknown;
  source: Source;
  packVersion: string | null;
}

export interface AlertRow {
  workspaceId: string;
  key: string;
  metric: string;
  threshold: number;
  source: Source;
  packVersion: string | null;
}

export interface Sql {
  query<T = unknown>(text: string, params?: unknown[]): Promise<T[]>;
}

export interface Db extends Sql {
  connect(): Promise<Sql & { release(): void }>;
}

export interface Tx {
  dashboards: {
    findByKey(workspaceId: string, key: string): Promise<DashboardRow | null>;
    upsert(workspaceId: string, row: Omit<DashboardRow, "workspaceId">): Promise<void>;
  };
  alerts: {
    findByKey(workspaceId: string, key: string): Promise<AlertRow | null>;
    upsert(workspaceId: string, row: Omit<AlertRow, "workspaceId">): Promise<void>;
  };
}

function bind(sql: Sql): Tx {
  return {
    dashboards: {
      async findByKey(workspaceId, key) {
        const rows = await sql.query<DashboardRow>(
          "SELECT * FROM dashboards WHERE workspace_id = $1 AND key = $2",
          [workspaceId, key],
        );
        return rows[0] ?? null;
      },
      async upsert(workspaceId, row) {
        await sql.query(
          `INSERT INTO dashboards (workspace_id, key, title, layout, source, pack_version)
           VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (workspace_id, key) DO UPDATE
             SET title = EXCLUDED.title, layout = EXCLUDED.layout,
                 source = EXCLUDED.source, pack_version = EXCLUDED.pack_version`,
          [workspaceId, row.key, row.title, row.layout, row.source, row.packVersion],
        );
      },
    },
    alerts: {
      async findByKey(workspaceId, key) {
        const rows = await sql.query<AlertRow>(
          "SELECT * FROM alerts WHERE workspace_id = $1 AND key = $2",
          [workspaceId, key],
        );
        return rows[0] ?? null;
      },
      async upsert(workspaceId, row) {
        await sql.query(
          `INSERT INTO alerts (workspace_id, key, metric, threshold, source, pack_version)
           VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (workspace_id, key) DO UPDATE
             SET metric = EXCLUDED.metric, threshold = EXCLUDED.threshold,
                 source = EXCLUDED.source, pack_version = EXCLUDED.pack_version`,
          [workspaceId, row.key, row.metric, row.threshold, row.source, row.packVersion],
        );
      },
    },
  };
}

// Runs `work` inside BEGIN ... COMMIT on one connection. Any error thrown by
// `work`, or by a query it runs, rolls the whole transaction back and is
// rethrown, so either every write lands or none does.
export async function withTransaction<T>(db: Db, work: (tx: Tx) => Promise<T>): Promise<T> {
  const conn = await db.connect();
  try {
    await conn.query("BEGIN");
    const result = await work(bind(conn));
    await conn.query("COMMIT");
    return result;
  } catch (err) {
    await conn.query("ROLLBACK");
    throw err;
  } finally {
    conn.release();
  }
}
