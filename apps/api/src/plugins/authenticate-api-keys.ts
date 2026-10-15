import type { FastifyReply, FastifyRequest } from "fastify";
import { isApiKeyActive } from "../modules/api-keys/api-key.service.js";

export async function authenticateApiKey(
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<void> {
  const authorization = request.headers.authorization;
  const match = authorization?.match(/^Bearer\s+(\S+)$/i);

  if (!match) {
    return reply.code(401).send({ error: "Unauthorized" });
  }

  const active = await isApiKeyActive(match[1]);

  if (!active) {
    return reply.code(401).send({ error: "Unauthorized" });
  }
}
