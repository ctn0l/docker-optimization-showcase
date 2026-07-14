SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

IMAGE_PREFIX ?= docker-optimization-showcase
RESULTS_TSV ?= target/benchmark/results.tsv
REPORT_MD ?= docs/RESULTS.md
BENCHMARK_ARGS ?=
BUILD_ARGS ?=
STARTUP_ARGS ?=
TRIVY_CACHE_VOLUME ?= showcase-trivy-cache

DOCKERFILES := $(filter-out %.dockerignore,$(wildcard docker/Dockerfile-*))
VARIANTS := $(patsubst docker/Dockerfile-%,%,$(DOCKERFILES))
BUILD_TARGETS := $(addprefix build-,$(VARIANTS))

.PHONY: help verify build-all $(BUILD_TARGETS) benchmark report startup clean-results clean-images clean clean-all

help: ## Show the available targets and configurable variables
	@printf 'Docker Optimization Showcase\n\n'
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_.%-]+:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nVariables:\n'
	@printf '  %-16s %s\n' 'IMAGE_PREFIX' 'Image repository prefix'
	@printf '  %-16s %s\n' 'BENCHMARK_ARGS' 'Extra arguments passed to benchmark.sh'
	@printf '  %-16s %s\n' 'BUILD_ARGS' 'Extra arguments passed to docker build'
	@printf '  %-16s %s\n' 'STARTUP_ARGS' 'Extra arguments passed to measure-startup.sh'
	@printf '  %-16s %s\n' 'RESULTS_TSV' 'Raw benchmark results path'
	@printf '  %-16s %s\n' 'REPORT_MD' 'Generated Markdown report path'

verify: ## Run the Maven verification suite
	./mvnw verify

build-all: $(BUILD_TARGETS) ## Build all five Dockerfile variants

$(BUILD_TARGETS): build-%:
	@printf '[make] Building %s:%s\n' '$(IMAGE_PREFIX)' '$*'
	DOCKER_BUILDKIT=1 docker build \
		--file docker/Dockerfile-$* \
		--tag $(IMAGE_PREFIX):$* \
		$(BUILD_ARGS) \
		.

benchmark: ## Run the complete benchmark and generate the Markdown report
	./scripts/benchmark.sh \
		--output $(RESULTS_TSV) \
		--report $(REPORT_MD) \
		$(BENCHMARK_ARGS)

report: ## Regenerate the Markdown report from existing raw results
	./scripts/generate-report.sh \
		--input $(RESULTS_TSV) \
		--metadata $(RESULTS_TSV).meta.tsv \
		--output $(REPORT_MD)

startup: ## Measure startup for IMAGE=<tag>; accepts STARTUP_ARGS
	@test -n "$(IMAGE)" || { printf 'Usage: make startup IMAGE=<tag> [STARTUP_ARGS="..."]\n' >&2; exit 2; }
	./scripts/measure-startup.sh --image $(IMAGE) $(STARTUP_ARGS)

clean-results: ## Remove raw benchmark output and generated report
	rm -rf target/benchmark
	rm -f $(REPORT_MD)

clean-images: ## Remove only project images and leftover benchmark containers
	@containers="$$(docker ps -aq --filter name=showcase-benchmark-)"; \
	if [[ -n "$$containers" ]]; then docker rm -f $$containers >/dev/null; fi
	@for image in $$(docker image ls --format '{{.Repository}}:{{.Tag}}' | \
		awk -v prefix='$(IMAGE_PREFIX):' 'index($$0, prefix) == 1'); do \
		docker image rm -f "$$image" >/dev/null; \
	done

clean: clean-results clean-images ## Remove project results, images and temporary containers

clean-all: clean ## Also remove the persistent Trivy vulnerability database cache
	@docker volume rm $(TRIVY_CACHE_VOLUME) >/dev/null 2>&1 || true
