import type { PoolClient } from "pg";
import { pool } from "./db.js";

export type ClaimedMonitor = {
  id: string;
  name: string;
  url: string;
  interval_seconds: number;
  timeout_ms: number;
  expected_status_code: number;
  next_check_at: Date;
};
const DEFAULT_BATCH_SIZE = 1;
const DEFAULT_LEASE_SECONDS = 90;
const PROCESSING_RETRY_DELAY_SECONDS = 5;

export async function claimDueMonitors(
  batchSize = DEFAULT_BATCH_SIZE,
  leaseSeconds = DEFAULT_LEASE_SECONDS,
): Promise<ClaimedMonitor[]> {
  if (!Number.isInteger(batchSize) || batchSize < 1) {
    throw new RangeError("batchSize must be a positive integer");
  }

  if (!Number.isInteger(leaseSeconds) || leaseSeconds < 1) {
    throw new RangeError("leaseSeconds must be a positive integer");
  }
  const client: PoolClient = await pool.connect();

  try {
    await client.query("BEGIN");
    const result = await client.query<ClaimedMonitor>(
      `WITH due_monitors AS (
         SELECT id
         FROM monitors
         WHERE enabled = TRUE
           AND next_check_at <= NOW()
         ORDER BY next_check_at ASC, id ASC
         LIMIT $1
         FOR UPDATE SKIP LOCKED
       )
       UPDATE monitors AS monitor
       SET next_check_at =
         NOW() + ($2 * INTERVAL '1 second')
       FROM due_monitors
       WHERE monitor.id = due_monitors.id
       RETURNING
         monitor.id,
         monitor.name,
         monitor.url,
         monitor.interval_seconds,
         monitor.timeout_ms,
         monitor.expected_status_code,
         monitor.next_check_at`,
      [batchSize, leaseSeconds],
    );
    await client.query("COMMIT");
    return result.rows;
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch (rollbackError) {
      console.error("Failed to roll back monitor claim", {
        message:
          rollbackError instanceof Error
            ? rollbackError.message
            : String(rollbackError),
      });
    }

    throw error;
  } finally {
    client.release();
  }
}

export async function rescheduleMonitorAfterFailure(
  monitorId: string,
): Promise<void> {
  await pool.query(
    `UPDATE monitors
     SET next_check_at = NOW() + ($2 * INTERVAL '1 second')
     WHERE id = $1`,
    [monitorId, PROCESSING_RETRY_DELAY_SECONDS],
  );
}
