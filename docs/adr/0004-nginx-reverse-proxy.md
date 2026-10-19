# ADR-0004: Host-Level Nginx Reverse Proxy

- **Status:** Accepted
- **Date:** 2026-10-19

## Context

Beacon runs its API, background worker, and PostgreSQL database using Docker Compose on the `beacon-vm` Ubuntu server.

The API listens on port `3000` inside its container and is published on the VM through `127.0.0.1:3000`. PostgreSQL is not published on a host port.

Beacon needs an HTTP entry point that can later support hostname-based routing, TLS termination, security headers, and request rate limiting.

## Decision

Nginx will run directly on the Ubuntu VM host, outside Docker Compose, and act as the reverse proxy for the Beacon API.

Nginx will listen on HTTP port `80` and forward incoming requests to:

`http://127.0.0.1:3000`

The initial configuration will forward the original host, client address, forwarded address chain, and request scheme through proxy headers.

The Nginx configuration will be maintained in the repository at `deploy/nginx/beacon.conf` and enabled on the VM through `/etc/nginx/sites-available/` and `/etc/nginx/sites-enabled/`.

The API will remain bound to the VM's loopback interface. PostgreSQL will remain accessible through the Docker network without a published host port.

## Consequences

### Positive

- Nginx provides a single HTTP entry point for the API.
- The API does not need to be exposed directly on an external network interface.
- TLS termination, hostname routing, security headers, and rate limiting can be introduced at the proxy layer.
- Nginx configuration is version-controlled alongside the application.

### Trade-offs

- Nginx must be installed, configured, and maintained separately from Docker Compose.
- The host-level proxy introduces another service to monitor and troubleshoot.
- Proxy headers must be handled carefully by the API to avoid trusting spoofed client information.

## Follow-up

- Configure the `beacon.test` hostname and a locally trusted TLS certificate.
- Configure Fastify's trusted-proxy behavior, proxy timeouts, request body limits, and compression.
- Apply TLS hardening and security headers.
- Add rate limiting to write endpoints.
