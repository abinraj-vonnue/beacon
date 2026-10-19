import { config } from "./config.js";
import Fastify from "fastify";
import { pool } from "./db.js";
import { authenticateApiKey } from "./plugins/authenticate-api-keys.js";
import { monitorRoutes } from "./modules/monitors/monitor.routes.js";
import { publicStatusRoutes } from "./modules/public-status/public-status.routes.js";

export function buildServer() {
  const app = Fastify({
    logger: {
      level: config.LOG_LEVEL,
    },
    trustProxy: config.TRUSTED_PROXY_IP ? [config.TRUSTED_PROXY_IP] : false,

    bodyLimit: 1024 * 1024,
    requestTimeout: 15_000,
  });
  app.addHook("onRequest", (request, _reply, done) => {
    request.log.info(
      {
        clientIp: request.ip,
        proxyPeerIp: request.raw.socket.remoteAddress,
        protocol: request.protocol,
      },
      "Request recieved",
    );
    done();
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

  app.register(publicStatusRoutes);
  app.register(monitorRoutes);

  return app;
}
