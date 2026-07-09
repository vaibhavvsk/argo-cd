# Argo CD UBI9 Rebuild and Deployment Guide

## Overview

This guide covers rebuilding all Argo CD container images on a UBI9 base, pushing them to an
internal registry, and deploying via the official Argo CD Helm chart with image overrides.

- **Source Code:** https://github.com/argoproj/argo-cd
- **Helm Chart:** https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd
- **Version:** `v3.4.4`
- **UBI9 Dockerfile:** [`Dockerfile.ubi9`](../Dockerfile.ubi9)
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

### 1. Build the Argo CD Image

See [`Dockerfile.ubi9`](../Dockerfile.ubi9) for the full build definition. Tool versions (Helm, Kustomize, git-lfs) are pinned in [`hack/tool-versions.sh`](../hack/tool-versions.sh).

```bash
DOCKER_BUILDKIT=1 docker build \
  -f Dockerfile.ubi9 \
  -t registry.company.com/argocd/argocd:v3.4.4-ubi9 \
  --platform linux/amd64 \
  --build-arg GIT_TAG=v3.4.4 \
  .
```

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
docker push registry.company.com/argocd/redis:8.2.3-ubi9
docker push registry.company.com/argocd/dex:v2.45.0-ubi9     # if SSO enabled
docker push registry.company.com/argocd/haproxy:3.0.8-ubi9   # if HA
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

### Verify all Argo CD component binaries are present

```bash
IMAGE=registry.company.com/argocd/argocd:v3.4.4-ubi9

docker run --rm $IMAGE argocd-server --help
docker run --rm $IMAGE argocd-repo-server --help
docker run --rm $IMAGE argocd-application-controller --help
docker run --rm $IMAGE argocd-applicationset-controller --help
docker run --rm $IMAGE argocd-notifications-controller --help
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

