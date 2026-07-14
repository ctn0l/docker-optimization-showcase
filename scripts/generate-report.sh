#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INPUT_FILE="$BENCHMARK_ROOT/target/benchmark/results.tsv"
METADATA_FILE=""
OUTPUT_FILE="$BENCHMARK_ROOT/docs/RESULTS.md"
TEMP_FILE=""

usage() {
    cat <<'EOF'
Usage: scripts/generate-report.sh [options]

Generate a Markdown benchmark report from the raw TSV results.

Options:
  --input FILE       Raw benchmark TSV (default: target/benchmark/results.tsv)
  --metadata FILE    Metadata TSV (default: INPUT.meta.tsv)
  --output FILE      Markdown report (default: docs/RESULTS.md)
  -h, --help         Show this help
EOF
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --input)
                [[ "$#" -ge 2 ]] || benchmark_die "--input requires a value"
                INPUT_FILE="$2"
                shift 2
                ;;
            --metadata)
                [[ "$#" -ge 2 ]] || benchmark_die "--metadata requires a value"
                METADATA_FILE="$2"
                shift 2
                ;;
            --output)
                [[ "$#" -ge 2 ]] || benchmark_die "--output requires a value"
                OUTPUT_FILE="$2"
                shift 2
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

    [[ "$INPUT_FILE" == /* ]] || INPUT_FILE="$BENCHMARK_ROOT/$INPUT_FILE"
    [[ "$OUTPUT_FILE" == /* ]] || OUTPUT_FILE="$BENCHMARK_ROOT/$OUTPUT_FILE"
    if [[ -z "$METADATA_FILE" ]]; then
        METADATA_FILE="${INPUT_FILE}.meta.tsv"
    elif [[ "$METADATA_FILE" != /* ]]; then
        METADATA_FILE="$BENCHMARK_ROOT/$METADATA_FILE"
    fi
}

metadata_value() {
    local key="$1"
    local fallback="${2:-not recorded}"
    local value=""

    if [[ -f "$METADATA_FILE" ]]; then
        value=$(awk -F '\t' -v key="$key" '$1 == key { print $2; exit }' "$METADATA_FILE")
    fi
    printf '%s\n' "${value:-$fallback}"
}

bytes_to_gib() {
    local bytes="$1"

    case "$bytes" in
        *[!0-9]*|'') printf '%s\n' "$bytes" ;;
        *) awk -v bytes="$bytes" 'BEGIN { printf "%.1f GiB\n", bytes / 1073741824 }' ;;
    esac
}

validate_input() {
    local expected_header
    local actual_header
    local row_count

    [[ -f "$INPUT_FILE" ]] || {
        benchmark_die "Results file not found: ${INPUT_FILE}"
        return 1
    }

    expected_header=$(printf 'variant\tdockerfile\tcold_build_ms\twarm_build_ms\trebuild_ms\tsize_bytes\tstartup_ms\tmemory_mib\tmemory_limit\tcritical\thigh\tmedium\tlow\tunknown')
    actual_header=$(sed -n '1p' "$INPUT_FILE")
    [[ "$actual_header" == "$expected_header" ]] || {
        benchmark_die "Unexpected results header in ${INPUT_FILE}"
        return 1
    }

    row_count=$(awk 'END { print NR - 1 }' "$INPUT_FILE")
    [[ "$row_count" -gt 0 ]] || {
        benchmark_die "Results file contains no variant rows"
        return 1
    }
}

write_environment() {
    local host_memory
    host_memory=$(bytes_to_gib "$(metadata_value host_memory_bytes unknown)")

    {
        printf '## Environment\n\n'
        printf -- '- Run ID: `%s`\n' "$(metadata_value run_id)"
        printf -- '- Started (UTC): `%s`\n' "$(metadata_value started_at_utc)"
        printf -- '- Git commit: `%s` (%s working tree)\n' \
            "$(metadata_value git_commit)" "$(metadata_value git_state unknown)"
        printf -- '- Host: %s, %s logical CPUs, %s RAM\n' \
            "$(metadata_value host_os)" "$(metadata_value host_logical_cpus)" "$host_memory"
        printf -- '- CPU: %s\n' "$(metadata_value host_cpu)"
        printf -- '- Docker: client `%s`, server `%s` — %s\n' \
            "$(metadata_value docker_client)" "$(metadata_value docker_server)" \
            "$(metadata_value docker_engine)"
        printf -- '- Builder: `%s`\n' "$(metadata_value buildkit_driver)"
        printf -- '- Trivy: %s\n' "$(metadata_value trivy_backend)"
        printf '\nBase images:\n\n'
    } >>"$TEMP_FILE"

    if [[ -f "$METADATA_FILE" ]] && awk -F '\t' '$1 == "base_image" { found=1 } END { exit !found }' "$METADATA_FILE"; then
        awk -F '\t' '$1 == "base_image" { printf "- `%s`\n", $2 }' "$METADATA_FILE" >>"$TEMP_FILE"
    else
        printf -- '- Not recorded\n' >>"$TEMP_FILE"
    fi
    printf '\n' >>"$TEMP_FILE"
}

write_results_table() {
    {
        printf '## Results\n\n'
        printf '| Variant | Cold build | Warm build | Source rebuild | Image size | Startup median | Memory RSS | Critical | High | Medium | Low | Unknown |\n'
        printf '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n'
    } >>"$TEMP_FILE"

    awk -F '\t' '
        function duration(value) {
            return value == "NA" ? "N/A" : sprintf("%.2f s", value / 1000)
        }
        function size(value) {
            return value == "NA" ? "N/A" : sprintf("%.1f MiB", value / 1048576)
        }
        function memory(value) {
            return value == "NA" ? "N/A" : sprintf("%.1f MiB", value)
        }
        function count(value) {
            return value == "NA" ? "N/A" : value
        }
        NR > 1 {
            printf "| [%s](../%s) | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
                $1, $2, duration($3), duration($4), duration($5), size($6), \
                duration($7), memory($8), count($10), count($11), count($12), \
                count($13), count($14)
        }
    ' "$INPUT_FILE" >>"$TEMP_FILE"
    printf '\n' >>"$TEMP_FILE"
}

write_highlights() {
    printf '## Highlights\n\n' >>"$TEMP_FILE"
    awk -F '\t' '
        NR == 2 {
            baseline_name = $1
            baseline_size = $6
            baseline_startup = $7
        }
        NR > 1 {
            rows++
            final_name = $1
            final_size = $6
            final_startup = $7
            if (smallest_size == "" || $6 < smallest_size) {
                smallest_size = $6
                smallest_name = $1
            }
            if (fastest_startup == "" || $7 < fastest_startup) {
                fastest_startup = $7
                fastest_name = $1
            }
        }
        END {
            printf "- Smallest image: **%s** at %.1f MiB.\n", smallest_name, smallest_size / 1048576
            printf "- Fastest startup: **%s** at %.2f s.\n", fastest_name, fastest_startup / 1000
            if (rows > 1 && baseline_size > 0 && baseline_startup > 0) {
                printf "- %s → %s: image size %+.1f%%; startup %+.1f%%.\n", \
                    baseline_name, final_name, \
                    (final_size - baseline_size) * 100 / baseline_size, \
                    (final_startup - baseline_startup) * 100 / baseline_startup
            }
        }
    ' "$INPUT_FILE" >>"$TEMP_FILE"
    printf '\n' >>"$TEMP_FILE"
}

write_methodology() {
    {
        printf '## Methodology\n\n'
        printf -- '- **Cold build:** isolated BuildKit builder, base images preloaded, regular layer cache disabled and Maven cache mount cleared.\n'
        printf -- '- **Warm build:** immediate rebuild of the unchanged context using the cache produced by the cold build.\n'
        printf -- '- **Source rebuild:** rebuild from an equivalent temporary context containing one additional generated application resource.\n'
        printf -- '- **Image size:** exact byte size reported by `docker image inspect`, displayed above in MiB.\n'
        printf -- '- **Startup:** time immediately before `docker run` to the first HTTP 200 from `/actuator/health`; median of %s runs, polling every %s s.\n' \
            "$(metadata_value startup_runs)" "$(metadata_value polling_interval_seconds)"
        printf -- '- **Memory:** `docker stats --no-stream` %s seconds after readiness, with a `%s` container limit.\n' \
            "$(metadata_value memory_delay_seconds)" "$(metadata_value memory_limit)"
        printf -- '- **Vulnerabilities:** Trivy vulnerability scanner counts by severity; `N/A` means the scan was explicitly skipped.\n'
        printf '\n## Reproduce\n\n'
        printf '```bash\n'
        printf './scripts/benchmark.sh\n'
        printf '```\n\n'
        printf '> This file is generated. Re-run the benchmark instead of editing it manually.\n'
    } >>"$TEMP_FILE"
}

main() {
    parse_args "$@"
    validate_input

    mkdir -p "$(dirname "$OUTPUT_FILE")"
    TEMP_FILE=$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")
    trap '[[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"' EXIT

    {
        printf '# Docker Optimization Benchmark Results\n\n'
        printf '> Automatically generated from `%s`.\n\n' "${INPUT_FILE#$BENCHMARK_ROOT/}"
    } >"$TEMP_FILE"

    write_environment
    write_results_table
    write_highlights
    write_methodology

    mv "$TEMP_FILE" "$OUTPUT_FILE"
    TEMP_FILE=""
    trap - EXIT
    benchmark_log "Generated ${OUTPUT_FILE}"
}

main "$@"
