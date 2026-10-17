# Beacon Learning Log

## Phase 0 — Baseline Application and Docker

### 2026-10-17 — Task 8: Project onboarding and milestone preparation

#### What I learned

- An npm workspaces monorepo allows the API, worker, and shared package to
  share dependency management while keeping their responsibilities separate.
- Native ESM requires runtime-compatible import paths in the TypeScript output.
- Database migrations should run before application services depend on the
  resulting schema.
- Container health checks distinguish a running process from a service that
  is ready to handle requests.
- Graceful shutdown allows an application to close its server and database
  connections cleanly.
- Docker named volumes preserve database data independently of container
  lifecycles.
- API keys should be stored as hashes, with plaintext keys displayed only
  when generated.
- Incident state changes should be explicit: Beacon opens an incident after
  three consecutive failed checks and resolves it after recovery.

#### Docker and operational lessons

- Multi-stage builds separate build-time dependencies from the runtime image.
- Running as a non-root user and using a read-only root filesystem reduce
  container privileges.
- Resource limits constrain container CPU and memory consumption.
- Compose dependency conditions help coordinate database readiness,
  migrations, and application startup.
- Image size is an operational trade-off that should be measured rather than
  assumed to meet a target.

#### Known deviation

The API and worker images are approximately 268 MB each. This exceeds the
roadmap's approximate 200 MB target by about 68 MB per image. The containers
are functionally verified, but the image-size target is not met.

Image optimization remains a follow-up task; the current images are not
being reported as meeting the target.

#### Remaining work

- Complete the automated testing task deferred as Task 6, including
  PostgreSQL integration and concurrency coverage.
- Revisit application image size and measure any optimization.
- Improve webhook delivery reliability with durable retries.
- Add authenticated endpoint monitoring in a later phase.

#### Verification status

The API and worker containers, Compose startup, migrations, health checks,
incident transitions, graceful shutdown, and PostgreSQL persistence were
verified during Task 7.

Task 8 documentation and Makefile changes must be verified from a clean
checkout before the `v0.1` milestone is published.
