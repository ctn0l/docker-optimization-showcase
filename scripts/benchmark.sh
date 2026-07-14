#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUTPUT_FILE="$BENCHMARK_ROOT/target/benchmark/results.tsv"
REPORT_FILE="$BENCHMARK_ROOT/docs/RESULTS.md"
METADATA_FILE=""
GENERATE_REPORT=1
STARTUP_RUNS=5
STARTUP_TIMEOUT=30
MEMORY_LIMIT=512m
MEMORY_DELAY_SECONDS=10
SKIP_PULL=0
SKIP_TRIVY=0
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"
TRIVY_CACHE_VOLUME="${TRIVY_CACHE_VOLUME:-showcase-trivy-cache}"
BUILDER_NAME=$(benchmark_sanitize_name "showcase-benchmark-${BENCHMARK_RUN_ID}")
BENCHMARK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WORK_DIR=""
SELECTED_VARIANTS=()
MEASURED_MEMORY_MIB=""

usage() {
    cat <<'EOF'
Usage: scripts/benchmark.sh [options]

Build and measure the Dockerfile variants. Raw results are written as TSV so
they can be turned into docs/RESULTS.md by the report generation step.

Options:
  --variant NAME          Measure only this variant (repeatable, e.g. 3-cache)
  --output FILE           Raw TSV output (default: target/benchmark/results.tsv)
  --report FILE           Markdown report (default: docs/RESULTS.md)
  --no-report             Do not generate the Markdown report
  --startup-runs COUNT    Startup samples per variant (default: 5)
  --startup-timeout SEC   Timeout for each startup sample (default: 30)
  --memory LIMIT          Docker memory limit (default: 512m)
  --memory-delay SEC      Wait after readiness before docker stats (default: 10)
  --skip-pull             Do not refresh application base images
  --skip-trivy            Skip vulnerability scanning
  -h, --help              Show this help

Environment:
  BENCHMARK_KEEP_ARTIFACTS=1  Keep builder, images and temporary contexts
  TRIVY_IMAGE=...             Trivy container image when no local binary exists
  TRIVY_CACHE_VOLUME=...      Persistent Docker volume for the Trivy database
EOF
}

require_non_negative_integer() {
    local label="$1"
    local value="$2"

    case "$value" in
        *[!0-9]*|'')
            benchmark_die "${label} must be a non-negative integer: ${value}"
            return 1
            ;;
    esac
}

