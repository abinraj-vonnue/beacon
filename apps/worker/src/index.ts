import { executeHttpCheck } from "./http-check";
import { claimDueMonitors } from "./monitor-claim";
import { processCheckResult } from "./process-check-result";

const monitors = await claimDueMonitors();
for (const monitor of monitors) {
  const result = await executeHttpCheck(monitor);

  await processCheckResult({
    monitor,
    result,
  });
}
