# Beacon Server Setup Runbook

## Purpose

Provision an Ubuntu server for Beacon using the idempotent bootstrap script.

The script installs Docker Engine, the Compose plugin and Nginx, configures
Docker log rotation, provisions the `deploy` account, hardens SSH, configures
UFW, installs the Beacon HTTPS site and public status page, installs the
systemd units, and starts Beacon.

## Prerequisites

- A supported Ubuntu server with network access to Ubuntu and Docker package repositories.
- Root access or an account with `sudo`.
- The Beacon repository checked out on the server.
- A valid Beacon `.env` file prepared manually.
- A public SSH key for `deploy`, either already installed or supplied to the script.
- The Beacon TLS certificate and private key available on the administrator's
  machine for transfer to the server. The script will not generate them.

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

The script validates every nonblank, noncomment line in the supplied file as
one public key. It rejects private-key blocks and invalid lines before writing
any supplied key to `authorized_keys`, then appends missing keys without
duplicating existing entries.

## 3. Transfer the TLS certificate and private key

Phase 2 Task 3 provisions the local `beacon.test` certificate. Before running
bootstrap, transfer those existing files from the administrator's machine to
the VM. Do not put either file in the repository. Keep the private-key file
restricted to the administrator on the source machine:

```bash
chmod 600 /path/to/beacon.test-key.pem
multipass transfer /path/to/beacon.test.pem beacon-vm:/home/ubuntu/beacon.test.pem
multipass transfer /path/to/beacon.test-key.pem beacon-vm:/home/ubuntu/beacon.test-key.pem

multipass exec beacon-vm -- sudo install -d -o root -g root -m 0755 /etc/ssl/beacon
multipass exec beacon-vm -- sudo install -o root -g root -m 0644 \
  /home/ubuntu/beacon.test.pem /etc/ssl/beacon/beacon.test.pem
multipass exec beacon-vm -- sudo install -o root -g root -m 0600 \
  /home/ubuntu/beacon.test-key.pem /etc/ssl/beacon/beacon.test-key.pem
multipass exec beacon-vm -- rm -f \
  /home/ubuntu/beacon.test.pem /home/ubuntu/beacon.test-key.pem
```

Confirm the files exist and have the intended ownership and permissions. Do
not print or display the private-key contents:

```bash
multipass exec beacon-vm -- sudo test -s /etc/ssl/beacon/beacon.test.pem
multipass exec beacon-vm -- sudo test -s /etc/ssl/beacon/beacon.test-key.pem
multipass exec beacon-vm -- sudo stat -c '%U:%G %a %n' \
  /etc/ssl/beacon/beacon.test.pem /etc/ssl/beacon/beacon.test-key.pem
```

Expected modes are `root:root 644` for the certificate and `root:root 600`
for the private key. Bootstrap checks both files before package installation,
then enforces these ownership and permission settings. If the files are
missing, repeat the Phase 2 Task 3 Multipass transfer before bootstrapping.

## 4. Validate the script

From the repository root:

```bash
bash -n deploy/scripts/bootstrap-server.sh
python3 -m json.tool deploy/docker/daemon.json >/dev/null
git diff --check
```

Inspect the script and confirm the environment values are correct before
running it.

## 5. Run bootstrap

With a public key:

```bash
sudo ./deploy/scripts/bootstrap-server.sh /path/to/deploy.pub
```

If the `deploy` account already has a working public key installed:

```bash
sudo ./deploy/scripts/bootstrap-server.sh
```

The script must run as root. It validates the environment file, repository
inputs, deploy key, Ubuntu platform, and TLS files before system changes. The
TLS preflight parses the certificate and unencrypted private key with OpenSSL,
rejects expired certificates, and verifies that both contain the same public
key. It does not replace an existing `/opt/beacon/.env`. If UFW is already
installed, the script stops an already active Nginx service, then immediately
discovers SSH listeners, removes explicit protocol-free and `/tcp` allow rules
for ports `80`, `443`, `3000`, and `5432` (including repeated entries), allows the
discovered SSH ports, sets the default policies, and enables UFW. If UFW is
absent, it stops an already active Nginx service, installs the base
prerequisites, and then runs that same firewall preparation before installing
Nginx. Neither path allows HTTP or HTTPS during firewall preparation. If
preparation fails, Nginx stays stopped so an inactive or partially configured
firewall cannot leave the web service reachable.

