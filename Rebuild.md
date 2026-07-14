# Argo CD UBI9 Rebuild and Deployment Guide

## Overview

This guide covers rebuilding all Argo CD container images on a UBI9 base, pushing them to an
internal registry, and deploying via the official Argo CD Helm chart with image overrides.

- **Source Code (UBI9 fork):** https://github.com/vaibhavvsk/argo-cd/tree/v3.4.4_ubi9
- **Upstream Source Code:** https://github.com/argoproj/argo-cd
- **Helm Chart:** https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd
- **Version:** `v3.4.4`
- **UBI9 Dockerfile (server):** [`Dockerfile.ubi9`](../Dockerfile.ubi9)
- **UBI9 Dockerfile (CLI):** [`Dockerfile.cli.ubi9`](../Dockerfile.cli.ubi9)
- **Tool Versions:** [`hack/tool-versions.sh`](../hack/tool-versions.sh)

---

## Component Reference

All components, their upstream sources, pinned versions, deployment role, and internal UBI9 target images in one place.

### Core Argo CD Components

Argo CD builds **one binary** (`argocd`) shipped as a single image. Each Kubernetes Deployment
selects its component via a different command — rebuilding one UBI9 image covers all of them.

| Kubernetes Deployment | Container | args / command (from manifest) | Role | Upstream Image (v3.4.4) | Internal UBI9 Image |
|-----------------------|-----------|-------------------------------|------|------------------------|---------------------|
| `argocd-server` | main | `args: [/usr/local/bin/argocd-server]` · [manifest](../manifests/base/server/argocd-server-deployment.yaml) | Web UI, API server, CLI endpoint | `quay.io/argoproj/argocd:v3.4.4` | `registry.company.com/argocd/argocd:v3.4.4-ubi9` |
| `argocd-repo-server` | main | `args: [/usr/local/bin/argocd-repo-server]` · [manifest](../manifests/base/repo-server/argocd-repo-server-deployment.yaml) | Git access, Helm/Kustomize rendering | ↑ same image | ↑ same image |
| `argocd-application-controller` | main | `args: [/usr/local/bin/argocd-application-controller]` · [manifest](../manifests/base/application-controller/argocd-application-controller-statefulset.yaml) | Application reconciliation and sync | ↑ same image | ↑ same image |
| `argocd-applicationset-controller` | main | `args: [/usr/local/bin/argocd-applicationset-controller]` · [manifest](../manifests/base/applicationset-controller/argocd-applicationset-controller-deployment.yaml) | Dynamic Application generation | ↑ same image | ↑ same image |
| `argocd-notifications-controller` | main | `args: [/usr/local/bin/argocd-notifications]` · [manifest](../manifests/base/notification/argocd-notifications-controller-deployment.yaml) | Notification delivery | ↑ same image | ↑ same image |
| `argocd-dex-server` | init (`copyutil`) | `command: [/bin/cp, -n, /usr/local/bin/argocd, /shared/argocd-dex]` · [manifest](../manifests/base/dex/argocd-dex-server-deployment.yaml) | Copies argocd binary into shared volume for Dex | ↑ same image | ↑ same image |
| `argocd-dex-server` | main (`dex`) | `command: [/shared/argocd-dex, rundex]` · [manifest](../manifests/base/dex/argocd-dex-server-deployment.yaml) | Runs Dex SSO using the copied binary | `ghcr.io/dexidp/dex:v2.45.0` | `registry.company.com/argocd/dex:v2.45.0-ubi9` |
| `argocd-redis` | init (`secret-init`) | `command: [argocd, admin, redis-initial-password]` · [manifest](../manifests/base/redis/argocd-redis-deployment.yaml) | Generates Redis password secret | ↑ argocd image | ↑ argocd UBI9 image |
| `argocd-redis` | main (`redis`) | `args: [--save, --appendonly, no, --requirepass ...]` · [manifest](../manifests/base/redis/argocd-redis-deployment.yaml) | Cache and state storage | `public.ecr.aws/docker/library/redis:8.2.3-alpine` | `registry.company.com/argocd/redis:8.2.3-ubi9` |

### External Dependencies

