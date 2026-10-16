import type { ClaimedMonitor } from "./monitor-claim.js";
import type { HttpCheckResult } from "./http-check.js";
import type { ProcessCheckResultInput } from "./process-check-result.js";

export const WORKER_BATCH_SIZE = 1;
export const MONITOR_LEASE_SECONDS = 90;

type WorkerLogger = Pick<Console, "info" | "error">;

export type WorkerBatchDependencies = {
  claimDueMonitors: (
    batchSize: number,
    leaseSeconds: number,
  ) => Promise<ClaimedMonitor[]>;
  executeHttpCheck: (monitor: ClaimedMonitor) => Promise<HttpCheckResult>;
  processCheckResult: (input: ProcessCheckResultInput) => Promise<void>;
  rescheduleAfterFailure: (monitorId: string) => Promise<void>;
  logger?: WorkerLogger;
};

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export async function processBatch({
  claimDueMonitors,
  executeHttpCheck,
  processCheckResult,
  rescheduleAfterFailure,
  logger = console,
}: WorkerBatchDependencies): Promise<void> {
  const monitors = await claimDueMonitors(
    WORKER_BATCH_SIZE,
    MONITOR_LEASE_SECONDS,
  );

  if (monitors.length === 0) {
    return;
  }

  logger.info("Claimed monitors", { count: monitors.length });

  for (const monitor of monitors) {
    try {
      const result = await executeHttpCheck(monitor);
      await processCheckResult({ monitor, result });

      logger.info("Monitor check processed", {
        monitorId: monitor.id,
        success: result.ok,
        latencyMs: result.latencyMs,
      });
    } catch (error) {
      logger.error("Failed to process monitor check", {
        monitorId: monitor.id,
        message: getErrorMessage(error),
      });

      try {
        await rescheduleAfterFailure(monitor.id);
      } catch (retryError) {
        logger.error("Failed to reschedule monitor after processing error", {
          monitorId: monitor.id,
          message: getErrorMessage(retryError),
        });
      }
    }
  }
}