Nginx is installed only after UFW is enabled, so its package's default site
cannot be reached through the script-managed web ports. The script installs
the tracked Nginx site and rate-limit configuration, publishes `web/status/`
under `/var/www/beacon/`, validates with `nginx -t`, then starts or reloads
Nginx. After the existing systemd setup and Beacon service start both Nginx
and Beacon are confirmed active, it requests the status page and `/readyz`
through the local HTTPS listener. Only after both checks succeed does it add
`80/tcp` and `443/tcp`. If a step after cleanup fails, the script leaves those
managed rules closed; if either final allow operation fails, it attempts to
remove both rules before exiting. The status directory is synchronized
idempotently.

Unrelated existing UFW rules are preserved. Review `sudo ufw status numbered`
on an existing host; additional allow rules may expose ports beyond the
Beacon-managed set. A failed preflight exits without changing UFW, so existing
rules remain as they were until preflight succeeds and bootstrap can perform
the cleanup. If UFW's added-rule output is unrecognized or cannot be read, the
script stops with an error instead of attempting to edit the firewall.

Before enabling UFW, the script reads active `ssh.socket` TCP listeners when
socket activation is running; otherwise it reads the effective SSH port from
`sshd -T`. It allows each discovered TCP port before setting the deny-incoming
policy. Confirm the configured port with
`sudo systemctl show --property=Listen --value ssh.socket` for an active
socket, or `sudo sshd -T | grep '^port '` otherwise. Check the resulting
firewall rules with `sudo ufw status verbose`.

The Docker daemon configuration is updated only when its desired settings
differ. Existing unrelated daemon settings are preserved, and Docker is
restarted only when the configuration changed while the daemon was active.

## 6. Verify SSH access before closing the current session

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

## 7. Verify the deployment

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

Validate Nginx and its service:

```bash
sudo nginx -t
sudo systemctl status nginx.service --no-pager
```

Check HTTPS and the public status page from the VM, using the local TLS
certificate for this development hostname:

```bash
curl -kfsS --resolve beacon.test:443:127.0.0.1 https://beacon.test/
curl -kfsS --resolve beacon.test:443:127.0.0.1 https://beacon.test/readyz
```

The first request should return the Beacon status page; the second should
return the API readiness response through Nginx.

Check listening sockets:

```bash
sudo ss -tlnp
```

Check firewall status:

```bash
sudo ufw status verbose
```

On a fresh VM using the standard SSH port, the final inbound TCP allow rules
should be `22`, `80`, and `443`. On an existing host, separately review and
preserve unrelated rules instead of assuming these are the only allowed
ports. Confirm the API remains loopback-only and Nginx listens on the public
web ports:

```bash
sudo ufw status numbered
sudo ss -ltnp
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

## 8. Network exposure

- SSH is allowed through UFW.
- The API is published on `127.0.0.1:3000`, not on all interfaces.
- PostgreSQL is not published to the host network.
- UFW allows HTTP and HTTPS on ports `80` and `443` only after Nginx and Beacon
  are active. It removes explicit `3000/tcp`, `80/tcp`, and `443/tcp` rules
  during reconfiguration, including repeated rules.
- The bootstrap does not open ports `3000` or `5432`; its cleanup removes an
  existing explicit `5432/tcp` rule as well.
- Do not add UFW rules opening ports `3000` or `5432`.

Docker-published ports can bypass UFW filtering because Docker manages its own
networking rules. Binding the API to loopback and not publishing PostgreSQL
are important exposure controls. See
`docs/adr/0003-bind-published-ports-to-localhost.md`.

From a machine outside the VM, verify ports `3000` and `5432` are not
reachable. If Nmap is available, they should be reported closed or filtered,
not open:

```bash
nmap -Pn -p 3000,5432 SERVER_IP
```

On the administrator's laptop, map `beacon.test` to the current VM address in
the hosts file (for example, `/etc/hosts` on Linux or macOS). If a rebuilt VM
receives a different IP address, update that mapping before testing:

```text
SERVER_IP beacon.test
```

Then verify from the laptop with `curl -kI https://beacon.test/` and open
`https://beacon.test/` in a browser. The `-k` option is for this local
development certificate; use the Phase 2 Task 3 trust procedure if the local
certificate authority has been installed on the client.

## 9. Operational notes

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
