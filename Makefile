include Makefile.org

TARGETARCH?=$(HOST_ARCH)
TARGETOS?=$(HOST_OS)

.PHONY: docker-build
docker-build:
	@echo "$(DOCKER) buildx build -f Dockerfile.ubi9 -t $(IMAGE_PREFIX)argocd:$(IMAGE_TAG) --build-arg TARGETARCH=$(TARGETARCH) --build-arg TARGETOS=$(TARGETOS) ."
	$(DOCKER) buildx build -f Dockerfile.ubi9 -t $(IMAGE_PREFIX)argocd:$(IMAGE_TAG) --build-arg TARGETARCH=$(TARGETARCH) --build-arg TARGETOS=$(TARGETOS) .

.PHONY: armimage
