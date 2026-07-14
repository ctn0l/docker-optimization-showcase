# Docker Optimization Showcase

[![CI](https://github.com/ctn0l/docker-optimization-showcase/actions/workflows/ci.yml/badge.svg)](https://github.com/ctn0l/docker-optimization-showcase/actions/workflows/ci.yml)

This project puts the same small Spring Boot application into five progressively better Docker "boxes". The application does not change: only the way it is packaged changes.

The goal is to show, with real measurements, how a better Docker image can use less disk space and memory, start faster, rebuild faster, and contain fewer known vulnerabilities.

## My results dashboard

These are results measured on my machine on **14 July 2026**. They describe this specific test environment, so another computer or network may produce different timings.

**Test environment:** Apple M5 Pro (18 logical CPUs, ARM64), 64 GB RAM, macOS, Docker Desktop 29.5.3, Java 25, Spring Boot 4.1.0.

| Step | What changed | Image size | Startup | Memory | Critical / High vulnerabilities |
|---|---|---:|---:|---:|---:|
| 1. Naive | The whole project is copied into a full Java image | 261.5 MiB | 1.24 s | 209.9 MiB | 0 / 12 |
| 2. Multi-stage | Build tools are removed from the final image | 128.3 MiB | 1.23 s | 199.1 MiB | 0 / 7 |
| 3. Cache | Dependencies and image layers are reused | 128.3 MiB | 1.16 s | 199.1 MiB | 0 / 7 |
| 4. Slim | Only the Java parts needed by the app are included | **62.3 MiB** | 1.29 s | 132.2 MiB | **0 / 0** |
| 5. AOT | Frequently used Java code is prepared in advance | 75.4 MiB | **0.67 s** | **94.4 MiB** | **0 / 0** |

From the first image to the final AOT image:

- the image is **71% smaller**;
- startup is **46% faster**;
- memory use is about **55% lower**;
- High vulnerabilities went from **12 to 0**, while Critical vulnerabilities remained at 0.

There is no single winner for every need. Step 4 produces the smallest image. Step 5 is about 13 MiB larger, but it starts much faster and uses the least memory.

Build speed is a separate measurement. A **cold build** starts without a project cache, a **warm build** repeats the same build, and a **code rebuild** changes only application code.

| Step | Cold build | Warm build | Code rebuild |
|---|---:|---:|---:|
| 1. Naive | 71.95 s | 3.20 s | 51.93 s |
| 2. Multi-stage | 83.51 s | 2.18 s | 3.41 s |
| 3. Cache | 80.92 s | 2.44 s | **3.25 s** |
| 4. Slim | 109.50 s | 1.59 s | 6.67 s |
| 5. AOT | 87.73 s | **1.56 s** | 5.34 s |

This shows the main benefit of correct Docker layers: after a code-only change, the optimized images rebuild in a few seconds instead of rebuilding almost everything.

### What do these numbers mean?

- **Image size:** space needed to store and transfer the packaged application.
- **Startup:** time from starting the container until the application reports that it is ready.
- **Memory:** RAM used by the running container after a 10-second settling period.
- **Vulnerabilities:** known security issues found in the operating-system and application packages by Trivy.

Startup is the median of five launches. Build times can vary more because downloads, the network, and Docker's cache affect them.

## The five steps

### 1. Naive starting point

The [naive image](docker/Dockerfile-1-naive) copies the whole project and builds it inside one full Java image. It is easy to write, but it also keeps tools and files that the running application does not need.

### 2. Separate building from running

The [multi-stage image](docker/Dockerfile-2-multistage) adds a separate build stage. Compared with step 1, only the finished application and a smaller Java runtime reach the final image.

### 3. Reuse work

The [cached and layered image](docker/Dockerfile-3-cache) improves step 2 by keeping dependencies separate from frequently changing source code. Docker can then reuse most previous work after a small code change.

### 4. Include only what is needed

The [slim image](docker/Dockerfile-4-slim) improves step 3 by using `jlink` to create a custom Java runtime. It also runs as a non-root user and includes a health check. This is the smallest variant.

### 5. Prepare startup in advance

The [AOT image](docker/Dockerfile-5-aot) starts from step 4 and adds a Java AOT cache. Commonly used classes are prepared while the image is built, trading a little more disk space for faster startup and lower runtime memory in this test.

## Try it yourself

You only need [Git](https://git-scm.com/) and [Docker Desktop](https://www.docker.com/products/docker-desktop/).

Clone the project and build the final image:

```bash
git clone https://github.com/ctn0l/docker-optimization-showcase.git
cd docker-optimization-showcase
make build-5-aot
```

Start the application:

```bash
docker run --rm -p 8080:8080 docker-optimization-showcase:5-aot
```

When the startup messages stop, open these pages in a browser:

- [Application information](http://localhost:8080/api/v1/info) — you should see a short JSON response containing the app and Java version.
- [Health check](http://localhost:8080/actuator/health) — you should see `{"status":"UP"}`.

Press `Ctrl+C` in the terminal to stop the application.

## Reproduce the complete benchmark

Run:

```bash
make benchmark
```

This builds and measures all five images, downloads the Trivy security database, and creates a local report at `docs/RESULTS.md`. It can take several minutes and use a few gigabytes of temporary disk space.

Useful commands:

```bash
make help       # Show all commands
make verify     # Run the automated application tests
make build-all  # Build all five images
make report     # Recreate the report from existing measurements
make clean      # Remove benchmark results and project images
```

The benchmark logic is in [`scripts/`](scripts/). The shell automation in that directory was generated with AI assistance at my request, then reviewed and tested locally.

## Automatic checks

Every push and pull request runs GitHub Actions to:

1. test the Java application;
2. build all five Docker images;
3. scan the final image with Trivy and fail if a Critical vulnerability is found.

## License

This project is available under the [MIT License](LICENSE).
