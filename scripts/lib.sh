#!/usr/bin/env bash

# Shared helpers for the benchmark scripts.
# Compatible with the Bash 3.2 shipped by macOS.

if [[ -n "${BENCHMARK_LIB_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
BENCHMARK_LIB_LOADED=1

BENCHMARK_ROOT="${BENCHMARK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
BENCHMARK_TAG_PREFIX="${BENCHMARK_TAG_PREFIX:-docker-optimization-showcase:benchmark}"
BENCHMARK_CONTAINER_PREFIX="${BENCHMARK_CONTAINER_PREFIX:-showcase-benchmark}"
BENCHMARK_KEEP_ARTIFACTS="${BENCHMARK_KEEP_ARTIFACTS:-0}"
BENCHMARK_TIMER_BACKEND="${BENCHMARK_TIMER_BACKEND:-}"
BENCHMARK_LAST_DURATION_MS=""

BENCHMARK_CONTAINERS=()
BENCHMARK_IMAGES=()

benchmark_log() {
    printf '[benchmark] %s\n' "$*" >&2
}

benchmark_warn() {
    printf '[benchmark] WARNING: %s\n' "$*" >&2
}

benchmark_die() {
    printf '[benchmark] ERROR: %s\n' "$*" >&2
    return 1
}

benchmark_require_command() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 ||
        benchmark_die "Required command not found: ${command_name}"
}

benchmark_select_timer() {
    local probe

    if [[ -n "$BENCHMARK_TIMER_BACKEND" ]]; then
        return 0
    fi

    probe=$(date +%s%3N 2>/dev/null || true)
    case "$probe" in
        *[!0-9]*|'') ;;
        *)
            BENCHMARK_TIMER_BACKEND="gnu-date"
            return 0
            ;;
    esac

    if command -v perl >/dev/null 2>&1 &&
        perl -MTime::HiRes=time -e 'exit(time() > 0 ? 0 : 1)' >/dev/null 2>&1; then
        BENCHMARK_TIMER_BACKEND="perl"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        BENCHMARK_TIMER_BACKEND="python3"
        return 0
    fi

    benchmark_die "No millisecond timer available (GNU date, Perl Time::HiRes, or python3)"
}

benchmark_now_ms() {
    benchmark_select_timer || return 1

    case "$BENCHMARK_TIMER_BACKEND" in
        gnu-date)
            date +%s%3N
            ;;
        perl)
            perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
            ;;
        python3)
            python3 -c 'import time; print(time.time_ns() // 1_000_000)'
            ;;
        *)
            benchmark_die "Unsupported timer backend: ${BENCHMARK_TIMER_BACKEND}"
            ;;
    esac
}

benchmark_run_timed() {
    local started_ms
    local ended_ms
    local status

    started_ms=$(benchmark_now_ms) || return 1
    if "$@"; then
        status=0
    else
        status=$?
    fi
    ended_ms=$(benchmark_now_ms) || return 1

    BENCHMARK_LAST_DURATION_MS=$((ended_ms - started_ms))
    return "$status"
}

benchmark_median() {
    local value

    [[ "$#" -gt 0 ]] || {
        benchmark_die "Cannot calculate the median of an empty sample"
        return 1
    }

    for value in "$@"; do
        case "$value" in
            *[!0-9]*|'')
                benchmark_die "Median samples must be non-negative integers: ${value}"
                return 1
                ;;
        esac
    done

    printf '%s\n' "$@" |
        LC_ALL=C sort -n |
        awk '
            { samples[NR] = $1 }
            END {
                if (NR % 2 == 1) {
                    print samples[(NR + 1) / 2]
                } else {
                    printf "%.0f\n", (samples[NR / 2] + samples[NR / 2 + 1]) / 2
                }
            }
        '
}

benchmark_sanitize_name() {
    printf '%s' "$1" |
        tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

benchmark_image_tag() {
    local variant
    variant=$(benchmark_sanitize_name "$1") || return 1
    printf '%s-%s-%s\n' "$BENCHMARK_TAG_PREFIX" "$variant" "$BENCHMARK_RUN_ID"
}

benchmark_container_name() {
    local variant
    local suffix="${2:-1}"
    variant=$(benchmark_sanitize_name "$1") || return 1
    printf '%s-%s-%s-%s\n' \
        "$BENCHMARK_CONTAINER_PREFIX" "$variant" "$BENCHMARK_RUN_ID" "$suffix"
}

benchmark_register_container() {
    local candidate="$1"
    local registered

    for registered in ${BENCHMARK_CONTAINERS[@]+"${BENCHMARK_CONTAINERS[@]}"}; do
        [[ "$registered" == "$candidate" ]] && return 0
    done
    BENCHMARK_CONTAINERS+=("$candidate")
}

benchmark_register_image() {
    local candidate="$1"
    local registered

    for registered in ${BENCHMARK_IMAGES[@]+"${BENCHMARK_IMAGES[@]}"}; do
        [[ "$registered" == "$candidate" ]] && return 0
    done
    BENCHMARK_IMAGES+=("$candidate")
}

benchmark_cleanup() (
    local resource
    set +e

    if [[ "$BENCHMARK_KEEP_ARTIFACTS" == "1" ]]; then
        benchmark_log "Keeping benchmark resources (BENCHMARK_KEEP_ARTIFACTS=1)"
        exit 0
    fi

    for resource in ${BENCHMARK_CONTAINERS[@]+"${BENCHMARK_CONTAINERS[@]}"}; do
        docker rm -f "$resource" >/dev/null 2>&1 || true
    done

    for resource in ${BENCHMARK_IMAGES[@]+"${BENCHMARK_IMAGES[@]}"}; do
        docker image rm -f "$resource" >/dev/null 2>&1 || true
    done
)

benchmark_install_cleanup_trap() {
    trap 'benchmark_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

benchmark_base_images() {
    local dockerfile

    for dockerfile in "$BENCHMARK_ROOT"/docker/Dockerfile-*; do
        [[ -f "$dockerfile" ]] || continue
        awk '$1 == "FROM" { print $2 }' "$dockerfile"
    done | LC_ALL=C sort -u
}

benchmark_pull_base_images() {
    local image

    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        benchmark_log "Pulling base image ${image}"
        docker pull "$image"
    done < <(benchmark_base_images)
}

benchmark_preflight() {
    local required_file

    if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]}" -lt 3 ]]; then
        benchmark_die "Bash 3 or newer is required"
        return 1
    fi

    for required_file in \
        "$BENCHMARK_ROOT/pom.xml" \
        "$BENCHMARK_ROOT/docker/Dockerfile-1-naive" \
        "$BENCHMARK_ROOT/docker/Dockerfile-5-aot"; do
        [[ -f "$required_file" ]] || {
            benchmark_die "Required project file not found: ${required_file}"
            return 1
        }
    done

    benchmark_require_command docker || return 1
    benchmark_require_command awk || return 1
    benchmark_require_command sort || return 1
    benchmark_require_command sed || return 1
    benchmark_require_command tr || return 1
    benchmark_select_timer || return 1

    docker info >/dev/null 2>&1 || {
        benchmark_die "Docker daemon is not reachable"
        return 1
    }

    benchmark_log "Preflight passed (timer=${BENCHMARK_TIMER_BACKEND}, run=${BENCHMARK_RUN_ID})"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    benchmark_die "This file is a library; source it from a benchmark script"
    exit 2
fi
