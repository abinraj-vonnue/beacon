import { config } from "./config.js";
import Fastify from "fastify";
import { pool } from "./db.js";
import { authenticateApiKey } from "./plugins/authenticate-api-keys.js";
import { monitorRoutes } from "./modules/monitors/monitor.routes.js";

export function buildServer() {
  const app = Fastify({
    logger: {
      level: config.LOG_LEVEL,
    },
  });

  app.get("/healthz", async () => {
    return { status: "ok" };
  });

  app.get("/readyz", async (_request, reply) => {
    try {
      await pool.query("SELECT 1");
      return { status: "ready" };
    } catch (error) {
      app.log.error({ err: error }, "Database readiness check failed");

      return reply.code(503).send({
        status: "not_ready",
      });
    }
  });

  app.get("/protected", { preHandler: authenticateApiKey }, async () => ({
    status: "authenticated",
  }));

  app.register(monitorRoutes);

  return app;
}
