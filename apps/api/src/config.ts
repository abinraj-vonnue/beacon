import dotenv from "dotenv";
import { z } from "zod";

dotenv.config({ path: "../../.env" });

const configSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATABASE_URL: z.string().min(1),
  LOG_LEVEL: z
    .enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
    .default("info"),
});

export const config = configSchema.parse(process.env);
