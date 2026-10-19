import { listPublicMonitorRecords } from "./public-status.repository.js";

type MonitorStatus = "up" | "down" | "unknown" | "paused";

function asDate(value: Date | string | null): Date | null {
  if (value === null) return null;
  return value instanceof Date ? value : new Date(value);
}

function uptimePercent(successes: number, checks: number): number | null {
  if (checks === 0) return null;
  return Number(((successes / checks) * 100).toFixed(2));
}

export async function getPublicStatus() {
  const generatedAt = new Date();
  const records = await listPublicMonitorRecords();

  const monitors = records.map((record) => {
    const lastChecked = asDate(record.last_checked_at);

    // Mark monitors stale when no check has completed for three intervals.
    const stale =
      lastChecked === null ||
      generatedAt.getTime() - lastChecked.getTime() >
        record.interval_seconds * 3 * 1000;

    let status: MonitorStatus;

    if (!record.enabled) {
      status = "paused";
    } else if (stale) {
      status = "unknown";
    } else {
      status = record.latest_success ? "up" : "down";
    }

    return {
      name: record.name,
      status,
      last_checked_at: lastChecked?.toISOString() ?? null,
      uptime_24h_percent: uptimePercent(
        record.successes_24h,
        record.checks_24h,
      ),
      uptime_7d_percent: uptimePercent(record.successes_7d, record.checks_7d),
    };
  });

  const activeMonitors = monitors.filter(
    (monitor) => monitor.status !== "paused",
  );

  let status: "operational" | "degraded" | "unknown" = "unknown";

  if (activeMonitors.some((monitor) => monitor.status === "down")) {
    status = "degraded";
  } else if (
    activeMonitors.length > 0 &&
    activeMonitors.every((monitor) => monitor.status === "up")
  ) {
    status = "operational";
  }

  return {
    status,
    generated_at: generatedAt.toISOString(),
    monitors,
  };
}
