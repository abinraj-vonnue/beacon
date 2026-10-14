# ADR-0002: npm Workspaces Monorepo

- **Status:** Accepted
- **Date:** 2026-10-14

## Context
Beacon contains an API, a background worker, and shared code. These components need coordinated dependency management and consistent tooling.

## Decision
Use an npm workspaces monorepo, with separate packages for the API, worker, and shared code.

## Consequences
- Shared types and database utilities can live in one package.
- Dependencies and scripts can be managed from the repository root.
- Components remain separately buildable and deployable.
- The repository requires clear package boundaries and scripts.

## Alternatives
- **Separate repositories:** Rejected for now because the project is small and its components share code.
- **A single application package:** Rejected because the API and worker have different runtime responsibilities.
