import { pool } from "../db.js";

const TABLES = ["check_results", "incidents", "monitors", "api_keys"];

async function resetDatabase(): Promise<void> {
  if (
    process.env.NODE_ENV === "production" &&
    process.env.ALLOW_DB_RESET !== "true"
  ) {
    throw new Error(
      "Database reset blocked in production. Explicit authorization required.",
    );
  }

  console.log("Resetting application data...");

  await pool.query(`
    TRUNCATE TABLE ${TABLES.join(", ")}
    RESTART IDENTITY;
  `);

  console.log("Database reset completed successfully.");
  console.log(`Cleared tables: ${TABLES.join(", ")}`);
}

try {
  await resetDatabase();
} catch (error) {
  console.error("Database reset failed:", error);
  process.exitCode = 1;
} finally {
  await pool.end();
}
