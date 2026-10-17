# Beacon Server Setup Runbook

## Purpose

Provision an Ubuntu server for Beacon using the idempotent bootstrap script.

The script installs Docker Engine and the Compose plugin, configures Docker
log rotation, provisions the `deploy` account, hardens SSH, configures UFW,
installs the systemd units, and starts Beacon.

## Prerequisites

- A supported Ubuntu server with network access to Ubuntu and Docker package repositories.
- Root access or an account with `sudo`.
- The Beacon repository checked out on the server.
- A valid Beacon `.env` file prepared manually.
- A public SSH key for `deploy`, either already installed or supplied to the script.

## 1. Prepare the repository and environment

From the repository root, create `.env` only if it does not already exist:

```bash
if [ ! -e .env ]; then
  cp .env.example .env
fi
```

Edit `.env` and set the required production values, including a strong,
unique database password. Do not overwrite a previously prepared environment
file by copying the example over it.

Set restrictive permissions and verify Git handling:

```bash
chmod 600 .env
if ! git check-ignore -q .env; then
  echo ".env is not ignored by Git; stop and fix the ignore rules." >&2
  exit 1
fi

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  echo ".env is tracked by Git; stop and remove it from version control safely." >&2
  exit 1
fi
```

If `.env` already exists in `/opt/beacon`, the bootstrap script preserves it.
Review that file separately when changing production configuration.

Never commit production secrets.

## 2. Prepare SSH access

If the `deploy` account needs a public key, provide its public-key file when
running the script. The private key must remain on the administrator's machine.

If no key file is supplied, the script requires at least one valid public key
in `/home/deploy/.ssh/authorized_keys`. It checks the key file with
`ssh-keygen` and aborts before changing SSH authentication settings if no
usable key is present.

The script validates the supplied public key and appends missing key lines
without intentionally duplicating existing entries.

## 3. Validate the script

From the repository root:

```bash
bash -n deploy/scripts/bootstrap-server.sh
python3 -m json.tool deploy/docker/daemon.json >/dev/null
git diff --check
```

Inspect the script and confirm the environment values are correct before
running it.

## 4. Run bootstrap

With a public key:

```bash
sudo ./deploy/scripts/bootstrap-server.sh /path/to/deploy.pub
```

If the `deploy` account already has a working public key installed:

```bash
sudo ./deploy/scripts/bootstrap-server.sh
```

The script must run as root. It is designed to be rerun without replacing an
existing `/opt/beacon/.env`.

Before enabling UFW, the script reads active `ssh.socket` TCP listeners when
socket activation is running; otherwise it reads the effective SSH port from
`sshd -T`. It allows each discovered TCP port. Confirm the configured port
with `sudo systemctl show --property=Listen --value ssh.socket` for an active
socket, or `sudo sshd -T | grep '^port '` otherwise. Check the resulting
firewall rule with `sudo ufw status verbose`.

The Docker daemon configuration is updated only when its desired settings
differ. Existing unrelated daemon settings are preserved, and Docker is
restarted only when the configuration changed while the daemon was active.

## 5. Verify SSH access before closing the current session

Keep the current administrative session open. From a second terminal, test:

```bash
ssh deploy@SERVER_IP
```

Use the corresponding private key if SSH does not select it automatically.

Only close the original session after the new login succeeds. Root SSH login,
password authentication, and keyboard-interactive authentication are disabled
by the hardening configuration.

If the new login fails, use the still-open session or the VM/provider console
to diagnose the issue.

## 6. Verify the deployment

On the server:

```bash
sudo systemctl status docker.service --no-pager
sudo systemctl status beacon.service --no-pager
sudo systemctl status beacon-prune.timer --no-pager
sudo systemctl list-timers --all | grep beacon-prune
```

Check API readiness locally:

```bash
curl -fsS http://127.0.0.1:3000/readyz
```

Check listening sockets:

```bash
sudo ss -tlnp
```

Check firewall status:

```bash
sudo ufw status verbose
```

Check Docker logging configuration:

```bash
sudo cat /etc/docker/daemon.json
```

Check environment-file ownership and permissions:

```bash
sudo stat -c '%U:%G %a %n' /opt/beacon/.env
```

The expected environment-file mode is `600`, owned by `deploy`.

## 7. Network exposure

- SSH is allowed through UFW.
- The API is published on `127.0.0.1:3000`, not on all interfaces.
- PostgreSQL is not published to the host network.
- Do not add UFW rules opening ports `3000` or `5432`.

Docker-published ports can bypass UFW filtering because Docker manages its own
networking rules. Binding the API to loopback and not publishing PostgreSQL
are important exposure controls. See
`docs/adr/0003-bind-published-ports-to-localhost.md`.

## 8. Operational notes

Manage Beacon through systemd:

```bash
sudo systemctl status beacon.service
sudo systemctl restart beacon.service
sudo journalctl -u beacon.service -f
```

Do not use `make up` or `make down` while systemd owns the Compose stack.

The `deploy` account belongs to the `docker` group. Docker-group membership
effectively grants root-level privileges. Log out and back in before
expecting a new group membership to apply.

The weekly prune timer removes unused Docker images older than seven days.
Inspect the service journal when investigating a prune operation:

```bash
sudo journalctl -u beacon-prune.service
```

## Recovery

If SSH access fails after hardening, do not close the working session.
Use the existing session or VM/provider console to inspect:

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
sudo systemctl status ssh --no-pager
sudo journalctl -u ssh --since today
```

Correct the configuration and validate it with `sshd -t` before reloading SSH.
