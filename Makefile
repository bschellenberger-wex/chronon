REG_NAME ?= usartifactorywexinc.jfrog.io
IMAGE_NAME ?= ai-platform-docker-subprod/chronon-app
# Generate a tag using git describe and append a short hash of any uncommitted changes
TAG ?= $(shell git describe --tags --always --dirty)-$(shell git diff | sha256sum | cut -c -6)
# Remove "-e3b0c4" from tag - this is the SHA256 hash prefix of an empty string,
# which appears when there are no uncommitted changes
TAG_VERSION := $(subst -e3b0c4,,$(TAG))
IMAGE_NAME_URL := ${REG_NAME}/${IMAGE_NAME}:${TAG_VERSION}

.PHONY: lint image-package image-push local-run docker-shell compose-up
lint:
	echo "👕 lint"
	black src
	isort --profile black src
image-package:
	DOCKER_BUILDKIT=1 docker build --platform=linux/amd64 -t "${IMAGE_NAME_URL}" -f "Dockerfile" .
image-push:
	docker push ${IMAGE_NAME_URL}
local-run: image-package
	docker run --rm -it ${IMAGE_NAME_URL} /bin/bash
docker-shell:
	docker-compose exec main /bin/bash
compose-up:
	docker-compose build
	docker-compose up -d
