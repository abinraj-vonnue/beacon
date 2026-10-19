#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/https-readiness.sh"

log_messages=()
die_message=""
log() { log_messages+=("$*"); }
die() { die_message="$*"; return 99; }

curl_calls=0
curl_success_after=2
curl_timeouts=()
curl_urls=()
sleep_calls=()
curl() {
  local previous="" argument
  for argument in "$@"; do
    if [[ "$previous" == --max-time ]]; then curl_timeouts+=("$argument"); fi
    if [[ "$argument" == https://beacon.test/readyz ]]; then curl_urls+=("$argument"); fi
    previous="$argument"
  done
  curl_calls=$((curl_calls + 1))
  ((curl_calls > curl_success_after))
}
sleep() {
  sleep_calls+=("$1")
  SECONDS=$((SECONDS + $1))
}

SECONDS=0
if ! wait_for_https_readiness https://beacon.test/readyz 120 2; then
  printf 'FAIL: readiness retry should succeed after transient failures: %s\n' "$die_message" >&2
  exit 1
fi
[[ "$curl_calls" -eq 3 ]]
[[ "${sleep_calls[*]}" == '2 2' ]]
[[ "${curl_timeouts[*]}" == '5 5 5' ]]
[[ "${curl_urls[*]}" == 'https://beacon.test/readyz https://beacon.test/readyz https://beacon.test/readyz' ]]
[[ "${log_messages[*]}" == *'API became ready through the local HTTPS proxy.'* ]]

curl_calls=0
curl_success_after=999
curl_timeouts=()
curl_urls=()
sleep_calls=()
die_message=""
SECONDS=0
if wait_for_https_readiness https://beacon.test/readyz 7 2; then
  printf 'FAIL: readiness timeout should fail closed.\n' >&2
  exit 1
else
  status=$?
fi
[[ "$status" -eq 99 ]]
[[ "$curl_calls" -eq 4 ]]
[[ "${curl_timeouts[*]}" == '5 5 3 1' ]]
[[ "${sleep_calls[*]}" == '2 2 2 1' ]]
[[ "${die_message}" == *'within 7 seconds'* ]]
[[ "$SECONDS" -eq 7 ]]
printf 'PASS: HTTPS readiness retries, logs success, and stops at its deadline.\n'
