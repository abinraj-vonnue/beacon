import { pool } from "./db.js";
import type { ClaimedMonitor } from "./monitor-claim.js";
import type { HttpCheckResult } from "./http-check.js";
import { sendIncidentWebhook } from "./webhook.js";
import { nextState } from "@beacon/shared";

export type ProcessCheckResultInput = {
  monitor: ClaimedMonitor;
  result: HttpCheckResult;
};

export async function processCheckResult({
  monitor,
  result,
}: ProcessCheckResultInput): Promise<void> {
  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    // Serialize state transitions for this monitor.
    const monitorResult = await client.query<{
      consecutive_failures: number;
    }>(
      `SELECT consecutive_failures
       FROM monitors
       WHERE id = $1
       FOR UPDATE`,
      [monitor.id],
    );

    const currentMonitor = monitorResult.rows[0];

    if (!currentMonitor) {
      throw new Error(`Monitor ${monitor.id} no longer exists`);
    }

    const incidentResult = await client.query<{ id: string }>(
      `SELECT id
       FROM incidents
       WHERE monitor_id = $1
         AND status ='open'
       ORDER BY opened_at DESC
       LIMIT 1
       FOR UPDATE`,
      [monitor.id],
    );

    const incidentOpen = incidentResult.rows.length > 0;

    const transition = nextState(
      {
        consecutiveFailures: currentMonitor.consecutive_failures,
        incidentOpen,
      },
      result.ok,
    );

    await client.query(
      `INSERT INTO check_results (
         monitor_id, success, status_code, latency_ms, error_message
       )
       VALUES ($1, $2, $3, $4, $5)`,
      [
        monitor.id,
        result.ok,
        result.statusCode,
        result.latencyMs,
        result.error,
      ],
    );

    await client.query(
      `UPDATE monitors
       SET consecutive_failures = $2,
           next_check_at = NOW() + ($3 * INTERVAL '1 second')
       WHERE id = $1`,
      [
        monitor.id,
        transition.state.consecutiveFailures,
        monitor.interval_seconds,
      ],
    );
    let webhookEvent: "opened" | "resolved" | undefined;

    if (transition.action === "open") {
      await client.query(
        `INSERT INTO incidents (monitor_id)
         VALUES ($1)`,
        [monitor.id],
      );
      webhookEvent = "opened";
    } else if (transition.action === "close") {
      const incidentId = incidentResult.rows[0]?.id;

      if (!incidentId) {
        throw new Error(
          `Cannot resolve incident: no open incident found for monitor ${monitor.id}`,
        );
      }

      const updateResult = await client.query(
        `UPDATE incidents
         SET status = 'resolved',
             resolved_at = NOW()
         WHERE id = $1
           AND status = 'open'`,
        [incidentResult.rows[0]?.id],
      );

      if (updateResult.rowCount !== 1) {
        throw new Error(`Failed to resolve incident ${incidentId}`);
      }
      webhookEvent = "resolved";
    }

    await client.query("COMMIT");
    if (webhookEvent) {
      await sendIncidentWebhook(webhookEvent, monitor);
    }
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch (rollbackError) {
      console.error("Failed to roll back check-result transaction", {
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
