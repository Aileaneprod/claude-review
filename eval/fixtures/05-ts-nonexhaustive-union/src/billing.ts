export type PlanEvent =
  | { kind: "created"; planId: string }
  | { kind: "upgraded"; planId: string; from: string }
  | { kind: "cancelled"; planId: string; at: string }
  | { kind: "paused"; planId: string; until: string };

function assertNever(value: never): never {
  throw new Error(`unhandled variant: ${JSON.stringify(value)}`);
}

/** Exhaustive: the default branch fails the build if a variant is added. */
export function describe(event: PlanEvent): string {
  switch (event.kind) {
    case "created":
      return `plan ${event.planId} created`;
    case "upgraded":
      return `plan ${event.planId} upgraded from ${event.from}`;
    case "cancelled":
      return `plan ${event.planId} cancelled at ${event.at}`;
    case "paused":
      return `plan ${event.planId} paused until ${event.until}`;
    default:
      return assertNever(event);
  }
}

export function revenueDelta(event: PlanEvent): number {
  switch (event.kind) {
    case "created":
      return 1;
    case "upgraded":
      return 2;
    case "cancelled":
      return -1;
  }
  return 0;
}
