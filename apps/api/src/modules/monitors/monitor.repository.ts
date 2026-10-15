import { pool } from "../../db";
import { CreateMonitorInput, UpdateMonitorInput } from "./monitor.schema";

const monitorColumns = `
  id,
  name,
  url,
  interval_seconds,
  timeout_ms,
  expected_status_code,
  enabled,
  created_at,
  updated_at
`;

export async function createMonitor(data: CreateMonitorInput) {
  const result = await pool.query(
    `INSERT INTO monitors (
       name, url, interval_seconds, timeout_ms,
       expected_status_code, enabled
     )
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING ${monitorColumns}`,
    [
      data.name,
      data.url,
      data.interval_seconds,
      data.timeout_ms,
      data.expected_status_code,
      data.enabled,
    ],
  );
  return result.rows[0];
}
export async function listMonitors() {
  const result = await pool.query(
    `SELECT ${monitorColumns}
     FROM monitors
     ORDER BY created_at DESC, id DESC`,
  );
  return result.rows;
}

export async function findMonitorById(id: string) {
  const result = await pool.query(
    `SELECT ${monitorColumns}
     FROM monitors
     WHERE id = $1`,
    [id],
  );

  return result.rows[0] ?? null;
}

export async function updateMonitor(id: string, data: UpdateMonitorInput) {
  const fields: Record<string, unknown> = {
    name: data.name,
    url: data.url,
    interval_seconds: data.interval_seconds,
    timeout_ms: data.timeout_ms,
    expected_status_code: data.expected_status_code,
    enabled: data.enabled,
  };
  const updates = Object.entries(fields).filter(
    ([, value]) => value !== undefined,
  );
  const assignments = updates.map(
    ([column], index) => `${column} = $${index + 2}`,
  );
  const values = updates.map(([, value]) => value);

  const result = await pool.query(
    `UPDATE monitors
     SET ${assignments.join(", ")}, updated_at = NOW()
     WHERE id = $1
     RETURNING ${monitorColumns}`,
    [id, ...values],
  );
  return result.rows[0] ?? null;
}
export async function deleteMonitor(id: string): Promise<boolean> {
  const result = await pool.query(`DELETE FROM monitors WHERE id = $1`, [id]);
  return (result.rowCount ?? 0) > 0;
}