These are **separate images** not part of the Argo CD binary, each requiring an independent UBI9 rebuild.

| Component | Source Repository | Upstream Image | Version in v3.4.4 | Required | Repo Image Config | Internal UBI9 Image |
|-----------|------------------|---------------|-------------------|----------|-------------------|---------------------|
| Redis | https://github.com/redis/redis | `public.ecr.aws/docker/library/redis` | `8.2.3-alpine` | Always | [argocd-redis-deployment.yaml](../manifests/base/redis/argocd-redis-deployment.yaml) · Helm: `redis.image` | `registry.company.com/argocd/redis:8.2.3-ubi9` |
| Dex | https://github.com/dexidp/dex | `ghcr.io/dexidp/dex` | `v2.45.0` | Only if SSO/OIDC enabled | [argocd-dex-server-deployment.yaml](../manifests/base/dex/argocd-dex-server-deployment.yaml) · Helm: `dex.image` | `registry.company.com/argocd/dex:v2.45.0-ubi9` |
| HAProxy | https://github.com/haproxy/haproxy | `public.ecr.aws/docker/library/haproxy` | `3.0.8-alpine` | HA deployments only | [redis-ha/chart/values.yaml](../manifests/ha/base/redis-ha/chart/values.yaml) · Helm: `redis-ha.haproxy.image` | `registry.company.com/argocd/haproxy:3.0.8-ubi9` |

### Helm Chart

| Component | Repository | Purpose |
|-----------|-----------|---------|
| Argo CD Helm Chart | https://github.com/argoproj/argo-helm | Deployment and lifecycle management via Helm |

### Rebuild Scope

| Scope | Images to Rebuild | Covers |
|-------|------------------|--------|
| **Standard** — all components | `argocd`, `redis`, `dex` | All core deployments + SSO |
| **Full HA** — all components | `argocd`, `redis`, `dex`, `haproxy` | All containers in an HA deployment |

---

## Build Instructions

### 0. Build the Argo CD Binary (Optional — local verification)

Before building the container image you can compile and verify the `argocd` binary directly on your machine:

```bash
make BIN_NAME=argocd-linux-amd64 GOOS=linux GOARCH=amd64 argocd-all
```

Output binary: `dist/argocd-linux-amd64`

**Sample output:**

```
$ ./dist/argocd-linux-amd64 version
argocd: v3.4.4+cfd9e76
  BuildDate: 2026-07-10T05:20:27Z
  GitCommit: cfd9e76783c3cfad473296157acb594099dc042a
  GitTreeState: clean
  GoVersion: go1.26.0
  Compiler: gc
  Platform: linux/amd64
{"level":"fatal","msg":"Argo CD server address unspecified","time":"2026-07-10T05:30:35Z"}
```

> **Note:** The `fatal` log at the end is expected — `argocd version` also tries to reach a live server for the server-side version. The binary itself is working correctly; the client-side version is printed first.

Other platform targets available via `argocd-all`:

| `BIN_NAME` | `GOOS` | `GOARCH` |
|---|---|---|
| `argocd-linux-amd64` | `linux` | `amd64` |
| `argocd-linux-arm64` | `linux` | `arm64` |
| `argocd-darwin-amd64` | `darwin` | `amd64` |
| `argocd-darwin-arm64` | `darwin` | `arm64` |
| `argocd-windows-amd64.exe` | `windows` | `amd64` |

---

### Makefile Variables Reference

| Variable | Default | Used by |
|---|---|---|
| `DOCKERFILE` | `Dockerfile` | `make image` |
| `CLI_DOCKERFILE` | `Dockerfile.cli.ubi9` | `make cli-image` |
| `IMAGE_TAG` | `latest` (or git tag if on a tag) | all image targets |
| `IMAGE_REGISTRY` | `quay.io` | all image targets |
| `IMAGE_NAMESPACE` | `argoproj` | all image targets |
| `TARGETOS` | `linux` | `make docker-build` |
| `TARGETARCH` | `amd64` | `make docker-build` |

---

### 1. Build the Argo CD Server Image

