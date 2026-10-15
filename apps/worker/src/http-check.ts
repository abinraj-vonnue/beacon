import { performance } from "node:perf_hooks";
import { ClaimedMonitor } from "./monitor-claim";

export type HttpCheckResult = {
  ok: boolean;
  statusCode: number | null;
  latencyMs: number;
  error: string | null;
};
const MAX_ERROR_LENGTH = 2_000;

function getErrorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.slice(0, MAX_ERROR_LENGTH);
}

export async function executeHttpCheck(
  monitor: ClaimedMonitor,
): Promise<HttpCheckResult> {
  const startedAt = performance.now();
  try {
    const response = await fetch(monitor.url, {
      method: "GET",
      signal: AbortSignal.timeout(monitor.timeout_ms),
      redirect: "follow",
    });
    const latencyMs = Math.round(performance.now() - startedAt);
    const ok = response.status === monitor.expected_status_code;

    try {
      await response.body?.cancel();
    } catch {
      // The status and response-header latency are already known.
    }
    return {
      ok,
      statusCode: response.status,
      latencyMs,
      error: ok
        ? null
        : `Expected HTTP ${monitor.expected_status_code}, received ${response.status}`,
    };
  } catch (error: unknown) {
    return {
      ok: false,
      statusCode: null,
      latencyMs: Math.round(performance.now() - startedAt),
      error: getErrorMessage(error),
    };
  }
}