require_positive_integer() {
    local label="$1"
    local value="$2"

    require_non_negative_integer "$label" "$value" || return 1
    [[ "$value" -gt 0 ]] || {
        benchmark_die "${label} must be greater than zero"
        return 1
    }
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --variant)
                [[ "$#" -ge 2 ]] || benchmark_die "--variant requires a value"
                SELECTED_VARIANTS+=("$2")
                shift 2
                ;;
            --output)
                [[ "$#" -ge 2 ]] || benchmark_die "--output requires a value"
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --report)
                [[ "$#" -ge 2 ]] || benchmark_die "--report requires a value"
                REPORT_FILE="$2"
                shift 2
                ;;
            --no-report)
                GENERATE_REPORT=0
                shift
                ;;
            --startup-runs)
                [[ "$#" -ge 2 ]] || benchmark_die "--startup-runs requires a value"
                STARTUP_RUNS="$2"
                shift 2
                ;;
            --startup-timeout)
                [[ "$#" -ge 2 ]] || benchmark_die "--startup-timeout requires a value"
                STARTUP_TIMEOUT="$2"
                shift 2
                ;;
            --memory)
                [[ "$#" -ge 2 ]] || benchmark_die "--memory requires a value"
                MEMORY_LIMIT="$2"
                shift 2
                ;;
            --memory-delay)
                [[ "$#" -ge 2 ]] || benchmark_die "--memory-delay requires a value"
                MEMORY_DELAY_SECONDS="$2"
                shift 2
                ;;
            --skip-pull)
                SKIP_PULL=1
                shift
                ;;
            --skip-trivy)
                SKIP_TRIVY=1
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

    require_positive_integer "--startup-runs" "$STARTUP_RUNS"
    require_positive_integer "--startup-timeout" "$STARTUP_TIMEOUT"
    require_non_negative_integer "--memory-delay" "$MEMORY_DELAY_SECONDS"
    [[ -n "$MEMORY_LIMIT" ]] || benchmark_die "--memory cannot be empty"

    if [[ "$OUTPUT_FILE" != /* ]]; then
        OUTPUT_FILE="$BENCHMARK_ROOT/$OUTPUT_FILE"
    fi
    if [[ "$REPORT_FILE" != /* ]]; then
        REPORT_FILE="$BENCHMARK_ROOT/$REPORT_FILE"
    fi
    METADATA_FILE="${OUTPUT_FILE}.meta.tsv"
}

variant_selected() {
    local variant="$1"
    local selected

    if [[ -z "${SELECTED_VARIANTS[0]+set}" ]]; then
        return 0
    fi

    for selected in "${SELECTED_VARIANTS[@]}"; do
        [[ "$selected" == "$variant" ]] && return 0
    done
    return 1
}

metadata_put() {
    local key="$1"
    local value="$2"

    value=$(printf '%s' "$value" | tr '\t\r\n' '   ')
    printf '%s\t%s\n' "$key" "$value" >>"$METADATA_FILE"
}

host_cpu_name() {
    local value=""

    if command -v sysctl >/dev/null 2>&1; then
        value=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    fi
    if [[ -z "$value" && -r /proc/cpuinfo ]]; then
        value=$(awk -F ': *' '/model name/ { print $2; exit }' /proc/cpuinfo)
    fi
    printf '%s\n' "${value:-unknown}"
}

host_memory_bytes() {
    local value=""

    if command -v sysctl >/dev/null 2>&1; then
        value=$(sysctl -n hw.memsize 2>/dev/null || true)
    fi
    if [[ -z "$value" && -r /proc/meminfo ]]; then
        value=$(awk '/MemTotal/ { print $2 * 1024; exit }' /proc/meminfo)
    fi
    printf '%s\n' "${value:-unknown}"
}

host_logical_cpus() {
    local value=""

    if command -v getconf >/dev/null 2>&1; then
        value=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    fi
    if [[ -z "$value" && -x /usr/sbin/sysctl ]]; then
        value=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || true)
    fi
    printf '%s\n' "${value:-unknown}"
}

write_metadata() {
    local image
    local digest
    local selected="all"
    local git_state="clean"
    local trivy_backend
    local trivy_digest

    if [[ -n "${SELECTED_VARIANTS[0]+set}" ]]; then
        selected=$(IFS=,; printf '%s' "${SELECTED_VARIANTS[*]}")
    fi
    [[ -z "$(git -C "$BENCHMARK_ROOT" status --porcelain --untracked-files=normal 2>/dev/null)" ]] || git_state="dirty"

    : >"$METADATA_FILE"
    metadata_put format_version 1
    metadata_put run_id "$BENCHMARK_RUN_ID"
    metadata_put started_at_utc "$BENCHMARK_STARTED_AT"
    metadata_put git_commit "$(git -C "$BENCHMARK_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
    metadata_put git_state "$git_state"
    metadata_put selected_variants "$selected"
    metadata_put host_os "$(uname -srm)"
    metadata_put host_arch "$(uname -m)"
    metadata_put host_cpu "$(host_cpu_name)"
    metadata_put host_logical_cpus "$(host_logical_cpus)"
    metadata_put host_memory_bytes "$(host_memory_bytes)"
    metadata_put docker_client "$(docker version --format '{{.Client.Version}}')"
    metadata_put docker_server "$(docker version --format '{{.Server.Version}}')"
    metadata_put docker_engine "$(docker info --format '{{.OperatingSystem}} ({{.Architecture}})')"
    metadata_put buildkit_driver docker-container
    metadata_put startup_runs "$STARTUP_RUNS"
    metadata_put startup_timeout_seconds "$STARTUP_TIMEOUT"
    metadata_put polling_interval_seconds 0.1
    metadata_put memory_limit "$MEMORY_LIMIT"
    metadata_put memory_delay_seconds "$MEMORY_DELAY_SECONDS"

    if [[ "$SKIP_TRIVY" == "1" ]]; then
        trivy_backend="skipped"
    elif command -v trivy >/dev/null 2>&1; then
        trivy_backend=$(trivy --version 2>/dev/null | head -1)
    else
        trivy_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$TRIVY_IMAGE" 2>/dev/null || true)
        trivy_backend="container ${trivy_digest:-$TRIVY_IMAGE}"
    fi
    metadata_put trivy_backend "$trivy_backend"

    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)
        metadata_put base_image "${digest:-$image}"
    done < <(benchmark_base_images)
}

benchmark_orchestrator_cleanup() {
    benchmark_cleanup

    if [[ "$BENCHMARK_KEEP_ARTIFACTS" == "1" ]]; then
        [[ -n "$WORK_DIR" ]] && benchmark_log "Temporary work kept at ${WORK_DIR}"
        benchmark_log "Builder kept: ${BUILDER_NAME}"
        return 0
    fi

    docker buildx rm "$BUILDER_NAME" >/dev/null 2>&1 || true
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}

install_orchestrator_traps() {
    trap 'benchmark_orchestrator_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

prepare_builder() {
    local image
    local index=0
    local preload_context="$WORK_DIR/base-context"
    local preload_file

    benchmark_log "Creating isolated BuildKit builder ${BUILDER_NAME}"
    docker buildx create \
        --name "$BUILDER_NAME" \
        --driver docker-container >/dev/null
    docker buildx inspect --builder "$BUILDER_NAME" --bootstrap >/dev/null

    mkdir -p "$preload_context"
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        index=$((index + 1))
        preload_file="$WORK_DIR/base-${index}.Dockerfile"
        printf 'FROM %s\n' "$image" >"$preload_file"
        benchmark_log "Preloading ${image} into the isolated builder"
        docker buildx build \
            --builder "$BUILDER_NAME" \
            --progress quiet \
            --file "$preload_file" \
            "$preload_context" >/dev/null
    done < <(benchmark_base_images)
}

clear_builder_exec_cache() {
    benchmark_log "Clearing Maven cache mounts in the isolated builder"
    docker buildx prune \
        --builder "$BUILDER_NAME" \
        --force \
        --filter type=exec.cachemount >/dev/null
}

build_variant() {
    local dockerfile="$1"
    local context="$2"
    local image_tag="$3"
    local log_file="$4"
    local no_cache="$5"
    local args=(
        docker buildx build
        --builder "$BUILDER_NAME"
        --load
        --provenance=false
        --progress plain
        --file "$dockerfile"
        --tag "$image_tag"
    )

    [[ "$no_cache" == "1" ]] && args+=(--no-cache)
    args+=("$context")

    if benchmark_run_timed "${args[@]}" >"$log_file" 2>&1; then
        return 0
    fi

    benchmark_warn "Build failed; last output from ${log_file}:"
    tail -80 "$log_file" >&2 || true
    return 1
}

create_modified_context() {
    local destination="$1"

    mkdir -p "$destination"
    cp -R "$BENCHMARK_ROOT/." "$destination/"
    # Constant content changes COPY src relative to the original context while
    # keeping the rebuilt artifact byte-stable across independent benchmark runs.
    printf 'benchmark.cache-buster=true\n' \
        >"$destination/src/main/resources/benchmark-cache-buster.properties"
}

wait_for_container_http() {
    local container_id="$1"
    local container_port="$2"
    local timeout_seconds="$3"
    local host_port=""
    local deadline_ms
    local now_ms
    local http_code

    now_ms=$(benchmark_now_ms)
    deadline_ms=$((now_ms + timeout_seconds * 1000))

    while true; do
        host_port=$(docker inspect --format \
            "{{(index (index .NetworkSettings.Ports \"${container_port}/tcp\") 0).HostPort}}" \
            "$container_id" 2>/dev/null || true)

        if [[ -n "$host_port" ]]; then
            http_code=$(curl --silent \
                --output /dev/null \
                --write-out '%{http_code}' \
                --connect-timeout 0.2 \
                --max-time 0.5 \
                "http://127.0.0.1:${host_port}/actuator/health" || true)
            [[ "$http_code" == "200" ]] && return 0
        fi

        if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != "true" ]]; then
            docker logs --tail 50 "$container_id" >&2 || true
            benchmark_die "Container exited before readiness"
            return 1
        fi

        now_ms=$(benchmark_now_ms)
        [[ "$now_ms" -lt "$deadline_ms" ]] || {
            docker logs --tail 50 "$container_id" >&2 || true
            benchmark_die "Container readiness timed out after ${timeout_seconds}s"
            return 1
        }
        sleep 0.1
    done
}

memory_to_mib() {
    local usage="$1"
    local value="${usage%% *}"
    local number
    local factor

    case "$value" in
        *GiB) number=${value%GiB}; factor=1024 ;;
        *MiB) number=${value%MiB}; factor=1 ;;
        *KiB) number=${value%KiB}; factor=0.0009765625 ;;
        *GB)  number=${value%GB};  factor=953.67431640625 ;;
        *MB)  number=${value%MB};  factor=0.95367431640625 ;;
        *kB)  number=${value%kB};  factor=0.00095367431640625 ;;
        *B)   number=${value%B};   factor=0.00000095367431640625 ;;
        *)
            benchmark_die "Unsupported docker stats memory value: ${usage}"
            return 1
            ;;
    esac

    awk -v number="$number" -v factor="$factor" \
        'BEGIN { printf "%.2f\n", number * factor }'
}

measure_memory_mib() {
    local variant="$1"
    local image_tag="$2"
    local container_name
    local container_id
    local memory_usage
    local memory_mib

    container_name=$(benchmark_container_name "${variant}-memory" 1)
    benchmark_register_container "$container_name"

    container_id=$(docker run --detach \
        --name "$container_name" \
        --memory "$MEMORY_LIMIT" \
        --publish 127.0.0.1::8080 \
        "$image_tag")

    wait_for_container_http "$container_id" 8080 "$STARTUP_TIMEOUT"
    sleep "$MEMORY_DELAY_SECONDS"
    memory_usage=$(docker stats --no-stream --format '{{.MemUsage}}' "$container_id")
    memory_mib=$(memory_to_mib "$memory_usage")

    docker rm -f "$container_name" >/dev/null 2>&1 || true
    MEASURED_MEMORY_MIB="$memory_mib"
}

count_trivy_severities() {
    local json_file="$1"

    awk '
        BEGIN {
            counts["CRITICAL"] = 0
            counts["HIGH"] = 0
            counts["MEDIUM"] = 0
            counts["LOW"] = 0
            counts["UNKNOWN"] = 0
        }
        /"Severity"[[:space:]]*:/ {
            severity = $0
            sub(/^.*"Severity"[[:space:]]*:[[:space:]]*"/, "", severity)
            sub(/".*$/, "", severity)
            if (severity in counts) counts[severity]++
        }
        END {
            printf "%d\t%d\t%d\t%d\t%d\n", \
                counts["CRITICAL"], counts["HIGH"], counts["MEDIUM"], \
                counts["LOW"], counts["UNKNOWN"]
        }
    ' "$json_file"
}

scan_image() {
    local variant="$1"
    local image_tag="$2"
    local json_file="$WORK_DIR/trivy-${variant}.json"
    local archive_file="$WORK_DIR/image-${variant}.tar"

    if [[ "$SKIP_TRIVY" == "1" ]]; then
        printf 'NA\tNA\tNA\tNA\tNA\n'
        return 0
    fi

    benchmark_log "Scanning ${variant} with Trivy"
    if command -v trivy >/dev/null 2>&1; then
        trivy image \
            --quiet \
            --scanners vuln \
            --format json \
            --output "$json_file" \
            "$image_tag"
    else
        docker save --output "$archive_file" "$image_tag"
        docker run --rm \
            --volume "${TRIVY_CACHE_VOLUME}:/root/.cache/trivy" \
            --volume "${archive_file}:/scan/image.tar:ro" \
            "$TRIVY_IMAGE" image \
                --quiet \
                --scanners vuln \
                --format json \
                --input /scan/image.tar >"$json_file"
    fi

    count_trivy_severities "$json_file"
}

prepare_trivy() {
    [[ "$SKIP_TRIVY" == "1" ]] && return 0
    command -v trivy >/dev/null 2>&1 && return 0

    benchmark_log "Local Trivy not found; pulling ${TRIVY_IMAGE}"
    docker pull "$TRIVY_IMAGE" >/dev/null
}

benchmark_variant() {
    local dockerfile="$1"
    local variant="$2"
    local image_tag
    local rebuild_context="$WORK_DIR/context-${variant}"
    local cold_ms
    local warm_ms
    local rebuild_ms
    local size_bytes
    local startup_ms
    local memory_mib
    local severities

    image_tag=$(benchmark_image_tag "$variant")
    benchmark_register_image "$image_tag"
    benchmark_log "===== Variant ${variant} ====="

    clear_builder_exec_cache

    benchmark_log "Cold build (${variant})"
    build_variant "$dockerfile" "$BENCHMARK_ROOT" "$image_tag" \
        "$WORK_DIR/${variant}-cold.log" 1
    cold_ms="$BENCHMARK_LAST_DURATION_MS"

    benchmark_log "Warm build (${variant})"
    build_variant "$dockerfile" "$BENCHMARK_ROOT" "$image_tag" \
        "$WORK_DIR/${variant}-warm.log" 0
    warm_ms="$BENCHMARK_LAST_DURATION_MS"

    benchmark_log "Rebuild after source-only change (${variant})"
    create_modified_context "$rebuild_context"
    build_variant "$rebuild_context/docker/$(basename "$dockerfile")" \
        "$rebuild_context" "$image_tag" "$WORK_DIR/${variant}-rebuild.log" 0
    rebuild_ms="$BENCHMARK_LAST_DURATION_MS"

    size_bytes=$(docker image inspect --format '{{.Size}}' "$image_tag")
    startup_ms=$("$SCRIPT_DIR/measure-startup.sh" \
        --image "$image_tag" \
        --variant "$variant" \
        --runs "$STARTUP_RUNS" \
        --timeout "$STARTUP_TIMEOUT" \
        --memory "$MEMORY_LIMIT" \
        --quiet)
    measure_memory_mib "$variant" "$image_tag"
    memory_mib="$MEASURED_MEMORY_MIB"
    severities=$(scan_image "$variant" "$image_tag")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$variant" "docker/$(basename "$dockerfile")" \
        "$cold_ms" "$warm_ms" "$rebuild_ms" "$size_bytes" \
        "$startup_ms" "$memory_mib" "$MEMORY_LIMIT" "$severities" \
        >>"$OUTPUT_FILE"

    benchmark_log "Completed ${variant}: cold=${cold_ms}ms warm=${warm_ms}ms rebuild=${rebuild_ms}ms startup=${startup_ms}ms"
}

main() {
    local dockerfile
    local variant
    local matched=0

    parse_args "$@"
    benchmark_preflight
    benchmark_require_command curl
    benchmark_require_command cp
    benchmark_require_command tail
    docker buildx version >/dev/null 2>&1 || benchmark_die "Docker Buildx is required"

    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/showcase-benchmark.XXXXXX")
    install_orchestrator_traps
    mkdir -p "$(dirname "$OUTPUT_FILE")"

    [[ "$SKIP_PULL" == "1" ]] || benchmark_pull_base_images
    prepare_trivy
    write_metadata
    prepare_builder

    printf 'variant\tdockerfile\tcold_build_ms\twarm_build_ms\trebuild_ms\tsize_bytes\tstartup_ms\tmemory_mib\tmemory_limit\tcritical\thigh\tmedium\tlow\tunknown\n' \
        >"$OUTPUT_FILE"

    for dockerfile in "$BENCHMARK_ROOT"/docker/Dockerfile-*; do
        [[ -f "$dockerfile" ]] || continue
        [[ "$dockerfile" == *.dockerignore ]] && continue
        variant=$(basename "$dockerfile")
        variant=${variant#Dockerfile-}
        variant_selected "$variant" || continue

        matched=$((matched + 1))
        benchmark_variant "$dockerfile" "$variant"
    done

    [[ "$matched" -gt 0 ]] || benchmark_die "No Dockerfile matched the selected variants"
    benchmark_log "Raw results written to ${OUTPUT_FILE}"
    if [[ "$GENERATE_REPORT" == "1" ]]; then
        "$SCRIPT_DIR/generate-report.sh" \
            --input "$OUTPUT_FILE" \
            --metadata "$METADATA_FILE" \
            --output "$REPORT_FILE"
        benchmark_log "Markdown report written to ${REPORT_FILE}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
