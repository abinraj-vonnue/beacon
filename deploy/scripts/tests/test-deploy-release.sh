#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'Refusing to run deployment tests as root.\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/../deploy-release.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/app" "$TEST_ROOT/state"
cat > "$TEST_ROOT/app/compose.yaml" <<'EOF'
services: {}
EOF
cat > "$TEST_ROOT/app/compose.prod.yaml" <<'EOF'
services:
  api:
    image: ghcr.io/example/beacon-api:sha-aaaaaaa
  worker:
    image: ghcr.io/example/beacon-worker:sha-aaaaaaa
EOF
: > "$TEST_ROOT/.env"

cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker %s\n' "$*" >> "$BEACON_TEST_LOG"
if [[ -n "${BEACON_FAIL_DOCKER:-}" && "$*" == *"$BEACON_FAIL_DOCKER"* ]]; then
  exit 42
fi
sleep 0.1
EOF
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'curl %s\n' "$*" >> "$BEACON_TEST_LOG"
[[ "${BEACON_FAIL_READINESS:-0}" != 1 ]]
EOF
chmod +x "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/curl"

export PATH="$TEST_ROOT/bin:$PATH"
export BEACON_DEPLOY_TEST_ROOT="$TEST_ROOT"
export BEACON_TEST_LOG="$TEST_ROOT/commands.log"
: > "$BEACON_TEST_LOG"

printf '10\n' > "$TEST_ROOT/state/deployed-release-run-number"
"$DEPLOY_SCRIPT" 10 aaaaaaa111111111111111111111111111111111
"$DEPLOY_SCRIPT" 9 bbbbbbb111111111111111111111111111111111
[[ "$(cat "$TEST_ROOT/state/deployed-release-run-number")" == 10 ]]
[[ ! -s "$BEACON_TEST_LOG" ]]

"$DEPLOY_SCRIPT" 11 ccccccc111111111111111111111111111111111
[[ "$(cat "$TEST_ROOT/state/deployed-release-run-number")" == 11 ]]
grep -Fq 'beacon-api:sha-ccccccc' "$TEST_ROOT/app/compose.prod.yaml"
grep -Fq 'beacon-worker:sha-ccccccc' "$TEST_ROOT/app/compose.prod.yaml"
grep -Fq 'curl --fail --retry 10 --retry-delay 3 http://127.0.0.1:3000/readyz' "$BEACON_TEST_LOG"

if BEACON_FAIL_DOCKER='up -d' "$DEPLOY_SCRIPT" 12 ddddddd111111111111111111111111111111111; then
  printf 'FAIL: Compose failure should fail the deployment.\n' >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/state/deployed-release-run-number")" == 11 ]]

if BEACON_FAIL_READINESS=1 "$DEPLOY_SCRIPT" 12 ddddddd111111111111111111111111111111111; then
  printf 'FAIL: readiness failure should fail the deployment.\n' >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/state/deployed-release-run-number")" == 11 ]]

printf '12\ninvalid\n' > "$TEST_ROOT/state/deployed-release-run-number"
if "$DEPLOY_SCRIPT" 13 eeeeeee111111111111111111111111111111111; then
  printf 'FAIL: malformed release state should fail closed.\n' >&2
  exit 1
fi
[[ "$(cat "$TEST_ROOT/state/deployed-release-run-number")" == $'12\ninvalid' ]]

printf '11\n' > "$TEST_ROOT/state/deployed-release-run-number"
: > "$BEACON_TEST_LOG"
"$DEPLOY_SCRIPT" 12 fffffff111111111111111111111111111111111 & pid_old=$!
"$DEPLOY_SCRIPT" 13 1234567111111111111111111111111111111111 & pid_new=$!
wait "$pid_old"
wait "$pid_new"
[[ "$(cat "$TEST_ROOT/state/deployed-release-run-number")" == 13 ]]

printf 'PASS: release ordering, successful and failed state updates, malformed state, and overlapping runs.\n'
