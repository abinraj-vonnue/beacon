import assert from "node:assert/strict";
import test from "node:test";
import type { ClaimedMonitor } from "./monitor-claim.js";
import { processBatch } from "./worker-loop.js";

const monitor: ClaimedMonitor = {
  id: "monitor-1",
  name: "Example",
  url: "https://example.com",
  interval_seconds: 60,
  timeout_ms: 60_000,
  expected_status_code: 200,
  next_check_at: new Date("2026-01-01T00:00:00Z"),
};

test("processes one leased monitor and reschedules it after persistence fails", async () => {
  const events: string[] = [];
  let claimedBatchSize = 0;
  let leaseSeconds = 0;

  await processBatch({
    claimDueMonitors: async (batchSize, requestedLeaseSeconds) => {
      claimedBatchSize = batchSize;
      leaseSeconds = requestedLeaseSeconds;
      return [monitor];
    },
    executeHttpCheck: async () => {
      events.push("check");
      return {
        ok: false,
        statusCode: null,
        latencyMs: 60_000,
        error: "timeout",
      };
    },
    processCheckResult: async () => {
      events.push("persist");
      throw new Error("database unavailable");
    },
    rescheduleAfterFailure: async (monitorId) => {
      events.push(`retry:${monitorId}`);
    },
    logger: { info() {}, error() {} },
  });

  assert.equal(claimedBatchSize, 1);
  assert.ok(leaseSeconds * 1_000 > monitor.timeout_ms);
  assert.deepEqual(events, [
    "check",
    "persist",
    "retry:monitor-1",
  ]);
});

test("does not retry when a failed HTTP check is successfully persisted", async () => {
  const events: string[] = [];

  await processBatch({
    claimDueMonitors: async () => {
      return [monitor];
    },
    executeHttpCheck: async () => ({
      ok: false,
      statusCode: 503,
      latencyMs: 12,
      error: "Expected HTTP 200, received 503",
    }),
    processCheckResult: async () => {
      events.push("persist");
    },
    rescheduleAfterFailure: async () => {
      events.push("retry");
    },
    logger: { info() {}, error() {} },
  });

  assert.deepEqual(events, ["persist"]);
});
