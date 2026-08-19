# Building a Multi-Architecture Docker Image for OpenSearch Dashboards

This page describes how to produce a single Docker image manifest that supports `linux/amd64` (x64), `linux/arm64`, `linux/ppc64le`, and `linux/s390x` from an x64-built OpenSearch Dashboards tarball, using Red Hat Universal Base Image (UBI9) Node.js as the base.

## Background

The standard `assemble.sh` workflow produces a tarball that bundles an architecture-specific Node.js binary at `node/bin/node`. This binary is a native ELF executable compiled for the target CPU — it cannot run on a different architecture. This limits the standard Docker release scripts to `x64` and `arm64` only, as those are the only architectures supported by `build.sh` and `assemble.sh`.

Two additional architectures — `ppc64le` and `s390x` — are not supported by the OpenSearch Dashboards build system (`build_args.py` allows only `x64` and `arm64`). QEMU emulation is unreliable for `s390x` and too slow for production use on either architecture.

## Key Discovery

Inspecting the OSD 3.7.0 assembled tarball reveals that **all 70,427 files across core and all 15 plugins are pure JavaScript** — no native compiled `.node` C++ addon files are present. Every plugin ships as a webpack-bundled JavaScript artifact. The only architecture-specific binary in the entire tarball is `node/bin/node` itself.

Furthermore, the `bin/use_node` script that all OSD entrypoints use resolves its Node.js binary through the following fallback chain:

```
1. $OSD_NODE_HOME/bin/node    ← env var override, highest priority
2. $NODE_HOME/bin/node        ← env var override
3. $OSD_HOME/node/bin/node    ← bundled binary (removed in this solution)
4. $(command -v node)         ← system-wide PATH ← used by this solution
```

If the `node/` directory is absent, `use_node` automatically falls through to whatever `node` binary is on the system `PATH`.

## Solution

Use `registry.access.redhat.com/ubi9/nodejs-22-minimal` as the Docker base image. Red Hat publishes this image natively for `amd64`, `arm64`, `ppc64le`, and `s390x`. During the Docker build:

1. The x64 tarball is unpacked (same tarball for all architectures — it contains only pure JS).
2. The bundled `node/` directory is deleted: `rm -rf $OPENSEARCH_DASHBOARDS_HOME/node`.
3. At runtime, `use_node` falls through to the arch-native Node.js from the base image.
4. `docker buildx` automatically selects the correct `nodejs-22-minimal` variant per architecture.

This means **you only need to build the OSD tarball once on x64**. The same tarball is used to produce images for all four architectures.

### Architecture support summary

| Architecture | Standard build + assemble | Standard Docker scripts | This solution |
|---|---|---|---|
| x64 / amd64 | ✅ | ✅ | ✅ |
| arm64 | ✅ | ✅ | ✅ |
| ppc64le | ❌ not supported | ❌ | ✅ |
| s390x | ❌ not supported | ❌ | ✅ |

## Dockerfile

