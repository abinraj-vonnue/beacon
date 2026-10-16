import { FastifyPluginAsync } from "fastify";
import { authenticateApiKey } from "../../plugins/authenticate-api-keys.js";

import * as monitorController from "./monitor.controller.js";

export const monitorRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("preHandler", authenticateApiKey);

  app.post("/monitors", monitorController.createMonitor);
  app.get("/monitors", monitorController.listMonitors);

  app.get<{ Params: { id: string } }>(
    "/monitors/:id",
    monitorController.getMonitor,
  );

  app.patch<{ Params: { id: string } }>(
    "/monitors/:id",
    monitorController.updateMonitor,
  );

  app.delete<{ Params: { id: string } }>(
    "/monitors/:id",
    monitorController.deleteMonitor,
  );
};
