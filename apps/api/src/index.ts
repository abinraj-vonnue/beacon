import { config } from "./config";
import { pool } from "./db";
import { buildServer } from "./server";

const app = buildServer();
try {
  await app.listen({
    port: config.PORT,
    host: "0.0.0.0",
  });
} catch (error) {
  app.log.error({ err: error }, "Failed to start API");
  await pool.end();
  process.exitCode = 1;
}

let shuttingDown = false;
async function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;

  app.log.info({ signal }, "Shutting down API");

  try {
    await app.close();
    await pool.end();
  } catch (error) {
    app.log.error({ err: error }, "Shutdown failed");
    process.exitCode = 1;
  }
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