The Dockerfile implementing this solution is at [`docker/release/dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile`](https://github.com/opensearch-project/opensearch-build/blob/main/docker/release/dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile).

It is a two-stage build:

- **Stage 0** (`ubi9/nodejs-22-minimal`): unpacks the tarball, removes `node/`, applies config files and entrypoint scripts.
- **Stage 1** (`ubi9/nodejs-22-minimal`): clean runtime image, copies the configured installation from Stage 0.

The key line in Stage 0:

```dockerfile
# Remove the arch-specific bundled Node.js — system Node from base image is used instead
RUN rm -rf $OPENSEARCH_DASHBOARDS_HOME/node
```

## Prerequisites

- A Red Hat account is required to pull `registry.access.redhat.com/ubi9/nodejs-22-minimal`:
  ```bash
  docker login registry.access.redhat.com
  ```
- Docker with `buildx` support. For building non-native architectures on an x64 host, install QEMU emulation (one-time setup):
  ```bash
  docker run --privileged --rm tonistiigi/binfmt --install all
  ```
  > **Note**: QEMU is suitable for building the Docker image layers (which are light operations). It is **not** suitable for running the full `build.sh` / `assemble.sh` pipeline on `s390x`.

## Build Steps

### Step 1 — Assemble the x64 tarball

If not already done, assemble the OpenSearch Dashboards distribution. See [Building a Distribution from the source](Building-an-OpenSearch-and-OpenSearch-Dashboards-Distribution) for the full build workflow.

```bash
docker run --rm \
  -v "$(pwd)":/opensearch-build \
  -w /opensearch-build \
  python:3.9-slim-bookworm \
  bash -c "
    apt-get update -q && apt-get install -y bash && pip install pipenv &&
    LANG=C.UTF-8 ./assemble.sh tar/builds/opensearch-dashboards/manifest.yml -v
  "
```

Output: `tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-x64.tar.gz`

### Step 2 — Build a single-arch image locally (no push)

Use this to build and test locally before pushing to a registry.

```bash
cd docker/release

./build-image-single-arch.sh \
  -v 3.7.0 \
  -p opensearch-dashboards \
  -a x64 \
  -f dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile \
  -t ../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-x64.tar.gz
```

This produces a local image tagged `opensearchproject/opensearch-dashboards:3.7.0`. Re-tag it for your registry before the next arch overwrites the tag:

```bash
docker tag opensearchproject/opensearch-dashboards:3.7.0 \
  icr.io/wxd_dev/opensearch-dashboards:3.7.0-x64
```

Repeat for `arm64` (requires an arm64-built tarball — see [Architecture notes](#architecture-notes) below):

```bash
./build-image-single-arch.sh \
  -v 3.7.0 \
  -p opensearch-dashboards \
  -a arm64 \
  -f dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile \
  -t ../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-arm64.tar.gz

docker tag opensearchproject/opensearch-dashboards:3.7.0 \
  icr.io/wxd_dev/opensearch-dashboards:3.7.0-arm64
```

For `ppc64le` and `s390x`, the x64 tarball is reused (same pure-JS content):

```bash
# ppc64le — build directly with docker buildx (build-image-single-arch.sh does not support these arches)
docker buildx build \
  --platform linux/ppc64le \
  --build-arg VERSION=3.7.0 \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --build-arg NOTES="local" \
  -f dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile \
  --load \
  -t icr.io/wxd_dev/opensearch-dashboards:3.7.0-ppc64le \
  /tmp/osd-build-context   # directory containing the tarball renamed to opensearch-dashboards-ppc64.tgz + config files

# s390x — same pattern with --platform linux/s390x
```

### Step 3 — Build multi-arch and push (x64 + arm64)

`build-image-multi-arch.sh` always pushes to a registry. Use this for `x64` and `arm64`:

```bash
cd docker/release

./build-image-multi-arch.sh \
  -v 3.7.0 \
  -p opensearch-dashboards \
  -a x64,arm64 \
  -f dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile \
  -r icr.io/wxd_dev/opensearch-dashboards \
  -t "../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-x64.tar.gz,\
../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-arm64.tar.gz"
```

### Step 4 — Assemble the final multi-arch manifest

Once all per-arch images are pushed:

```bash
docker login icr.io

docker push icr.io/wxd_dev/opensearch-dashboards:3.7.0-x64
docker push icr.io/wxd_dev/opensearch-dashboards:3.7.0-arm64
docker push icr.io/wxd_dev/opensearch-dashboards:3.7.0-ppc64le
docker push icr.io/wxd_dev/opensearch-dashboards:3.7.0-s390x

docker manifest create icr.io/wxd_dev/opensearch-dashboards:3.7.0 \
  icr.io/wxd_dev/opensearch-dashboards:3.7.0-x64 \
  icr.io/wxd_dev/opensearch-dashboards:3.7.0-arm64 \
  icr.io/wxd_dev/opensearch-dashboards:3.7.0-ppc64le \
  icr.io/wxd_dev/opensearch-dashboards:3.7.0-s390x

docker manifest push icr.io/wxd_dev/opensearch-dashboards:3.7.0
```

Docker will now resolve the correct image variant automatically based on the pulling host's architecture.

## Architecture notes

### arm64
A separate arm64 tarball must be built natively — `assemble.sh` supports `arm64` and the Node.js binary bundled inside must be arm64. Run `build.sh` and `assemble.sh` on an arm64 CI runner or machine. The `node/` directory is then deleted in the Dockerfile as with x64.

### ppc64le and s390x
These architectures are **not supported by `build.sh` or `assemble.sh`**. However, since the tarball contains only pure JavaScript, the x64 tarball is used directly. The `node/` directory is removed during the Docker build and the arch-native Node.js from `ubi9/nodejs-22-minimal` takes over. No native build on ppc64le or s390x hardware is required.

> **Important**: `build-image-single-arch.sh` and `build-image-multi-arch.sh` validate architecture values and will reject `ppc64le` and `s390x`. Use `docker buildx build` directly with the Dockerfile for these architectures, or patch the `-a` validation in the release scripts.

## Caveats

### Node.js version compatibility
The `nodejs-22-minimal` base image provides Node.js 22. Verify that the version of OSD you are building lists Node 22 as a supported runtime in its `.nvmrc` or `package.json` `engines` field. For OSD 3.7.0, Node 22 is supported.

### reportsDashboards plugin (PDF generation)
The `reportsDashboards` plugin uses headless Chromium to generate PDF reports. This requires `nss`, `fontconfig`, and `freetype` — all included in the Dockerfile. Full `xorg-x11-fonts-*` packages are not available in `ubi9-minimal` repositories. If PDF report generation fails due to missing fonts, consider switching the base to `registry.access.redhat.com/ubi9/ubi` (full UBI9) which has access to a wider set of packages.

### Native .node addons in future versions
The absence of native `.node` C++ addon files was verified against OSD 3.7.0. If a future version introduces native addons, this solution would require those specific modules to be recompiled for each target architecture, which would bring back a native build dependency. Verify with:

```bash
tar -tzf opensearch-dashboards-<version>-linux-x64.tar.gz | grep -E "\.node$"
```

If this command returns any output, those files are native addons and will need arch-specific handling.
