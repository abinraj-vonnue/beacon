wait_for_https_readiness() {
  local url="$1" timeout_seconds="${2:-120}" retry_interval="${3:-2}"
  local deadline=$((SECONDS + timeout_seconds)) remaining request_timeout sleep_duration

  while ((SECONDS < deadline)); do
    remaining=$((deadline - SECONDS))
    request_timeout=5
    if ((remaining < request_timeout)); then
      request_timeout=$remaining
    fi

    if curl --fail --silent --show-error --max-time "$request_timeout" \
      --resolve beacon.test:443:127.0.0.1 --insecure "$url" >/dev/null 2>&1; then
      log "API became ready through the local HTTPS proxy."
      return 0
    fi

    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || break
    sleep_duration="$retry_interval"
    if ((remaining < sleep_duration)); then
      sleep_duration="$remaining"
    fi
    sleep "$sleep_duration"
  done

  die "API readiness through the local HTTPS proxy was not achieved within ${timeout_seconds} seconds; leaving HTTP/HTTPS closed."
}
