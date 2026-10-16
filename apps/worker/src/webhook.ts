import { config } from "./db.js";
import type { ClaimedMonitor } from "./monitor-claim.js";

export type IncidentEvent = "opened" | "resolved";

export type IncidentWebhookPayload = {
  event: IncidentEvent;
  monitor: {
    id: string;
    name: string;
    url: string;
  };
  occurredAt: string;
};
export async function sendIncidentWebhook(
  event: IncidentEvent,
  monitor: ClaimedMonitor,
): Promise<void> {
  const webhookUrl = config.WEBHOOK_URL;

  if (!webhookUrl) {
    return;
  }
  const payload: IncidentWebhookPayload = {
    event,
    monitor: {
      id: monitor.id,
      name: monitor.name,
      url: monitor.url,
    },
    occurredAt: new Date().toISOString(),
  };

  try {
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) {
      console.error("Incident webhook returned an unsuccessful status", {
        event,
        monitorId: monitor.id,
        status: response.status,
      });
    }
    await response.body?.cancel();
  } catch (error) {
    console.error("Incident webhook delivery failed", {
      event,
      monitorId: monitor.id,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}