The dedicated UBI9 build target is `docker-build`. It uses [`Dockerfile.ubi9`](../Dockerfile.ubi9) and passes `TARGETOS`/`TARGETARCH` as build args. Tool versions (Helm, Kustomize, git-lfs) are pinned in [`hack/tool-versions.sh`](../hack/tool-versions.sh).

```bash
# Default build — linux/amd64, tagged quay.io/argoproj/argocd:latest
make docker-build

# With an explicit image tag
make docker-build IMAGE_TAG=v3.4.4_ubi9
```

Output: `quay.io/argoproj/argocd:v3.4.4_ubi9`

#### Cross-architecture builds

Override `TARGETARCH` (and optionally `TARGETOS`) at call time:

```bash
# arm64
make docker-build TARGETARCH=arm64 IMAGE_TAG=v3.4.4_ubi9

# ppc64le
make docker-build TARGETARCH=ppc64le IMAGE_TAG=v3.4.4_ubi9
```

#### All overridable variables

```bash
make docker-build \
  TARGETARCH=amd64 \
  TARGETOS=linux \
  IMAGE_TAG=v3.4.4_ubi9 \
  IMAGE_NAMESPACE=myorg \
  IMAGE_REGISTRY=registry.company.com
```

> **Alternative (legacy):** `make image DOCKERFILE=Dockerfile.ubi9 IMAGE_TAG=v3.4.4_ubi9` — uses the generic `image` target but requires passing `DOCKERFILE` explicitly to avoid building the default Ubuntu-based image.

#### Network requirements

The build pulls from these external endpoints — all must be reachable from the build host:

| Stage | Endpoint | What it fetches |
|---|---|---|
| `builder`, `argocd-build` | `dl.google.com` | Go 1.26.0 tarball |
| `argocd-ui` | `nodejs.org` | Node.js 23.0.0 tarball |
| `argocd-ui` | `registry.yarnpkg.com` | UI npm dependencies |
| `argocd-build` | `proxy.golang.org` / `sum.golang.org` | Go module dependencies |
| all `dnf` stages | `cdn.redhat.com` | UBI9 BaseOS + AppStream RPMs |

> **dnf tuning:** All `dnf` calls in `Dockerfile.ubi9` use `--disablerepo='*' --enablerepo='ubi-9-baseos-rpms,ubi-9-appstream-rpms'` to restrict to UBI9 public repos only, plus `--setopt=minrate=1 --setopt=timeout=30` to fail fast on stalled connections instead of hanging indefinitely.

> **curl-minimal:** `ubi9/ubi` and `ubi9/ubi-minimal` ship `curl-minimal` which conflicts with the full `curl` package — do not add `curl` to any `dnf`/`microdnf` install list in this Dockerfile.

#### Build stage summary

| Stage | Base image | Purpose |
|---|---|---|
| `builder` | `ubi9/ubi:9.8-1782841664` | Builds Helm, Kustomize, git-lfs binaries |
| `argocd-base` | `ubi9/ubi-minimal:9.8-1782797275` | Runtime base — packages, tini, user setup |
| `argocd-ui` | `ubi9/ubi:9.8-1782841664` | Builds UI assets (Node 23.0.0 via tarball) |
| `argocd-build` | `ubi9/ubi:9.8-1782841664` | Compiles Argo CD Go binary |
| final | `argocd-base` | Assembles runtime image |

### 1a. Build the Argo CD CLI Image (optional)

See [`Dockerfile.cli.ubi9`](../Dockerfile.cli.ubi9). Produces a minimal UBI9 image with only the `argocd` CLI binary — no UI assets, no server-side tools. Builds independently from the server image.

```bash
make cli-image CLI_DOCKERFILE=Dockerfile.cli.ubi9 IMAGE_TAG=v3.4.4_ubi9
```

Output: `quay.io/argoproj/argocd-cli:v3.4.4_ubi9`

> **Note:** Go is downloaded from `dl.google.com` (mirrors `go.dev/dl`) to avoid network restrictions. Subsequent builds reuse Docker layer cache — only the source compile step re-runs on code changes.

### 2. Build Redis on UBI9

```bash
# Create a minimal Dockerfile.redis-ubi9 wrapping redis 8.2.3
docker build -f Dockerfile.redis-ubi9 \
  -t registry.company.com/argocd/redis:8.2.3-ubi9 .
```

