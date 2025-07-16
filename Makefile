# Registry type: 'ecr' or 'artifactory' (default: ecr)
REGISTRY_TYPE ?= ecr

# Registry URLs
ECR_REG_NAME = 975049916663.dkr.ecr.us-east-1.amazonaws.com
ARTIFACTORY_REG_NAME = usartifactorywexinc.jfrog.io

# Select registry based on type
ifeq ($(REGISTRY_TYPE),artifactory)1
  REG_NAME := $(ARTIFACTORY_REG_NAME)
else
  REG_NAME := $(ECR_REG_NAME)
endif

ifeq ($(REGISTRY_TYPE),artifactory)
  IMAGE_NAME := ai-platform-docker-subprod/chronon-app
else
  IMAGE_NAME := chronon-app
endif
# Generate a tag using git describe and append a short hash of any uncommitted changes
TAG ?= $(shell git describe --tags --always --dirty)-$(shell git diff | sha256sum | cut -c -6)
# Remove "-e3b0c4" from tag - this is the SHA256 hash prefix of an empty string,
# which appears when there are no uncommitted changes
TAG_VERSION := $(subst -e3b0c4,,$(TAG))
IMAGE_NAME_URL := ${REG_NAME}/${IMAGE_NAME}:${TAG_VERSION}

.PHONY: lint image-package image-push local-run docker-shell compose-up print-image-info
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
print-image-info:
	@echo "Registry: ${REG_NAME}"
	@echo "Image: ${IMAGE_NAME}"
	@echo "Tag: ${TAG_VERSION}"
	@echo "Full image URL: ${IMAGE_NAME_URL}"

# EMR Spark image targets
ifeq ($(REGISTRY_TYPE),artifactory)
  EMR_SPARK_IMAGE_NAME := ai-platform-docker-subprod/chronon-emr-spark
else
  EMR_SPARK_IMAGE_NAME := chronon-emr-spark
endif
EMR_SPARK_TAG ?= $(shell git describe --tags --always --dirty)-$(shell git diff | sha256sum | cut -c -6)
EMR_SPARK_TAG_VERSION := $(subst -e3b0c4,,${EMR_SPARK_TAG})
EMR_SPARK_IMAGE_NAME_URL := ${REG_NAME}/${EMR_SPARK_IMAGE_NAME}:${EMR_SPARK_TAG_VERSION}

.PHONY: image-package-emr-spark image-push-emr-spark local-run-emr-spark print-emr-spark-image

image-package-emr-spark:
	DOCKER_BUILDKIT=1 docker build --platform=linux/amd64 -t "${EMR_SPARK_IMAGE_NAME_URL}" -f "emr-spark.Dockerfile" .

image-push-emr-spark:
	docker push ${EMR_SPARK_IMAGE_NAME_URL}

local-run-emr-spark: image-package-emr-spark
	docker run --rm -it ${EMR_SPARK_IMAGE_NAME_URL} /bin/bash

print-emr-spark-image:
	@echo "Registry: ${REG_NAME}"
	@echo "Image: ${EMR_SPARK_IMAGE_NAME}"
	@echo "Tag: ${EMR_SPARK_TAG_VERSION}"
	@echo "Full image URL: ${EMR_SPARK_IMAGE_NAME_URL}"

# Usage:
#   make image-package REGISTRY_TYPE=ecr|artifactory
#   make image-push REGISTRY_TYPE=ecr|artifactory
#   make image-package-emr-spark REGISTRY_TYPE=ecr|artifactory
#   make image-push-emr-spark REGISTRY_TYPE=ecr|artifactory
#   make print-image-info REGISTRY_TYPE=ecr|artifactory
#   make print-emr-spark-image REGISTRY_TYPE=ecr|artifactory
