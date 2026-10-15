import { createHash, randomBytes } from "node:crypto";
import { findActiveApiKey, insertApiKey } from "./api-key.repository";

function hashApiKey(apiKey: string): string {
  return createHash("sha256").update(apiKey).digest("hex");
}
export async function createApiKey(name: string): Promise<string> {
  const apiKey = randomBytes(32).toString("hex");

  await insertApiKey(name, hashApiKey(apiKey));

  return apiKey;
}
export async function isApiKeyActive(apiKey: string): Promise<boolean> {
  return findActiveApiKey(hashApiKey(apiKey));
}