### 3. Build Dex on UBI9 (if SSO enabled)

```bash
git clone --branch v2.45.0 https://github.com/dexidp/dex
cd dex
# Replace base image with ubi9 in Dockerfile, then:
docker build -t registry.company.com/argocd/dex:v2.45.0-ubi9 .
```

### 4. Build HAProxy on UBI9 (HA only)

```bash
docker build -f Dockerfile.haproxy-ubi9 \
  -t registry.company.com/argocd/haproxy:3.0.8-ubi9 .
```

### 5. Push All Images

```bash
docker push registry.company.com/argocd/argocd:v3.4.4-ubi9
docker push registry.company.com/argocd/argocd-cli:v3.4.4-ubi9  # if CLI image built
docker push registry.company.com/argocd/redis:8.2.3-ubi9
docker push registry.company.com/argocd/dex:v2.45.0-ubi9        # if SSO enabled
docker push registry.company.com/argocd/haproxy:3.0.8-ubi9      # if HA
```

---

## Deployment Flow

```
argoproj/argo-cd (tag v3.4.4)
        │
        ▼
Replace base images → UBI9 (Dockerfile.ubi9)
        │
        ▼
Build & push to internal registry
        │
        ▼
Deploy via argo-helm/charts/argo-cd
        │
        ▼
Override image refs in values.yaml
        │
        ▼
kubectl apply / helm install → Kubernetes
```

---

## Helm values.yaml Overrides

Use the following `values.yaml` snippet to point all deployments to your internal UBI9 images.

```yaml
global:
  image:
    repository: registry.company.com/argocd/argocd
    tag: v3.4.4-ubi9

redis:
  image:
    repository: registry.company.com/argocd/redis
    tag: 8.2.3-ubi9

dex:
  image:
    repository: registry.company.com/argocd/dex
    tag: v2.45.0-ubi9

# HA only — overrides the redis-ha subchart
redis-ha:
  image:
    repository: registry.company.com/argocd/redis
    tag: 8.2.3-ubi9
  haproxy:
    image:
      repository: registry.company.com/argocd/haproxy
      tag: 3.0.8-ubi9
```

---

## Validate Rebuilt Images

### Verify UI assets are embedded

The UI is compiled into the `argocd` binary via Go's `//go:embed` directive — there are no UI files on disk in the final image. Validate by checking the binary size and confirming the embedded path is accessible:

```bash
IMAGE=quay.io/argoproj/argocd:latest

# Binary with UI embedded is typically >100 MB; without UI it would be ~50 MB
docker run --rm --entrypoint sh $IMAGE -c "ls -lh /usr/local/bin/argocd"

# Confirm the embedded UI file list is non-empty (Go embed exposes dist/app at runtime)
docker run --rm --entrypoint sh $IMAGE -c \
  "argocd version --client 2>/dev/null | head -5"
# Expected: prints argocd client version — confirms binary is healthy
```

### Verify all Argo CD component binaries are present

```bash
IMAGE=quay.io/argoproj/argocd:latest

docker run --rm --entrypoint argocd-server $IMAGE --help
docker run --rm --entrypoint argocd-repo-server $IMAGE --help
docker run --rm --entrypoint argocd-application-controller $IMAGE --help
docker run --rm --entrypoint argocd-applicationset-controller $IMAGE --help
docker run --rm --entrypoint argocd-notifications-controller $IMAGE --help
```

### Verify the CLI image

```bash
CLI_IMAGE=registry.company.com/argocd/argocd-cli:v3.4.4-ubi9

# Should print client-side version (fatal log at end is expected — no server running)
docker run --rm $CLI_IMAGE version

# Should print help text
docker run --rm $CLI_IMAGE --help
```

### Verify base OS is UBI9

```bash
docker run --rm $IMAGE cat /etc/os-release | grep -E "NAME|VERSION"
# Expected: Red Hat Enterprise Linux or Red Hat Universal Base Image 9
```

### Verify all images referenced in a Helm render

```bash
helm template argocd argo/argo-cd -f values.yaml | grep "image:"
```

This provides the definitive list of every container image in use. Confirm each resolves to a
UBI9-based image in your internal registry.

