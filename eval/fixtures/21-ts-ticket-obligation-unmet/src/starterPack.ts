import { Db, withTransaction } from "./db";

export interface PackDashboard {
  key: string;
  title: string;
  layout: unknown;
}

export interface PackAlert {
  key: string;
  metric: string;
  threshold: number;
}

export interface StarterPack {
  version: string;
  dashboards: PackDashboard[];
  alerts: PackAlert[];
}

export interface LoadSummary {
  dashboardsWritten: number;
  dashboardsKept: string[];
  alertsWritten: number;
}

export async function loadStarterPack(
  db: Db,
  workspaceId: string,
  pack: StarterPack,
): Promise<LoadSummary> {
  return withTransaction(db, async (tx) => {
    const summary: LoadSummary = { dashboardsWritten: 0, dashboardsKept: [], alertsWritten: 0 };

    for (const dashboard of pack.dashboards) {
      const existing = await tx.dashboards.findByKey(workspaceId, dashboard.key);
      if (existing && existing.source !== "pack") {
        summary.dashboardsKept.push(dashboard.key);
        continue;
      }
      await tx.dashboards.upsert(workspaceId, {
        ...dashboard,
        source: "pack",
        packVersion: pack.version,
      });
      summary.dashboardsWritten += 1;
    }

    for (const alert of pack.alerts) {
      await tx.alerts.upsert(workspaceId, {
        ...alert,
        source: "pack",
        packVersion: pack.version,
      });
      summary.alertsWritten += 1;
    }

    return summary;
  });
}
