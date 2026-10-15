import { fileURLToPath } from "node:url";
import { pool } from "./db";
import { readdir, readFile } from "node:fs/promises";

const migrationsDirectory = fileURLToPath(
  new URL("../migrations/", import.meta.url),
);

const LOCK_ID = 20261015;

async function migrate(): Promise<void> {
  const client = await pool.connect();
  let lockAcquired = false;
  try {
    await client.query("SELECT pg_advisory_lock($1)", [LOCK_ID]);
    lockAcquired = true;

    await client.query(
      `CREATE TABLE IF NOT EXISTS schema_migrations (
        name TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )`,
    );
    const files = (await readdir(migrationsDirectory))
      .filter((file) => /^\d+_[a-z0-9_-]+\.sql$/.test(file))
      .sort();

    for (const file of files) {
      const { rows } = await client.query(
        "SELECT 1 FROM schema_migrations WHERE name = $1",
        [file],
      );
      if (rows.length > 0) {
        console.log(`Skipping applied migrations : ${file}`);
        continue;
      }
      const sql = await readFile(
        new URL(`../migrations/${file}`, import.meta.url),
        "utf8",
      );
      await client.query("BEGIN");
      try {
        await client.query(sql);
        await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [
          file,
        ]);
        await client.query("COMMIT");
        console.log(`Applied migration: ${file}`);
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      }
    }
    console.log("Migrations complete");
  } finally {
    if (lockAcquired) {
      await client.query("SELECT pg_advisory_unlock($1)", [LOCK_ID]);
    }
    client.release();
    await pool.end();
  }
}
migrate().catch((error: unknown) => {
  console.error("Migration failed:", error);
  process.exitCode = 1;
});
