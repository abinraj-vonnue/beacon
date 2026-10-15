import { pool } from "./db";
import { createApiKey } from "./modules/api-keys/api-key.service";

const name = process.argv[2]?.trim();

if (!name) {
  console.error(`Usage: npm run create-api-key -- "local development"`);
  process.exitCode = 1;
} else {
  try {
    const apiKey = await createApiKey(name);
    console.log("\nAPI key created. Copy it now , it wont be shown again\n");
    console.log(apiKey);
  } catch (error) {
    console.error("Failed to create API key", error);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
}
