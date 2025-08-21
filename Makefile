# Main app image (Artifactory)
ARTIFACTORY_REGISTRY_URL := usartifactorywexinc.jfrog.io
MAIN_APP_IMAGE_NAME := ai-platform-docker-subprod/chronon-app
MAIN_APP_VERSION := $(shell cat VERSION 2>/dev/null)
ifeq ($(strip $(MAIN_APP_VERSION)),)
$(error VERSION file must exist and contain a version string (e.g., 0.0.1-SNAPSHOT))
endif
MAIN_APP_TAG ?= $(MAIN_APP_VERSION)
MAIN_APP_IMAGE_URL := ${ARTIFACTORY_REGISTRY_URL}/${MAIN_APP_IMAGE_NAME}:${MAIN_APP_TAG}

# EMR Spark image (ECR)
ECR_REGISTRY_URL := 975049916663.dkr.ecr.us-east-1.amazonaws.com
EMR_SPARK_IMAGE_NAME := chronon-spark-emr
EMR_SPARK_VERSION := $(shell cat VERSION.emr-spark 2>/dev/null)
ifeq ($(strip $(EMR_SPARK_VERSION)),)
$(error VERSION.emr-spark file must exist and contain a version string (e.g., 0.0.1-SNAPSHOT))
endif
EMR_SPARK_TAG ?= $(EMR_SPARK_VERSION)
EMR_SPARK_IMAGE_URL := ${ECR_REGISTRY_URL}/${EMR_SPARK_IMAGE_NAME}:${EMR_SPARK_TAG}

.PHONY: lint image-package image-push local-run docker-shell compose-up print-image-info image-package-emr-spark image-push-emr-spark
lint:
	echo "👕 lint"
	black src
	isort --profile black src
image-package:
	./build_main_app.sh
image-push: image-package
	@echo "Pushing main app image to Artifactory..."
	@if ! echo ${MAIN_APP_TAG} | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	  echo "ERROR: VERSION must use semantic versioning (e.g., 0.0.1) for push. SNAPSHOT and non-semver tags are not allowed."; \
	  exit 1; \
	fi; \
	if docker manifest inspect ${MAIN_APP_IMAGE_URL} > /dev/null 2>&1; then \
	  echo "ERROR: Image ${MAIN_APP_IMAGE_URL} already exists in Artifactory. Aborting push to prevent overwrite."; \
	  exit 1; \
	else \
	  docker push ${MAIN_APP_IMAGE_URL}; \
	fi
local-run: image-package
	docker run --rm -it ${MAIN_APP_IMAGE_URL} /bin/bash
docker-shell:
	docker-compose exec main /bin/bash
compose-up:
	docker-compose build
	docker-compose up -d
print-image-info:
	@echo "Registry: ${ARTIFACTORY_REGISTRY_URL}"
	@echo "Image: ${MAIN_APP_IMAGE_NAME}"
	@echo "Tag: ${MAIN_APP_TAG}"
	@echo "Full image URL: ${MAIN_APP_IMAGE_URL}"

print-emr-spark-image:
	@echo "Registry: ${ECR_REGISTRY_URL}"
	@echo "Image: ${EMR_SPARK_IMAGE_NAME}"
	@echo "Tag: ${EMR_SPARK_TAG}"
	@echo "Full image URL: ${EMR_SPARK_IMAGE_URL}"

image-package-emr-spark:
	./build_emr_spark.sh $(ECR_REGISTRY_URL) us-east-1 $(EMR_SPARK_IMAGE_NAME)

image-push-emr-spark: image-package-emr-spark
	@echo "Pushing EMR Spark image to ECR..."
	@if ! echo ${EMR_SPARK_TAG} | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	  echo "ERROR: VERSION.emr-spark must use semantic versioning (e.g., 0.0.1) for push. SNAPSHOT and non-semver tags are not allowed."; \
	  exit 1; \
	fi; \
	if docker manifest inspect ${EMR_SPARK_IMAGE_URL} > /dev/null 2>&1; then \
	  echo "ERROR: Image ${EMR_SPARK_IMAGE_URL} already exists in ECR. Aborting push to prevent overwrite."; \
	  exit 1; \
	else \
	  docker push ${EMR_SPARK_IMAGE_URL}; \
	fi
