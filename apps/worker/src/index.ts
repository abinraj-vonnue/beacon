import { pool } from "./db";
import { executeHttpCheck } from "./http-check";
import { claimDueMonitors } from "./monitor-claim";
import { processCheckResult } from "./process-check-result";

const POLL_INTERVAL_MS = 5_000;

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function processBatch(): Promise<void> {
  const monitors = await claimDueMonitors();

  if (monitors.length === 0) {
    return;
  }

  console.info("Claimed monitors", {
    count: monitors.length,
  });

  for (const monitor of monitors) {
    try {
      const result = await executeHttpCheck(monitor);

      await processCheckResult({
        monitor,
        result,
      });

      console.info("Monitor check processed", {
        monitorId: monitor.id,
        success: result.ok,
        latencyMs: result.latencyMs,
      });
    } catch (error) {
      console.error("Failed to process monitor check", {
        monitorId: monitor.id,
        message: getErrorMessage(error),
      });
    }
  }
}
let shutdownRequested = false;
let shutdownPromise: Promise<void> | undefined;

function requestShutdown(signal: string): Promise<void> {
  if (shutdownPromise) {
    return shutdownPromise;
  }
  shutdownRequested = true;
  console.info("Worker shutdown requested", { signal });

  shutdownPromise = (async () => {
    try {
      await workerPromise;
      console.info("worker loop stopped");
    } catch (error) {
      console.error("Worker loop failed during shutdown", {
        message: getErrorMessage(error),
      });
      process.exitCode = 1;
    } finally {
      try {
        await pool.end();
        console.info("Database pool closed");
      } catch (error) {
        console.error("Failed to close database pool", {
          message: getErrorMessage(error),
        });
        process.exitCode = 1;
      }
    }
  })();
  return shutdownPromise;
}

async function runWorker(): Promise<void> {
  console.info("Beacon worker started", {
    pollIntervalMs: POLL_INTERVAL_MS,
  });
  while (!shutdownRequested) {
    try {
      await processBatch();
    } catch (error) {
      console.error("Worker batch failed", {
        message: getErrorMessage(error),
      });
    }
    if (!shutdownRequested) {
      await delay(POLL_INTERVAL_MS);
    }
  }
}
const workerPromise = runWorker();

process.on("SIGTERM", () => {
  void requestShutdown("SIGTERM");
});

process.on("SIGINT", () => {
  void requestShutdown("SIGINT");
});

workerPromise.catch((error: unknown) => {
  console.error("Worker terminated unexpectedly", {
    message: getErrorMessage(error),
  });
  process.exitCode = 1;
  void requestShutdown("worker-error");
});
