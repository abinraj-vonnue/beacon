import { FastifyReply, FastifyRequest } from "fastify";
import * as monitorService from "./monitor.service";
import {
  createMonitorSchema,
  monitorIdSchema,
  updateMonitorSchema,
} from "./monitor.schema";

type MonitorParams = { id: string };

function sendValidationError(reply: FastifyReply, message: string) {
  return reply.code(400).send({
    error: "Bad Request",
    message,
  });
}

export async function createMonitor(
  request: FastifyRequest,
  reply: FastifyReply,
) {
  const parsed = createMonitorSchema.safeParse(request.body);

  if (!parsed.success) {
    return sendValidationError(
      reply,
      parsed.error.issues.map((issue) => issue.message).join("; "),
    );
  }
  const monitor = await monitorService.createMonitor(parsed.data);
  return reply.code(201).send(monitor);
}

export async function listMonitors(
  _request: FastifyRequest,
  reply: FastifyReply,
) {
  const monitors = await monitorService.listMonitors();
  return reply.send(monitors);
}

export async function getMonitor(
  request: FastifyRequest<{ Params: MonitorParams }>,
  reply: FastifyReply,
) {
  const parsed = monitorIdSchema.safeParse(request.params);

  if (!parsed.success) {
    return sendValidationError(reply, "Monitor ID must be a valid UUID");
  }

  const monitor = await monitorService.getMonitor(parsed.data.id);

  if (!monitor) {
    return reply.code(404).send({ error: "Monitor not found" });
  }

  return reply.send(monitor);
}

export async function updateMonitor(
  request: FastifyRequest<{ Params: MonitorParams }>,
  reply: FastifyReply,
) {
  const parsedId = monitorIdSchema.safeParse(request.params);

  if (!parsedId.success) {
    return sendValidationError(reply, "Monitor ID must be a valid UUID");
  }

  const parsedBody = updateMonitorSchema.safeParse(request.body);

  if (!parsedBody.success) {
    return sendValidationError(
      reply,
      parsedBody.error.issues.map((issue) => issue.message).join("; "),
    );
  }

  const monitor = await monitorService.updateMonitor(
    parsedId.data.id,
    parsedBody.data,
  );

  if (!monitor) {
    return reply.code(404).send({ error: "Monitor not found" });
  }

  return reply.send(monitor);
}

export async function deleteMonitor(
  request: FastifyRequest<{ Params: MonitorParams }>,
  reply: FastifyReply,
) {
  const parsed = monitorIdSchema.safeParse(request.params);

  if (!parsed.success) {
    return sendValidationError(reply, "Monitor ID must be a valid UUID");
  }

  const deleted = await monitorService.deleteMonitor(parsed.data.id);

  if (!deleted) {
    return reply.code(404).send({ error: "Monitor not found" });
  }

  return reply.code(204).send();
}
