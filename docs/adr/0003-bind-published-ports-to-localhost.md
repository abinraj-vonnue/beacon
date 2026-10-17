# ADR-0003: Docker Port Binding and Host Exposure

- **Status:** Accepted
- **Date:** 2026-10-17

## Context

Beacon runs as a Docker Compose stack containing the API, worker, PostgreSQL database, migration service, and a test target.

During Phase 1 Task 5, PostgreSQL was temporarily published using `5432:5432`. A host-side Nmap scan against the VM (`10.27.55.34`) reported `5432/tcp` as `open`, despite UFW being enabled.

Docker configures its own packet-forwarding and NAT rules for published ports. Consequently, traffic to a published container port can follow a forwarding path that is not filtered by UFW's ordinary incoming rules in the same way as traffic destined for a service running directly on the host.

This demonstrated that UFW configuration alone is not sufficient to determine the exposure of Docker-published ports.

## Decision

- PostgreSQL will not publish a port to the VM host. The API, worker, and migration service will access it through the internal Compose network.
- The API will publish port 3000 only on the host's loopback interface using `127.0.0.1:3000:3000`.
- External access to the API will require an explicitly designed and secured ingress mechanism in a future deployment configuration.
- Docker port publishing and host firewall rules must be evaluated together when assessing network exposure.

## Consequences

### Positive

- PostgreSQL is not directly exposed through a published host port.
- The API is accessible locally within the VM without being directly published on its network interfaces.
- The configuration makes the intended network access boundary explicit and reduces accidental exposure.

### Trade-offs

- The API cannot be reached directly through the VM's network IP on port 3000.
- Remote access will require a deliberate ingress design, such as a reverse proxy or another controlled access mechanism.
- UFW rules alone should not be assumed to control every Docker-published port.

## Alternatives Considered

1. **Publish PostgreSQL on all interfaces:** Rejected because the host-side scan confirmed that port 5432 was reachable.
2. **Rely only on UFW:** Rejected because Docker's published-port traffic can follow NAT and forwarding paths that bypass the ordinary UFW incoming-filtering path.
3. **Bind the API to all interfaces:** Rejected for this lab because it would expose the API directly through the VM's network interfaces without an ingress layer.

## Verification

The following results were observed during Task 5:

- **Before the fix:** PostgreSQL was published as `5432:5432`, and a host-side Nmap scan reported `5432/tcp open`.
- **After the fix:** The host-side Nmap scan reported `5432/tcp filtered` and `3000/tcp closed`.
- **API readiness:** The readiness endpoint returned HTTP 200 from `http://127.0.0.1:3000/readyz` inside the VM.
- **Final Compose configuration:** PostgreSQL has no published host port, and the API is bound to `127.0.0.1:3000:3000`.
