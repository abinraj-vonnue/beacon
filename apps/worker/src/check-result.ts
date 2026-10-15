import { pool } from "./db";
import { HttpCheckResult } from "./http-check";

export type PersistCheckResultInput = {
  monitorId: string;
  result: HttpCheckResult;
};

export async function saveCheckResult({
  monitorId,
  result,
}: PersistCheckResultInput): Promise<void> {
  await pool.query(
    `INSERT INTO check_results (
       monitor_id,
       ok,
       status_code,
       latency_ms,
       error
     )
     VALUES ($1, $2, $3, $4, $5)`,
    [monitorId, result.ok, result.statusCode, result.latencyMs, result.error],
  );
}
