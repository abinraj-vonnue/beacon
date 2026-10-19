import type { FastifyPluginAsync } from "fastify";
import { getPublicStatus } from "./public-status.service.js";

export const publicStatusRoutes: FastifyPluginAsync = async (app) => {
  app.get("/public/status", async (request, reply) => {
    reply.header("Cache-Control", "no-store");

    try {
      return await getPublicStatus();
    } catch (error) {
      request.log.error({ err: error }, "Failed to load public status");

      return reply.code(503).send({
        status: "unknown",
        generated_at: new Date().toISOString(),
        monitors: [],
        error: "Status data is temporarily unavailable.",
      });
    }
  });
};
