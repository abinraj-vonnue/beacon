# Beacon

Beacon is a self-hosted HTTP monitoring service built with Node.js, TypeScript,
Fastify, PostgreSQL, and Docker Compose.

It provides an API for managing HTTP monitors and a background worker that
checks monitored endpoints and tracks incidents.

## Features

- Create, list, retrieve, update, and delete monitors.
- Validate monitor configuration and restrict URLs to HTTP or HTTPS.
- Authenticate monitor API requests with generated API keys.
- Store API-key hashes rather than plaintext keys.
- Run scheduled HTTP checks using a background worker.
- Open incidents after three consecutive failed checks.
- Resolve open incidents after a successful check.
- Persist data in PostgreSQL.
- Run the API and worker as non-root Docker containers with read-only
  root filesystems and resource limits.

## Architecture

- `apps/api` — Fastify HTTP API and SQL migrations.
- `apps/worker` — Background monitor-checking worker.
- `packages/shared` — Shared incident-state logic.
- `compose.yaml` — PostgreSQL, migrations, API, worker, and HTTP test target.
- `docs/adr` — Architecture decision records.

Beacon uses an npm workspaces monorepo and native ECMAScript modules.

## Prerequisites

For the Docker quickstart:

- Git
- Docker Engine
- Docker Compose v2

For local TypeScript builds and tests, also install Node.js 24 and npm.

## Quickstart

### 1. Clone the repository

```bash
git clone https://github.com/abinraj-vonnue/beacon.git
cd beacon
```

### 2. Configure the environment

```bash
cp .env.example .env
```

The example contains a development-only PostgreSQL password.
Change it before using the deployment outside a local development environment.

Do not commit `.env` or put real credentials in `.env.example`.

`DATABASE_URL` in the example uses `localhost` for applications run directly
on your host. Docker Compose sets the API and worker connection separately,
using the `db` service name inside the Compose network.

### 3. Start Beacon

```bash
make up
```

This builds the API and worker images, starts PostgreSQL, applies pending
migrations, and starts the application services.

Check service status and logs:

```bash
make ps
make logs
```

### 4. Check API health

```bash
curl http://localhost:3000/healthz
curl http://localhost:3000/readyz
```

`/healthz` checks whether the API process responds.
`/readyz` also checks database connectivity.

### 5. Create an API key

Generate a key inside the running API container:

```bash
docker compose --env-file .env -f compose.yaml exec api \
  node apps/api/dist/create-api-key.js "local development"
```

Copy the generated key and store it securely. The plaintext key is shown only
when it is created.

### 6. Create a monitor

Replace `YOUR_API_KEY` with the generated key:

```bash
curl --fail-with-body \
  -X POST http://localhost:3000/monitors \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Example website",
    "url": "https://example.com",
    "interval_seconds": 60,
    "timeout_ms": 5000,
    "expected_status_code": 200
  }'
```

The monitor interval must be between 30 and 3600 seconds. The timeout must be
between 100 and 60000 milliseconds. The expected HTTP status code must be
between 100 and 599.

### 7. List monitors

```bash
curl --fail-with-body \
  http://localhost:3000/monitors \
  -H "Authorization: Bearer YOUR_API_KEY"
```

Monitor endpoints require a valid API key:

- `POST /monitors` — Create a monitor.
- `GET /monitors` — List monitors.
- `GET /monitors/:id` — Retrieve a monitor.
- `PATCH /monitors/:id` — Update a monitor.
- `DELETE /monitors/:id` — Delete a monitor.

## Development

Install dependencies:

```bash
npm ci
```

Build the API and worker:

```bash
make build
```

Run the existing worker tests:

```bash
make test
```

The current test command covers the worker's incident-state and worker-loop
tests. Full automated testing, including PostgreSQL integration and concurrency
coverage, remains planned work.

## Useful commands

| Command             | Purpose                                    |
| ------------------- | ------------------------------------------ |
| `make up`           | Build and start services                   |
| `make down`         | Stop services; preserve database data      |
| `make ps`           | Show service status                        |
| `make logs`         | Follow all service logs                    |
| `make restart`      | Restart API and worker                     |
| `make build`        | Build API and worker                       |
| `make test`         | Run existing worker tests                  |
| `make clean`        | Stop services and remove orphan containers |
| `make down-volumes` | Stop services and delete database volumes  |

## Configuration

The root `.env` file is used by Docker Compose.

- `POSTGRES_DB` — PostgreSQL database name.
- `POSTGRES_USER` — PostgreSQL username.
- `POSTGRES_PASSWORD` — PostgreSQL password.
- `LOG_LEVEL` — Application log level.
- `PORT` and `DATABASE_URL` — Local application configuration.

Compose supplies the database connection URL to the API and worker using the
database service name.

## Data persistence

PostgreSQL data is stored in the named `postgres_data` Docker volume.
Running `make down` preserves this data. Running `make down-volumes` removes
the volume and permanently deletes its data.

## Current limitations

- API and worker images are approximately 268 MB each, above the roadmap's
  approximate 200 MB target.
- Full automated testing is not complete.
- Incident webhook delivery is best effort; durable retries are not implemented.
- Authenticated endpoint monitoring is not yet implemented.

## Architecture decisions

See [ADR-0001: Initial Technology Stack](docs/adr/0001-tech-stack.md) and
[ADR-0002: npm Workspaces Monorepo](docs/adr/0002-monorepo.md).

## License

See [LICENSE](LICENSE).
