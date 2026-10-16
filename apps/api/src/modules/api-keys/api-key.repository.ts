import { pool } from "../../db.js";

export async function insertApiKey(
  name: string,
  keyHash: string,
): Promise<void> {
  await pool.query(
    `INSERT INTO api_keys (name, key_hash)
    VALUES ($1,$2)`,
    [name, keyHash],
  );
}
export async function findActiveApiKey(keyHash: string): Promise<boolean> {
  const result = await pool.query(
    `SELECT id
    FROM api_keys
    WHERE key_hash = $1
    AND revoked_at IS NULL
    LIMIT 1`,
    [keyHash],
  );
  return result.rowCount !== null && result.rowCount > 0;
}
