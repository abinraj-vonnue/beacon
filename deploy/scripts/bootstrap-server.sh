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
readonly TLS_CERT="/etc/ssl/beacon/beacon.test.pem"
readonly TLS_KEY="/etc/ssl/beacon/beacon.test-key.pem"
readonly UFW_ADDED_RULES_HEADER="Added user rules (see 'ufw status' for running firewall):"
DOCKER_CONFIG_CHANGED=0
SSH_HARDENING_PENDING=0
SSH_HARDENING_BACKUP=""
SSH_HARDENING_PREVIOUSLY_EXISTED=0
SSH_PORTS=()
UFW_ADDED_RULES=""
UFW_PREPARED=0
WEB_PORT_RULES_PENDING=0

log() {
  printf '[beacon-bootstrap] %s\n' "$*"
}

die() {
  printf '[beacon-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

validate_public_key_file() {
  local key_file="$1" plain_public_keys="${2:-0}"
  local line line_number=0 valid_key_count=0 candidate_key key_type key_blob key_comment
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

    if [[ "$plain_public_keys" -eq 1 ]]; then
      read -r key_type key_blob key_comment <<< "$line"
      if [[ -z "$key_type" || -z "$key_blob" ]]; then
        rm -f "$candidate_key"
        die "Malformed public key on line $line_number of $key_file."
      fi
      printf '%s %s\n' "$key_type" "$key_blob" > "$candidate_key"
    else
      printf '%s\n' "$line" > "$candidate_key"
    fi
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

refresh_ufw_added_rules() {
  local output line header_seen=0
  output="$(ufw show added)" ||
    die "Could not read UFW's added rules; refusing to change firewall access."

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "$UFW_ADDED_RULES_HEADER" ]]; then
      header_seen=1
    elif [[ "$line" == "(None)" ]]; then
      :
    elif [[ "$line" == ufw\ * ]]; then
      :
    else
      die "Unexpected 'ufw show added' output. Review UFW manually before rerunning bootstrap: $line"
    fi
  done <<< "$output"

  ((header_seen == 1)) ||
    die "Could not recognize 'ufw show added' output. Review UFW manually before rerunning bootstrap."
  UFW_ADDED_RULES="$output"
}

count_ufw_added_rule() {
  local expected="$1" line count=0
  while IFS= read -r line; do
    if [[ "$line" == "$expected" ]]; then
      count=$((count + 1))
    fi
  done <<< "$UFW_ADDED_RULES"
  printf '%s\n' "$count"
}

remove_ufw_added_rule() {
  local rule="$1" before after
  while true; do
    refresh_ufw_added_rules
    before="$(count_ufw_added_rule "ufw allow $rule")"
    ((before > 0)) || return 0

    ufw --force delete allow "$rule" ||
      die "Could not remove UFW rule 'ufw allow $rule'. Review UFW manually."

    refresh_ufw_added_rules
    after="$(count_ufw_added_rule "ufw allow $rule")"
    if ((after >= before)); then
      die "UFW rule 'ufw allow $rule' did not disappear after deletion. Review UFW manually."
    fi
  done
}

prepare_firewall() {
  local ssh_port

  log "Preparing UFW before package operations that may start public services."
  install -d -m 0755 /run/sshd
  discover_ssh_ports

  # Validate the UFW output before making any changes, then remove only rules
  # managed by this script. Unrelated rules remain untouched.
  refresh_ufw_added_rules
  remove_ufw_added_rule 80/tcp
  remove_ufw_added_rule 443/tcp
  remove_ufw_added_rule 3000/tcp
  remove_ufw_added_rule 5432/tcp

  for ssh_port in "${SSH_PORTS[@]}"; do
    log "Allowing configured SSH port $ssh_port/tcp through UFW."
    ufw allow "$ssh_port/tcp"
  done

  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  UFW_PREPARED=1
  log "UFW is enabled; script-managed HTTP/HTTPS rules remain closed until bootstrap succeeds."
  log "Unrelated existing UFW rules are preserved; review 'ufw status numbered' for additional allowed ports."
}

stop_nginx_before_firewall_transition() {
  if systemctl is-active --quiet nginx.service; then
    log "Stopping active Nginx while the firewall is being prepared."
    systemctl stop nginx.service ||
      die "Could not stop Nginx before firewall preparation; refusing to continue."
  fi
}

