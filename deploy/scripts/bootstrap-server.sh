#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap an Ubuntu server for Beacon.
# Run as root from a checked-out Beacon repository.
#
# Usage:
#   sudo ./deploy/scripts/bootstrap-server.sh [deploy-public-key-file]

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DEPLOY_USER="deploy"
readonly DEPLOY_DIR="/opt/beacon"
readonly SSH_HARDENING="/etc/ssh/sshd_config.d/00-beacon-hardening.conf"
readonly DOCKER_CONFIG="/etc/docker/daemon.json"
DOCKER_CONFIG_CHANGED=0
SSH_HARDENING_PENDING=0
SSH_HARDENING_BACKUP=""
SSH_HARDENING_PREVIOUSLY_EXISTED=0
SSH_PORTS=()

log() {
  printf '[beacon-bootstrap] %s\n' "$*"
}

die() {
  printf '[beacon-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

validate_public_key_file() {
  local key_file="$1" line line_number=0 valid_key_count=0 candidate_key
  command -v ssh-keygen >/dev/null 2>&1 ||
    die "ssh-keygen is required to validate public keys."

  if grep -Eq -- '^[[:space:]]*-----BEGIN .*PRIVATE KEY-----[[:space:]]*$' "$key_file"; then
    die "Private-key material is not accepted: $key_file"
  fi

  candidate_key="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == \#* ]] && continue

    printf '%s\n' "$line" > "$candidate_key"
    if ! ssh-keygen -l -f "$candidate_key" >/dev/null 2>&1; then
      rm -f "$candidate_key"
      die "Invalid public key on line $line_number of $key_file."
    fi
    valid_key_count=$((valid_key_count + 1))
  done < "$key_file"
  rm -f "$candidate_key"

  ((valid_key_count > 0)) || die "No public keys found in $key_file."
}

validate_deploy_authorized_keys() {
  local authorized_keys="/home/$DEPLOY_USER/.ssh/authorized_keys"
  [[ -s "$authorized_keys" ]] ||
    die "No authorized SSH key is configured for $DEPLOY_USER."
  validate_public_key_file "$authorized_keys"
}

configure_docker_logging() {
  local candidate
  candidate="$(mktemp /etc/docker/daemon.json.XXXXXX)"

  python3 - "$DOCKER_CONFIG" "$REPO_ROOT/deploy/docker/daemon.json" "$candidate" <<'PY'
import json
import os
import sys

current_path, desired_path, output_path = sys.argv[1:]
with open(desired_path, encoding="utf-8") as desired_file:
    desired = json.load(desired_file)

if os.path.exists(current_path):
    with open(current_path, encoding="utf-8") as current_file:
        current = json.load(current_file)
else:
    current = {}

current.update(desired)
with open(output_path, "w", encoding="utf-8") as output_file:
    json.dump(current, output_file, indent=2)
    output_file.write("\n")
PY

  python3 -m json.tool "$candidate" >/dev/null || {
    rm -f "$candidate"
    die "Generated Docker daemon configuration is invalid."
  }

  if [[ -f "$DOCKER_CONFIG" ]] && python3 - "$candidate" "$DOCKER_CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as candidate_file:
    candidate = json.load(candidate_file)
with open(sys.argv[2], encoding="utf-8") as current_file:
    current = json.load(current_file)
sys.exit(0 if candidate == current else 1)
PY
  then
    log "Docker daemon configuration already matches; leaving it unchanged."
    rm -f "$candidate"
    return
  fi

  install -m 0644 "$candidate" "$DOCKER_CONFIG"
  rm -f "$candidate"
  DOCKER_CONFIG_CHANGED=1
}

restore_ssh_hardening() {
  if [[ "$SSH_HARDENING_PENDING" -eq 1 ]]; then
    if [[ "$SSH_HARDENING_PREVIOUSLY_EXISTED" -eq 1 ]]; then
      cp -p "$SSH_HARDENING_BACKUP" "$SSH_HARDENING"
    else
      rm -f "$SSH_HARDENING"
    fi
  fi
  if [[ -n "$SSH_HARDENING_BACKUP" ]]; then
    rm -f "$SSH_HARDENING_BACKUP"
  fi
}

rollback_ssh_hardening_on_exit() {
  local exit_status=$?
  trap - EXIT
  restore_ssh_hardening
  exit "$exit_status"
}

require_ssh_setting() {
  local effective_config="$1"
  local expected_setting="$2"
  grep -Fqx -- "$expected_setting" <<<"$effective_config" ||
    die "Effective SSH configuration is missing '$expected_setting'."
}

discover_ssh_ports() {
  local effective_config socket_listeners ssh_port_lines ssh_port ssh_port_number

  if systemctl is-active --quiet ssh.socket; then
    socket_listeners="$(systemctl show --property=Listen --value ssh.socket)" ||
      die "Could not read active SSH socket listeners."
    ssh_port_lines="$(python3 - "$socket_listeners" <<'PY'
import re
import sys

listeners = sys.argv[1]
ports = set()
for match in re.finditer(r'(?:^|\s)(?:\[[^]]+\]|[^:\s]+):([0-9]+)\s+\(Stream\)', listeners):
    ports.add(int(match.group(1)))

for port in sorted(ports):
    print(port)
PY
)" || die "Could not parse active SSH socket listeners."
  else
    effective_config="$(sshd -T)" || die "Could not read effective SSH configuration."
    ssh_port_lines="$(awk '$1 == "port" { print $2 }' <<<"$effective_config" | sort -nu)"
  fi

  [[ -n "$ssh_port_lines" ]] ||
    die "No SSH TCP port found in the active socket or effective SSH configuration."

  while IFS= read -r ssh_port; do
    [[ "$ssh_port" =~ ^[0-9]+$ ]] || die "Invalid SSH port: $ssh_port"
    ssh_port_number=$((10#$ssh_port))
    ((ssh_port_number >= 1 && ssh_port_number <= 65535)) ||
      die "SSH port is out of range: $ssh_port"
    SSH_PORTS+=("$ssh_port_number")
  done <<< "$ssh_port_lines"
}

configure_ssh_hardening() {
  local candidate effective_config deploy_config ssh_host
  SSH_HARDENING_BACKUP="$(mktemp)"
  if [[ -e "$SSH_HARDENING" ]]; then
    cp -p "$SSH_HARDENING" "$SSH_HARDENING_BACKUP"
    SSH_HARDENING_PREVIOUSLY_EXISTED=1
  fi

  candidate="$(mktemp /etc/ssh/sshd_config.d/.beacon-hardening.XXXXXX)"
  cat > "$candidate" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  chmod 0644 "$candidate"

  SSH_HARDENING_PENDING=1
  trap rollback_ssh_hardening_on_exit EXIT
  mv -f "$candidate" "$SSH_HARDENING"

  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    die "SSH configuration validation failed; restoring the previous drop-in."
  fi

  effective_config="$(sshd -T)" ||
    die "Could not read effective SSH configuration; restoring the previous drop-in."
  require_ssh_setting "$effective_config" 'permitrootlogin no'
  require_ssh_setting "$effective_config" 'passwordauthentication no'
  require_ssh_setting "$effective_config" 'kbdinteractiveauthentication no'
  require_ssh_setting "$effective_config" 'pubkeyauthentication yes'

  ssh_host="$(hostname -f)" ||
    die "Could not determine the host name for SSH policy validation."
  deploy_config="$(sshd -T -C "user=$DEPLOY_USER,host=$ssh_host,addr=127.0.0.1")" ||
    die "Could not read effective SSH configuration for $DEPLOY_USER."
  require_ssh_setting "$deploy_config" 'passwordauthentication no'
  require_ssh_setting "$deploy_config" 'pubkeyauthentication yes'

  if ! systemctl try-reload-or-restart ssh.service; then
    die "Could not reload SSH; restoring the previous drop-in."
  fi

  SSH_HARDENING_PENDING=0
  trap - EXIT
  rm -f "$SSH_HARDENING_BACKUP"
  SSH_HARDENING_BACKUP=""
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
elif [[ ! -s "/home/$DEPLOY_USER/.ssh/authorized_keys" ]]; then
  die "No key file supplied and $DEPLOY_USER has no authorized_keys; refusing to harden SSH."
fi

# Never overwrite an existing production environment file.
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

if [[ -n "$PUBLIC_KEY_FILE" ]]; then
  validate_public_key_file "$PUBLIC_KEY_FILE"
fi

log "Creating the deploy user if necessary."
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0750 \
  "/home/$DEPLOY_USER/.ssh"

if [[ -n "$PUBLIC_KEY_FILE" ]]; then
  log "Installing supplied public key(s) for $DEPLOY_USER."

  local_auth_keys="/home/$DEPLOY_USER/.ssh/authorized_keys"
  touch "$local_auth_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$local_auth_keys"
  chmod 0600 "$local_auth_keys"

  # Ensure newly appended keys start on a separate line.
  if [[ -s "$local_auth_keys" && -n "$(tail -c 1 "$local_auth_keys")" ]]; then
    printf '\n' >> "$local_auth_keys"
  fi

  # Validate and add each key independently without duplicating existing keys.
  while IFS= read -r key || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    grep -Fqx -- "$key" "$local_auth_keys" ||
      printf '%s\n' "$key" >> "$local_auth_keys"
  done < "$PUBLIC_KEY_FILE"

  chown "$DEPLOY_USER:$DEPLOY_USER" "$local_auth_keys"
  chmod 0600 "$local_auth_keys"
fi

validate_deploy_authorized_keys

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
docker_was_active=0
if systemctl is-active --quiet docker.service; then
  docker_was_active=1
fi
configure_docker_logging

systemctl enable --now docker
if [[ "$DOCKER_CONFIG_CHANGED" -eq 1 && "$docker_was_active" -eq 1 ]]; then
  systemctl restart docker.service
fi

# Docker-group membership effectively grants root-level privileges.
getent group docker >/dev/null || groupadd docker
usermod -aG docker "$DEPLOY_USER"

log "Preparing the deployment directory."
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0750 "$DEPLOY_DIR"

# Preserve an existing deployment .env file.
if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
  install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0600 \
    "$REPO_ROOT/.env" "$DEPLOY_DIR/.env"
fi

# Synchronize application files without deleting unrelated server files.
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
install -d -m 0755 /run/sshd
discover_ssh_ports
for ssh_port in "${SSH_PORTS[@]}"; do
  log "Allowing configured SSH port $ssh_port/tcp through UFW."
  ufw allow "$ssh_port/tcp"
done
# Do not open ports 3000 or 5432.
ufw --force enable

log "Hardening SSH."
install -d -m 0755 /etc/ssh/sshd_config.d

configure_ssh_hardening

log "Enabling Beacon and the prune timer."
systemctl daemon-reload
systemctl enable docker.service
systemctl enable beacon.service
systemctl enable --now beacon-prune.timer
systemctl restart beacon.service

log "Bootstrap completed. Test deploy SSH access in a second terminal."
log "Check: systemctl status beacon.service"
log "Check: systemctl list-timers --all | grep beacon-prune"
log "Check readiness locally: curl -fsS http://127.0.0.1:3000/readyz"
log "New docker-group membership applies to new login sessions."
