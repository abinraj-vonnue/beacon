import dotenv from "dotenv";
import { z } from "zod";

dotenv.config({ path: "../../.env" });
const trustedProxyIpSchema = z.preprocess(
  (value) =>
    typeof value === "string" && value.trim() === "" ? undefined : value,
  z.union([z.ipv4(), z.ipv6()]).optional(),
);

const configSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATABASE_URL: z.string().min(1),
  LOG_LEVEL: z
    .enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
    .default("info"),
  TRUSTED_PROXY_IP: trustedProxyIpSchema,
});

export const config = configSchema.parse(process.env);