rollback_web_port_rules_on_exit() {
  local exit_status=$?
  trap - EXIT
  if [[ "$WEB_PORT_RULES_PENDING" -eq 1 ]]; then
    if ! ufw --force delete allow 80/tcp >/dev/null 2>&1; then
      log "WARNING: could not confirm removal of 80/tcp during rollback; inspect 'ufw status numbered'."
    fi
    if ! ufw --force delete allow 443/tcp >/dev/null 2>&1; then
      log "WARNING: could not confirm removal of 443/tcp during rollback; inspect 'ufw status numbered'."
    fi
  fi
  exit "$exit_status"
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
[[ -r /etc/os-release ]] || die "Cannot determine the operating system; expected Ubuntu."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only."
[[ -f "$REPO_ROOT/compose.yaml" ]] || die "compose.yaml not found at $REPO_ROOT."
[[ -f "$REPO_ROOT/deploy/systemd/beacon.service" ]] ||
  die "Beacon systemd unit is missing."
[[ -f "$REPO_ROOT/deploy/systemd/beacon-prune.service" ]] ||
  die "Prune service unit is missing."
[[ -f "$REPO_ROOT/deploy/systemd/beacon-prune.timer" ]] ||
  die "Prune timer unit is missing."
[[ -f "$REPO_ROOT/deploy/docker/daemon.json" ]] ||
  die "Docker daemon configuration is missing."
[[ -f "$REPO_ROOT/deploy/nginx/beacon.conf" ]] ||
  die "Nginx site configuration is missing."
[[ -f "$REPO_ROOT/deploy/nginx/conf.d/beacon-ratelimit.conf" ]] ||
  die "Nginx rate-limit configuration is missing."
[[ -d "$REPO_ROOT/web/status" ]] ||
  die "Public status page source directory is missing."

PUBLIC_KEY_FILE="${1:-}"

if [[ -n "$PUBLIC_KEY_FILE" ]]; then
  [[ -f "$PUBLIC_KEY_FILE" ]] || die "Public key file not found: $PUBLIC_KEY_FILE"
  [[ -s "$PUBLIC_KEY_FILE" ]] || die "Public key file is empty."
  validate_public_key_file "$PUBLIC_KEY_FILE" 1
else
  validate_deploy_authorized_keys
fi

# Never overwrite an existing production environment file.
if [[ ! -f "$DEPLOY_DIR/.env" && ! -f "$REPO_ROOT/.env" ]]; then
  die "No .env found. Prepare one in the repository before bootstrapping."
fi

# Certificates are provisioned separately through the Phase 2 Task 3
# Multipass transfer procedure. Check them before package or system changes.
[[ -f "$TLS_CERT" && -s "$TLS_CERT" ]] ||
  die "TLS certificate $TLS_CERT is missing or empty. Transfer the certificate and key using the Phase 2 Task 3 Multipass transfer procedure before bootstrapping."
[[ -f "$TLS_KEY" && -s "$TLS_KEY" ]] ||
  die "TLS private key $TLS_KEY is missing or empty. Transfer the certificate and key using the Phase 2 Task 3 Multipass transfer procedure before bootstrapping."

# Prepare an existing firewall immediately after preflight. If UFW is absent,
# install only its base prerequisites first, then use the same preparation
# path before installing Nginx.
stop_nginx_before_firewall_transition
if command -v ufw >/dev/null 2>&1; then
  prepare_firewall
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

if [[ "$UFW_PREPARED" -eq 0 ]]; then
  prepare_firewall
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

install -d -o root -g root -m 0755 /etc/ssl/beacon
chown root:root "$TLS_CERT" "$TLS_KEY"
chmod 0644 "$TLS_CERT"
chmod 0600 "$TLS_KEY"

log "Installing Nginx behind the enabled firewall."
apt-get install -y nginx

log "Installing Docker from the official Docker Ubuntu repository."
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

log "Installing the Nginx site and public status page."
install -m 0644 "$DEPLOY_DIR/deploy/nginx/beacon.conf" \
  /etc/nginx/sites-available/beacon
install -m 0644 "$DEPLOY_DIR/deploy/nginx/conf.d/beacon-ratelimit.conf" \
  /etc/nginx/conf.d/beacon-ratelimit.conf
ln -sfn /etc/nginx/sites-available/beacon /etc/nginx/sites-enabled/beacon
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi
install -d -m 0755 /var/www/beacon
rsync -a --delete "$DEPLOY_DIR/web/status/" /var/www/beacon/

log "Validating the Nginx configuration."
if ! nginx -t; then
  die "Nginx configuration validation failed; refusing to start or reload Nginx."
fi
systemctl enable nginx.service
if systemctl is-active --quiet nginx.service; then
  systemctl reload nginx.service
else
  systemctl start nginx.service
fi

log "Installing systemd units."
install -m 0644 "$DEPLOY_DIR/deploy/systemd/beacon.service" \
  /etc/systemd/system/beacon.service
install -m 0644 "$DEPLOY_DIR/deploy/systemd/beacon-prune.service" \
  /etc/systemd/system/beacon-prune.service
install -m 0644 "$DEPLOY_DIR/deploy/systemd/beacon-prune.timer" \
  /etc/systemd/system/beacon-prune.timer

log "Hardening SSH."
install -d -m 0755 /etc/ssh/sshd_config.d

configure_ssh_hardening

log "Enabling Beacon and the prune timer."
systemctl daemon-reload
systemctl enable docker.service
systemctl enable beacon.service
systemctl enable --now beacon-prune.timer
systemctl restart beacon.service

systemctl is-active --quiet nginx.service ||
  die "Nginx is not active after configuration and startup; leaving HTTP/HTTPS closed."
systemctl is-active --quiet beacon.service ||
  die "Beacon is not active after startup; leaving HTTP/HTTPS closed."

log "Opening HTTP and HTTPS after Nginx and Beacon are running."
WEB_PORT_RULES_PENDING=1
trap rollback_web_port_rules_on_exit EXIT
ufw allow 80/tcp
ufw allow 443/tcp
refresh_ufw_added_rules
[[ "$(count_ufw_added_rule 'ufw allow 80/tcp')" -gt 0 ]] ||
  die "UFW did not confirm the 80/tcp allow rule; leaving web ports closed."
[[ "$(count_ufw_added_rule 'ufw allow 443/tcp')" -gt 0 ]] ||
  die "UFW did not confirm the 443/tcp allow rule; leaving web ports closed."
WEB_PORT_RULES_PENDING=0
trap - EXIT

log "Bootstrap completed. Test deploy SSH access in a second terminal."
log "Check: systemctl status beacon.service"
log "Check: systemctl list-timers --all | grep beacon-prune"
log "Check readiness locally: curl -fsS http://127.0.0.1:3000/readyz"
log "New docker-group membership applies to new login sessions."
