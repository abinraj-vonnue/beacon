import dotenv from "dotenv";
import pg from "pg";
import { z } from "zod";

dotenv.config({ path: "../../.env" });

const configSchema = z.object({
  DATABASE_URL: z.string().min(1),
});

const config = configSchema.parse(process.env);

export const pool = new pg.Pool({
  connectionString: config.DATABASE_URL,
  connectionTimeoutMillis: 5_000,
  application_name: "beacon-worker",
});

pool.on("error", (error: Error) => {
  console.error("Unexpected idle database client error", {
    message: error.message,
  });
});
