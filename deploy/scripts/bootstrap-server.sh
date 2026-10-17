
#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap an Ubuntu server for Beacon.
# Run as root from a checked-out Beacon repository.
#
# Usage:
#   sudo ./deploy/scripts/bootstrap-server.sh [deploy-public-key-file]
#
# If no key file is supplied, an existing deploy user's authorized_keys
# must already be configured.

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DEPLOY_USER="deploy"
readonly DEPLOY_DIR="/opt/beacon"
readonly SSH_HARDENING="/etc/ssh/sshd_config.d/99-beacon-hardening.conf"
readonly DOCKER_CONFIG="/etc/docker/daemon.json"

log() {
  printf '[beacon-bootstrap] %s\n' "$*"
}

die() {
  printf '[beacon-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo or as root."
[[ -f "$REPO_ROOT/compose.yaml" ]] || die "compose.yaml not found at $REPO_ROOT."
[[ -f "$REPO_ROOT/deploy/systemd/beacon.service" ]] ||
  die "Beacon systemd unit is missing."
[[ -f "$REPO_ROOT/deploy/systemd/beacon-prune.service" ]] ||
  die "Prune service unit is missing."
[[ -f "$REPO_ROOT/deploy/systemd/beacon-prune.timer" ]] ||
  die "Prune timer unit is missing."
[[ -f "$REPO_ROOT/deploy/docker/daemon.json" ]] ||
  die "Docker daemon configuration is missing."

PUBLIC_KEY_FILE="${1:-}"

if [[ -n "$PUBLIC_KEY_FILE" ]]; then
  [[ -f "$PUBLIC_KEY_FILE" ]] || die "Public key file not found: $PUBLIC_KEY_FILE"
  [[ -s "$PUBLIC_KEY_FILE" ]] || die "Public key file is empty."
fi

# A fresh deployment needs a manually prepared .env file.
# Never overwrite the existing production environment file.
if [[ ! -f "$DEPLOY_DIR/.env" && ! -f "$REPO_ROOT/.env" ]]; then
  die "No .env found. Prepare one in the repository before bootstrapping."
fi

log "Installing required Ubuntu packages."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  openssh-server \
  rsync \
  python3 \
  ufw

log "Creating the deploy user if necessary."
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0750 \
  "/home/$DEPLOY_USER/.ssh"

if [[ -n "$PUBLIC_KEY_FILE" ]]; then
  log "Installing the supplied public key for $DEPLOY_USER."
  touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chmod 0600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" \
    "/home/$DEPLOY_USER/.ssh/authorized_keys"

  # Append only if this exact public key is not already present.
  if ! grep -Fqx -f "$PUBLIC_KEY_FILE" \
      "/home/$DEPLOY_USER/.ssh/authorized_keys"; then
    cat "$PUBLIC_KEY_FILE" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
  fi
fi

log "Installing Docker from the official Docker Ubuntu repository."
. /etc/os-release
[[ "$ID" == "ubuntu" ]] || die "This script supports Ubuntu only."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
Architectures: $(dpkg --print-architecture)
EOF

apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

log "Configuring Docker log rotation."
install -d -m 0755 /etc/docker
install -m 0644 "$REPO_ROOT/deploy/docker/daemon.json" "$DOCKER_CONFIG"
python3 -m json.tool "$DOCKER_CONFIG" >/dev/null

systemctl enable --now docker
systemctl restart docker

# The Docker group grants effectively root-level privileges.
# Add deploy only after Docker has created the group.
getent group docker >/dev/null || groupadd docker
usermod -aG docker "$DEPLOY_USER"

log "Preparing the deployment directory."
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0750 "$DEPLOY_DIR"

# Preserve a previously provisioned .env file.
if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
  install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0600 \
    "$REPO_ROOT/.env" "$DEPLOY_DIR/.env"
fi

# Synchronize application files without deleting existing server files.
# Keep secrets, Git metadata, and installed dependencies out of the sync.
rsync -a \
  --exclude='.env' \
  --exclude='.git/' \
  --exclude='node_modules/' \
  --exclude='**/node_modules/' \
  --chown="$DEPLOY_USER:$DEPLOY_USER" \
  "$REPO_ROOT/" "$DEPLOY_DIR/"

chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR/.env"
chmod 0600 "$DEPLOY_DIR/.env"

log "Installing systemd units."
install -m 0644 "$DEPLOY_DIR/deploy/systemd/beacon.service" \
  /etc/systemd/system/beacon.service
install -m 0644 "$DEPLOY_DIR/deploy/systemd/beacon-prune.service" \
  /etc/systemd/system/beacon-prune.service
install -m 0644 "$DEPLOY_DIR/deploy/systemd/beacon-prune.timer" \
  /etc/systemd/system/beacon-prune.timer

log "Configuring UFW."
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH

# Do not open ports 3000 or 5432.
# Beacon publishes its API on loopback and does not publish PostgreSQL.
ufw --force enable

log "Hardening SSH."
install -d -m 0755 /etc/ssh/sshd_config.d

cat > "$SSH_HARDENING" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

# Do not reload SSH with an invalid configuration.
sshd -t
systemctl reload ssh

log "Enabling Beacon and the prune timer."
systemctl daemon-reload
systemctl enable docker.service
systemctl enable beacon.service
systemctl enable --now beacon-prune.timer
systemctl restart beacon.service

log "Bootstrap completed. Verify SSH access in a second terminal."
log "Check: systemctl status beacon.service"
log "Check: systemctl list-timers --all | grep beacon-prune"
log "Check readiness locally: curl -fsS http://127.0.0.1:3000/readyz"
log "Remember: new docker-group membership applies to new login sessions."
