# ADR-0001: Initial Technology Stack

- **Status:** Accepted
- **Date:** 2026-10-14

## Context
Beacon needs a maintainable API and background worker backed by persistent storage.

## Decision
Use Node.js, TypeScript, Fastify, and PostgreSQL.

## Consequences
- TypeScript provides static type checking.
- Fastify provides a lightweight HTTP framework.
- PostgreSQL stores monitors, check results, incidents, and API-key hashes.
- The team must maintain application code and database migrations.

## Alternatives
- **JavaScript:** Rejected in favor of TypeScript's static type checking.
- **Another HTTP framework:** Fastify is selected for its lightweight design.
- **Another database:** PostgreSQL is selected as the relational database for Beacon's data.
