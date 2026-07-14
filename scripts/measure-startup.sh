#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

IMAGE=""
VARIANT=""
RUNS=5
TIMEOUT_SECONDS=30
POLL_INTERVAL=0.1
MEMORY_LIMIT=512m
CONTAINER_PORT=8080
HEALTH_PATH=/actuator/health
QUIET=0
MEASURED_STARTUP_MS=""

usage() {
    cat <<'EOF'
Usage: scripts/measure-startup.sh --image IMAGE [options]

Measure container startup from immediately before `docker run` to the first
HTTP 200 response from the health endpoint.

Options:
  --image IMAGE           Image to run (required)
  --variant NAME          Label used in temporary container names
  --runs COUNT            Number of measurements (default: 5)
  --timeout SECONDS       Timeout for each run (default: 30)
  --interval SECONDS      Polling interval (default: 0.1)
  --memory LIMIT          Docker memory limit (default: 512m)
  --port PORT             Container HTTP port (default: 8080)
  --health-path PATH      Health endpoint (default: /actuator/health)
  --quiet                 Print only the median in milliseconds
  -h, --help              Show this help

Default output is tab-separated:
  run<TAB>STARTUP_MS
  median<TAB>MEDIAN_MS
EOF
}

require_positive_integer() {
    local label="$1"
    local value="$2"

    case "$value" in
        *[!0-9]*|'')
            benchmark_die "${label} must be a positive integer: ${value}"
            return 1
            ;;
    esac

    [[ "$value" -gt 0 ]] || {
        benchmark_die "${label} must be greater than zero"
        return 1
    }
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --image)
                [[ "$#" -ge 2 ]] || benchmark_die "--image requires a value"
                IMAGE="$2"
                shift 2
                ;;
            --variant)
                [[ "$#" -ge 2 ]] || benchmark_die "--variant requires a value"
                VARIANT="$2"
                shift 2
                ;;
            --runs)
                [[ "$#" -ge 2 ]] || benchmark_die "--runs requires a value"
                RUNS="$2"
                shift 2
                ;;
            --timeout)
                [[ "$#" -ge 2 ]] || benchmark_die "--timeout requires a value"
                TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --interval)
                [[ "$#" -ge 2 ]] || benchmark_die "--interval requires a value"
                POLL_INTERVAL="$2"
                shift 2
                ;;
            --memory)
                [[ "$#" -ge 2 ]] || benchmark_die "--memory requires a value"
                MEMORY_LIMIT="$2"
                shift 2
                ;;
            --port)
                [[ "$#" -ge 2 ]] || benchmark_die "--port requires a value"
                CONTAINER_PORT="$2"
                shift 2
                ;;
            --health-path)
                [[ "$#" -ge 2 ]] || benchmark_die "--health-path requires a value"
                HEALTH_PATH="$2"
                shift 2
                ;;
            --quiet)
                QUIET=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                benchmark_die "Unknown option: $1"
                return 1
                ;;
        esac
    done

    [[ -n "$IMAGE" ]] || {
        benchmark_die "--image is required"
        return 1
    }
    require_positive_integer "--runs" "$RUNS"
    require_positive_integer "--timeout" "$TIMEOUT_SECONDS"
    require_positive_integer "--port" "$CONTAINER_PORT"

    awk -v value="$POLL_INTERVAL" \
        'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }' || {
        benchmark_die "--interval must be a positive number: ${POLL_INTERVAL}"
        return 1
    }

    [[ -n "$MEMORY_LIMIT" ]] || {
        benchmark_die "--memory cannot be empty"
        return 1
    }

    [[ "$HEALTH_PATH" == /* ]] || HEALTH_PATH="/${HEALTH_PATH}"
    [[ -n "$VARIANT" ]] || VARIANT=$(benchmark_sanitize_name "$IMAGE")
}

release_container() {
    local container_name="$1"

    if [[ "$BENCHMARK_KEEP_ARTIFACTS" == "1" ]]; then
        docker stop --time 2 "$container_name" >/dev/null 2>&1 || true
    else
        docker rm -f "$container_name" >/dev/null 2>&1 || true
    fi
}

print_container_diagnostics() {
    local container_name="$1"

    benchmark_warn "Last logs from ${container_name}:"
    docker logs --tail 50 "$container_name" >&2 || true
}

measure_once() {
    local run_number="$1"
    local container_name
    local container_id
    local host_port=""
    local health_url
    local started_ms
    local current_ms
    local deadline_ms
    local http_code
    local attempt=0

    container_name=$(benchmark_container_name "$VARIANT" "$run_number")
    benchmark_register_container "$container_name"

    started_ms=$(benchmark_now_ms)
    deadline_ms=$((started_ms + TIMEOUT_SECONDS * 1000))

    if ! container_id=$(docker run --detach \
        --name "$container_name" \
        --memory "$MEMORY_LIMIT" \
        --publish "127.0.0.1::${CONTAINER_PORT}" \
        "$IMAGE"); then
        benchmark_die "docker run failed for ${IMAGE}"
        return 1
    fi

    while [[ -z "$host_port" ]]; do
        host_port=$(docker inspect --format \
            "{{(index (index .NetworkSettings.Ports \"${CONTAINER_PORT}/tcp\") 0).HostPort}}" \
            "$container_id" 2>/dev/null || true)
        [[ -n "$host_port" ]] && break

        if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != "true" ]]; then
            print_container_diagnostics "$container_name"
            release_container "$container_name"
            benchmark_die "Container exited before publishing its HTTP port"
            return 1
        fi

        current_ms=$(benchmark_now_ms)
        if [[ "$current_ms" -ge "$deadline_ms" ]]; then
            print_container_diagnostics "$container_name"
            release_container "$container_name"
            benchmark_die "Timed out waiting for the published port"
            return 1
        fi
        sleep "$POLL_INTERVAL"
    done

    health_url="http://127.0.0.1:${host_port}${HEALTH_PATH}"
    benchmark_log "Run ${run_number}/${RUNS}: ${container_name} -> ${health_url}"

    while true; do
        http_code=$(curl --silent \
            --output /dev/null \
            --write-out '%{http_code}' \
            --connect-timeout 0.2 \
            --max-time 0.5 \
            "$health_url" || true)

        if [[ "$http_code" == "200" ]]; then
            current_ms=$(benchmark_now_ms)
            MEASURED_STARTUP_MS=$((current_ms - started_ms))
            release_container "$container_name"
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $((attempt % 10)) -eq 0 ]]; then
            if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != "true" ]]; then
                print_container_diagnostics "$container_name"
                release_container "$container_name"
                benchmark_die "Container exited before becoming healthy"
                return 1
            fi
        fi

        current_ms=$(benchmark_now_ms)
        if [[ "$current_ms" -ge "$deadline_ms" ]]; then
            print_container_diagnostics "$container_name"
            release_container "$container_name"
            benchmark_die "Startup timed out after ${TIMEOUT_SECONDS}s"
            return 1
        fi
        sleep "$POLL_INTERVAL"
    done
}

main() {
    local run_number
    local median_ms
    local samples=()

    parse_args "$@"
    benchmark_preflight
    benchmark_require_command curl
    docker image inspect "$IMAGE" >/dev/null 2>&1 || {
        benchmark_die "Image not found locally: ${IMAGE}"
        return 1
    }
    benchmark_install_cleanup_trap

    for ((run_number = 1; run_number <= RUNS; run_number++)); do
        measure_once "$run_number"
        samples+=("$MEASURED_STARTUP_MS")
        [[ "$QUIET" == "1" ]] || printf 'run\t%s\n' "$MEASURED_STARTUP_MS"
    done

    median_ms=$(benchmark_median "${samples[@]}")
    if [[ "$QUIET" == "1" ]]; then
        printf '%s\n' "$median_ms"
    else
        printf 'median\t%s\n' "$median_ms"
    fi
}

main "$@"
