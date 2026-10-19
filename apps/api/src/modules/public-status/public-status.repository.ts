import { pool } from "../../db.js";

export type PublicMonitorRecord = {
  name: string;
  enabled: boolean;
  interval_seconds: number;
  last_checked_at: Date | string | null;
  latest_success: boolean | null;
  checks_24h: number;
  successes_24h: number;
  checks_7d: number;
  successes_7d: number;
};

export async function listPublicMonitorRecords(): Promise<
  PublicMonitorRecord[]
> {
  const result = await pool.query(`
    WITH uptime AS (
      SELECT
        monitor_id,
        COUNT(*) FILTER (
          WHERE checked_at >= NOW() - INTERVAL '24 hours'
        )::int AS checks_24h,
        COUNT(*) FILTER (
          WHERE success
            AND checked_at >= NOW() - INTERVAL '24 hours'
        )::int AS successes_24h,
        COUNT(*)::int AS checks_7d,
        COUNT(*) FILTER (WHERE success)::int AS successes_7d
      FROM check_results
      WHERE checked_at >= NOW() - INTERVAL '7 days'
      GROUP BY monitor_id
    )
    SELECT
      m.name,
      m.enabled,
      m.interval_seconds,
      latest.checked_at AS last_checked_at,
      latest.success AS latest_success,
      COALESCE(u.checks_24h, 0)::int AS checks_24h,
      COALESCE(u.successes_24h, 0)::int AS successes_24h,
      COALESCE(u.checks_7d, 0)::int AS checks_7d,
      COALESCE(u.successes_7d, 0)::int AS successes_7d
    FROM monitors AS m
    LEFT JOIN LATERAL (
      SELECT cr.checked_at, cr.success
      FROM check_results AS cr
      WHERE cr.monitor_id = m.id
      ORDER BY cr.checked_at DESC, cr.id DESC
      LIMIT 1
    ) AS latest ON TRUE
    LEFT JOIN uptime AS u ON u.monitor_id = m.id
    ORDER BY m.name ASC, m.id ASC
    `);
  return result.rows as PublicMonitorRecord[];
}
