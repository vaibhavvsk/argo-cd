# Rebuild — UBI9 Docker Image

## Prerequisites

- Docker with [buildx](https://docs.docker.com/buildx/working-with-buildx/) enabled
- Go (used by the Makefile to resolve `HOST_ARCH` / `HOST_OS`)

## Build

```bash
make docker-build
```

This builds `Dockerfile.ubi9` and tags the image as `argocd:latest` by default.

On success the output ends with:

```
=> => naming to docker.io/library/argocd:latest
=> => unpacking to docker.io/library/argocd:latest
```

## Verify

```bash
docker images argocd
```

Run a quick sanity check:

```bash
docker run --rm argocd version --client
```

## Optional variables

| Variable | Default | Description |
|---|---|---|
| `IMAGE_NAMESPACE` | _(none)_ | Prepends `<namespace>/` to the image tag, e.g. `myorg/argocd:latest` |
| `IMAGE_TAG` | `latest` (or current git tag) | Override the image tag |
| `TARGETARCH` | host arch | Target CPU architecture (`amd64`, `arm64`, …) |
| `TARGETOS` | host OS | Target OS (`linux`) |

### Example — custom namespace and tag

```bash
make docker-build IMAGE_NAMESPACE=myorg IMAGE_TAG=v3.1.9
# produces: myorg/argocd:v3.1.9
```

### Example — cross-compile for arm64

```bash
make docker-build TARGETARCH=arm64
```
