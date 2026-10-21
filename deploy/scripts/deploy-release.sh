#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[beacon-deploy] %s\n' "$*"
}

die() {
  printf '[beacon-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 2 ]] || die "Usage: $0 <release-run-number> <commit-sha>"
release_run="$1"
commit_sha="$2"
[[ "$release_run" =~ ^[1-9][0-9]*$ ]] || die "Invalid release run number."
[[ "$commit_sha" =~ ^[a-f0-9]{40}$ ]] || die "Invalid commit SHA."

if (( EUID != 0 )) && [[ -n "${BEACON_DEPLOY_TEST_ROOT:-}" ]]; then
  root="$BEACON_DEPLOY_TEST_ROOT"
  app_dir="$root/app"
  env_file="$root/.env"
  state_dir="$root/state"
  test_mode=1
else
  (( EUID == 0 )) || die "This deployment script must run as root."
  app_dir="/opt/beacon/app"
  env_file="/opt/beacon/.env"
  state_dir="/var/lib/beacon"
  test_mode=0
fi

state_file="$state_dir/deployed-release-run-number"
if (( test_mode )); then
  lock_dir="$root/run/lock"
else
  lock_dir="/run/lock"
fi
lock_file="$lock_dir/beacon-deployment.lock"
image_tag="sha-${commit_sha:0:7}"

if (( test_mode )); then
  mkdir -p -- "$state_dir"
  mkdir -p -- "$lock_dir"
else
  [[ ! -L "$state_dir" ]] || die "Release state directory is unsafe."
  install -d -o root -g root -m 0755 -- "$state_dir"
  [[ "$(stat -c '%u' -- "$state_dir")" == 0 ]] || die "Release state directory is not root-owned."
  chmod 0755 -- "$state_dir"
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || die "Deployment lock directory is unsafe."
  [[ "$(stat -c '%u' -- "$lock_dir")" == 0 ]] || die "Deployment lock directory is not root-owned."
fi
[[ -d "$state_dir" && ! -L "$state_dir" ]] || die "Release state directory is unsafe."
[[ -d "$lock_dir" && ! -L "$lock_dir" ]] || die "Deployment lock directory is unsafe."

[[ ! -L "$lock_file" ]] || die "Deployment lock file is unsafe."
lock_umask="$(umask)"
umask 077
exec 9>"$lock_file"
umask "$lock_umask"
if (( test_mode == 0 )); then
  [[ "$(stat -c '%u' -- "$lock_file")" == 0 ]] || die "Deployment lock file is not root-owned."
  chmod 0600 -- "$lock_file"
fi
flock -x 9 || die "Could not acquire deployment lock."

previous_run=0
if [[ -e "$state_file" || -L "$state_file" ]]; then
  [[ -f "$state_file" && ! -L "$state_file" ]] || die "Release state file is unsafe."
  if (( test_mode == 0 )); then
    [[ "$(stat -c '%u' -- "$state_file")" == 0 ]] || die "Release state file is not root-owned."
  fi
  state_lines=()
  mapfile -t state_lines < "$state_file"
  (( ${#state_lines[@]} == 1 )) || die "Release state file is malformed."
  previous_run="${state_lines[0]}"
  [[ "$previous_run" =~ ^(0|[1-9][0-9]*)$ ]] || die "Release state file is malformed."
fi

export LC_ALL=C
if (( ${#release_run} < ${#previous_run} )) ||
  { (( ${#release_run} == ${#previous_run} )) && [[ "$release_run" < "$previous_run" || "$release_run" == "$previous_run" ]]; }; then
  log "Skipping release run $release_run; run $previous_run is already deployed."
  exit 0
fi

[[ -d "$app_dir" ]] || die "Application directory is missing."
[[ -f "$env_file" ]] || die "Compose environment file is missing."
cd -- "$app_dir"
[[ -f compose.yaml && -f compose.prod.yaml ]] || die "Compose configuration is missing."

sed -i -E \
  -e "s|(beacon-api:sha-)[a-f0-9]{7}|\\1${commit_sha:0:7}|g" \
  -e "s|(beacon-worker:sha-)[a-f0-9]{7}|\\1${commit_sha:0:7}|g" \
  compose.prod.yaml
grep -Eq "beacon-api:${image_tag}" compose.prod.yaml || die "API image tag was not updated."
grep -Eq "beacon-worker:${image_tag}" compose.prod.yaml || die "Worker image tag was not updated."

docker compose --env-file "$env_file" -f compose.yaml -f compose.prod.yaml pull api worker migrate
docker compose --env-file "$env_file" -f compose.yaml -f compose.prod.yaml up -d
curl --fail --retry 10 --retry-delay 3 http://127.0.0.1:3000/readyz

state_tmp="$(mktemp "$state_dir/.deployed-release-run-number.XXXXXX")"
trap 'rm -f -- "$state_tmp"' EXIT
printf '%s\n' "$release_run" > "$state_tmp"
chmod 0644 -- "$state_tmp"
mv -f -- "$state_tmp" "$state_file"
trap - EXIT
log "Release run $release_run ($image_tag) deployed and ready."
