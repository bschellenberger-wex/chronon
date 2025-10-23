# Use bash for all shell commands
SHELL := /bin/bash

# Main app image (Artifactory) - Now handled by GitHub Actions
ARTIFACTORY_REGISTRY_URL := usartifactorywexinc.jfrog.io
MAIN_APP_IMAGE_NAME := ai-platform-docker-subprod/chronon-orchestrator
MAIN_APP_VERSION := $(shell cat VERSION 2>/dev/null | tr -d '[:space:]')
ifeq ($(strip $(MAIN_APP_VERSION)),)
$(error VERSION file must exist and contain a version string (e.g., 0.0.1-SNAPSHOT))
endif
MAIN_APP_TAG ?= $(MAIN_APP_VERSION)
MAIN_APP_IMAGE_URL := ${ARTIFACTORY_REGISTRY_URL}/${MAIN_APP_IMAGE_NAME}:${MAIN_APP_TAG}

# EMR Spark image (ECR) - Now handled by GitHub Actions
EMR_SPARK_IMAGE_NAME := chronon-spark-emr
EMR_SPARK_VERSION := $(shell cat VERSION.emr-spark 2>/dev/null | tr -d '[:space:]')
ifeq ($(strip $(EMR_SPARK_VERSION)),)
$(error VERSION.emr-spark file must exist and contain a version string (e.g., 0.0.1-SNAPSHOT))
endif
EMR_SPARK_TAG ?= $(EMR_SPARK_VERSION)

.PHONY: lint image-package image-push local-run docker-shell compose-up print-image-info build test prepare-artifacts list-jars promote-artifacts promote-to-subprod promote-to-prod scan-main-app scan-emr-spark scan-all clean-scan-results
lint:
	echo "👕 lint"
	black src
	isort --profile black src
# NOTE: Docker build/push is now handled by GitHub Actions workflows
# These targets are kept for local development and testing only

# Download Spark file from Artifactory for local builds
download-spark:
	@echo "📥 Downloading Spark from Artifactory..."
	@if [ ! -f "spark-3.5.5-bin-hadoop3.tgz" ]; then \
		jf rt download ai-platform-generic-subprod/spark/spark-3.5.5-bin-hadoop3.tgz ./ --flat; \
		echo "✅ Spark downloaded successfully"; \
	else \
		echo "✅ Spark file already exists, skipping download"; \
	fi

# Download Scala .deb from Artifactory for local builds
SCALA_DEB_FILENAME := scala-2.12.20.deb
SCALA_DEB_PATH := ./$(SCALA_DEB_FILENAME)
SCALA_ARTIFACTORY_PATH := ai-platform-generic/scala/2.12.20/scala-2.12.20.deb

download-scala:
	@echo "📥 Downloading Scala from Artifactory..."
	@if [ ! -f "$(SCALA_DEB_PATH)" ]; then \
		jf rt download $(SCALA_ARTIFACTORY_PATH) ./ --flat; \
		echo "✅ Scala downloaded successfully"; \
	else \
		echo "✅ Scala file already exists, skipping download"; \
	fi

image-package: download-spark download-scala
	@set -euo pipefail; \
	if [ ! -f VERSION ]; then \
	  echo "ERROR: VERSION file not found." >&2; \
	  exit 1; \
	fi; \
	TAG=$$(cat VERSION); \
	IMAGE_URI="$(ARTIFACTORY_REGISTRY_URL)/$(MAIN_APP_IMAGE_NAME):$$TAG"; \
	echo "Building Docker image: $$IMAGE_URI"; \
	docker buildx build --pull --platform linux/amd64 -f Dockerfile . -t "$$IMAGE_URI"

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
	@echo "Image: ${EMR_SPARK_IMAGE_NAME}"
	@echo "Tag: ${EMR_SPARK_TAG}"

# ==============================================================================
# EMR SPARK IMAGE PUBLISHING (Refactored for CI/CD)
# ==============================================================================

# Target to build the EMR spark image locally. Called by the `build-image` CI job.
.PHONY: build-emr-spark
build-emr-spark:
	@echo "🏗️ Building EMR Spark image..."
	@echo "Image Name: $(EMR_SPARK_IMAGE_NAME)"
	@echo "Version Tag: $(EMR_SPARK_TAG)"
	docker buildx build --pull \
		--platform linux/amd64 \
		--file emr-spark.Dockerfile \
		--tag $(EMR_SPARK_IMAGE_NAME):$(EMR_SPARK_TAG) \
		--load \
		.
	@echo "✅ Successfully built and loaded local image: $(EMR_SPARK_IMAGE_NAME):$(EMR_SPARK_TAG)"

# A reusable helper target for ECR authentication.
.PHONY: ecr-login
ecr-login:
	@echo "🔐 Logging into ECR for Account: $(AWS_ACCOUNT_ID) in Region: $(AWS_REGION)..."
	@aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com"
	@echo "✅ ECR login successful."

# Target to publish the EMR spark image to a specific region.
# Called by the matrix strategy in the `publish` CI job.
# Assumes the image has already been built and loaded.
.PHONY: publish-emr-spark-to-region
publish-emr-spark-to-region: ecr-login
	@echo "🚀 Publishing to Account: $(AWS_ACCOUNT_ID) in Region: $(AWS_REGION)..."
	@ECR_IMAGE_URI="$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(EMR_SPARK_IMAGE_NAME):$(EMR_SPARK_TAG)"; \
	echo "Full Image URI: $$ECR_IMAGE_URI"; \
	\
	if ! echo ${EMR_SPARK_TAG} | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	  echo "ERROR: VERSION.emr-spark must use semantic versioning (e.g., 0.0.1) for push. SNAPSHOT tags are not allowed. Found: ${EMR_SPARK_TAG}" >&2; \
	  exit 1; \
	fi; \
	\
	echo "🏷️ Tagging local image for ECR..."; \
	docker tag $(EMR_SPARK_IMAGE_NAME):$(EMR_SPARK_TAG) $$ECR_IMAGE_URI; \
	\
	echo "🔎 Checking if image already exists in ECR..."; \
	if docker manifest inspect $$ECR_IMAGE_URI > /dev/null 2>&1; then \
	  echo "ERROR: Image $$ECR_IMAGE_URI already exists in ECR. Aborting push to prevent overwrite." >&2; \
	  exit 1; \
	else \
	  echo "📦 Pushing image to ECR..."; \
	  docker push $$ECR_IMAGE_URI; \
	  echo "✅ Successfully pushed $$ECR_IMAGE_URI"; \
	fi

# Target to publish the EMR spark image to all regions with success/failure tracking.
# This replaces the inline logic in GitHub Actions.
# Usage: make publish-emr-spark REGIONS="us-east-1 us-west-2"
# REGIONS parameter is required - no default regions
.PHONY: publish-emr-spark
publish-emr-spark:
	@echo "🚀 Publishing EMR Spark image to all regions..."
	@bash -c '\
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text 2>/dev/null); \
	if [ -z "$$ACCOUNT_ID" ]; then \
	  echo "❌ Failed to retrieve AWS Account ID. Please ensure AWS credentials are configured."; \
	  exit 1; \
	fi; \
	SUCCESSFUL_REGIONS=(); \
	FAILED_REGIONS=(); \
	REGIONS="$(REGIONS)"; \
	if [ -z "$$REGIONS" ]; then \
	  echo "❌ Error: REGIONS parameter is required. Usage: make publish-emr-spark REGIONS=\"us-east-1 us-west-2\""; \
	  exit 1; \
	fi; \
	echo "📋 Target regions: $$REGIONS"; \
	for region in $$REGIONS; do \
	  echo "🚀 Publishing to region: $$region"; \
	  if $(MAKE) publish-emr-spark-to-region AWS_ACCOUNT_ID=$$ACCOUNT_ID AWS_REGION=$$region; then \
	    echo "✅ Completed publishing to $$region"; \
	    SUCCESSFUL_REGIONS+=("$$region"); \
	  else \
	    echo "❌ Failed publishing to $$region"; \
	    FAILED_REGIONS+=("$$region"); \
	  fi; \
	done; \
	echo "📊 Publishing Summary:"; \
	if [ $${#SUCCESSFUL_REGIONS[@]} -eq 0 ]; then \
	  echo "✅ Successful regions: (none)"; \
	else \
	  echo "✅ Successful regions: \"$${SUCCESSFUL_REGIONS[@]}\""; \
	fi; \
	if [ $${#FAILED_REGIONS[@]} -gt 0 ]; then \
	  echo "❌ Failed regions: \"$${FAILED_REGIONS[@]}\""; \
	  exit 1; \
	else \
	  echo "🎉 Successfully published to all regions!"; \
	fi'

# Build configuration
BAZEL_CONFIGS := --config java_8 --config scala_2.12 --config spark_3.5
FULL_VERSION ?= $(shell ./.github/scripts/generate_version.sh version)
GROUP_ID := $(shell source .github/MAVEN_VERSION && echo $$group_id)

# Optional: Set server_javabase for local development (VPN/CA Authority issues)
# This is required when behind a VPN due to CA Authority certificate issues
# Usage: make build SERVER_JAVABASE=$JAVA_HOME
# Usage: make build SERVER_JAVABASE=/path/to/java
# Usage: make test SERVER_JAVABASE=$JAVA_HOME
SERVER_JAVABASE ?=
BAZEL_SERVER_FLAGS := $(if $(SERVER_JAVABASE),--server_javabase=$(SERVER_JAVABASE),)

# Define JAR targets - easily extensible for future JARs
# Format: TARGET_NAME:BAZEL_TARGET:ARTIFACT_BASE_NAME:OUTPUT_DIR
JAR_TARGETS := \
    spark-assembly:spark:spark-assembly_deploy.jar:spark-assembly:spark

# Helper function to get artifact ID for a given base name
get-artifact-id = $(shell ./.github/scripts/generate_version.sh artifact_id --name=$(1))

# Build all JAR targets
build:
	@echo "🚀 Building all Chronon JAR targets with Bazel..."
	@if [ -n "$(SERVER_JAVABASE)" ]; then \
	   echo "Using server_javabase: $(SERVER_JAVABASE)"; \
	fi
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   bazel_target="//$$module:$$jar_name"; \
	   echo "Building $$name ($$bazel_target)..."; \
	   bazel $(BAZEL_SERVER_FLAGS) build $(BAZEL_CONFIGS) $$bazel_target; \
	done
	@echo "✅ All builds completed successfully!"

# Build a specific JAR target
build-%:
	@echo "🚀 Building specific JAR target: $*"
	@if [ -n "$(SERVER_JAVABASE)" ]; then \
	   echo "Using server_javabase: $(SERVER_JAVABASE)"; \
	fi
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   if [ "$$name" = "$*" ]; then \
		  bazel_target="//$$module:$$jar_name"; \
		  echo "Building $$name ($$bazel_target)..."; \
		  bazel $(BAZEL_SERVER_FLAGS) build $(BAZEL_CONFIGS) $$bazel_target; \
		  exit 0; \
	   fi; \
	done
	@echo "❌ Error: JAR target '$*' not found. Available targets:"
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   echo "  - $$name"; \
	done

# Run tests for all modules
test:
	@echo "🧪 Running Bazel tests..."
	@if [ -n "$(SERVER_JAVABASE)" ]; then \
	   echo "Using server_javabase: $(SERVER_JAVABASE)"; \
	fi
	bazel $(BAZEL_SERVER_FLAGS) test $(BAZEL_CONFIGS) //spark:test
	@echo "✅ All tests passed! 🎉"

# Prepare artifacts for all JAR targets
prepare-artifacts: build
	@echo "📝 Preparing Maven artifacts for all JAR targets..."
	@# Create a clean artifacts directory
	@rm -rf chronon-artifacts
	@mkdir -p chronon-artifacts
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   bazel_target="//$$module:$$jar_name"; \
	   artifact_id=$$(./.github/scripts/generate_version.sh artifact_id --name=$$artifact_base); \
	   echo "Processing $$name ($$artifact_id)..."; \
	   $(MAKE) prepare-artifact JAR_NAME=$$name BAZEL_TARGET=$$bazel_target ARTIFACT_BASE=$$artifact_base OUTPUT_DIR=$$output_dir ARTIFACT_ID=$$artifact_id; \
	done
	@echo "✅ All Maven artifacts prepared successfully!"
	@# Generate artifact manifest for GitHub Actions
	@echo "📋 Generating artifact manifest..."
	@echo "# Chronon Artifact Manifest" > chronon-artifacts/ARTIFACT_MANIFEST.txt
	@echo "# Generated on: $$(date)" >> chronon-artifacts/ARTIFACT_MANIFEST.txt
	@echo "# Full Version: $(FULL_VERSION)" >> chronon-artifacts/ARTIFACT_MANIFEST.txt
	@echo "# Group ID: $(GROUP_ID)" >> chronon-artifacts/ARTIFACT_MANIFEST.txt
	@echo "" >> chronon-artifacts/ARTIFACT_MANIFEST.txt
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   artifact_id=$$(./.github/scripts/generate_version.sh artifact_id --name=$$artifact_base); \
	   echo "ARTIFACT_ID=$$artifact_id" >> chronon-artifacts/ARTIFACT_MANIFEST.txt; \
	   echo "JAR_FILE=$$artifact_id-$(FULL_VERSION).jar" >> chronon-artifacts/ARTIFACT_MANIFEST.txt; \
	   echo "POM_FILE=$$artifact_id-$(FULL_VERSION).pom" >> chronon-artifacts/ARTIFACT_MANIFEST.txt; \
	   echo "CHECKSUM_FILE=$$artifact_id-$(FULL_VERSION).jar.sha256" >> chronon-artifacts/ARTIFACT_MANIFEST.txt; \
	   echo "" >> chronon-artifacts/ARTIFACT_MANIFEST.txt; \
	done
	@echo "📦 Artifacts ready in chronon-artifacts/:"
	@ls -la chronon-artifacts/
	@echo ""
	@echo "📋 Artifact manifest:"
	@cat chronon-artifacts/ARTIFACT_MANIFEST.txt

# Prepare artifacts for a specific JAR target
prepare-artifact-%: build-%
	@echo "📝 Preparing Maven artifacts for JAR target: $*"
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   if [ "$$name" = "$*" ]; then \
		  bazel_target="//$$module:$$jar_name"; \
		  artifact_id=$$(./.github/scripts/generate_version.sh artifact_id --name=$$artifact_base); \
		  $(MAKE) prepare-artifact JAR_NAME=$$name BAZEL_TARGET=$$bazel_target ARTIFACT_BASE=$$artifact_base OUTPUT_DIR=$$output_dir ARTIFACT_ID=$$artifact_id; \
		  exit 0; \
	   fi; \
	done
	@echo "❌ Error: JAR target '$*' not found."

# Internal target to prepare a single artifact
prepare-artifact:
	@echo "  📦 Preparing $(JAR_NAME) artifacts..."
	@echo "    Artifact ID: $(ARTIFACT_ID)"
	@echo "    Full version: $(FULL_VERSION)"
	@echo "    Group ID: $(GROUP_ID)"
	# Generate POM file from template
	sed -e "s/{{GROUP_ID}}/$(GROUP_ID)/g" \
		-e "s/{{ARTIFACT_ID}}/$(ARTIFACT_ID)/g" \
		-e "s/{{VERSION}}/$(FULL_VERSION)/g" \
		".github/wex.pom.xml.tpl" > "chronon-artifacts/$(ARTIFACT_ID)-$(FULL_VERSION).pom"
	# Copy and rename JAR to Maven convention in chronon-artifacts
	cp "bazel-bin/$(OUTPUT_DIR)/$(shell echo $(BAZEL_TARGET) | sed 's|.*:||')" "chronon-artifacts/$(ARTIFACT_ID)-$(FULL_VERSION).jar"
	# Generate checksum in chronon-artifacts
	(cd chronon-artifacts && sha256sum "$(ARTIFACT_ID)-$(FULL_VERSION).jar" > "$(ARTIFACT_ID)-$(FULL_VERSION).jar.sha256")
	@echo "    ✅ $(JAR_NAME) artifacts prepared"
	@echo "    Generated files:"
	@ls -la chronon-artifacts/$(ARTIFACT_ID)-$(FULL_VERSION).*

# List available JAR targets
list-jars:
	@echo "Available JAR targets:"
	@for target in $(JAR_TARGETS); do \
	   IFS=':' read -r name module jar_name artifact_base output_dir <<< "$$target"; \
	   bazel_target="//$$module:$$jar_name"; \
	   artifact_id=$$(./.github/scripts/generate_version.sh artifact_id --name=$$artifact_base); \
	   echo "  - $$name: $$artifact_id ($$bazel_target)"; \
	done

# Deploy Spark Assembly JAR to S3
S3_BUCKET ?=
S3_PREFIX ?= chronon-driver-jars
DRY_RUN ?= false
S3_REGION ?= $(AWS_REGION)

# Artifactory Repository Promotion Configuration
ARTIFACTORY_SUBPROD_REPO := ai-platform-maven-subprod
ARTIFACTORY_PROD_REPO := ai-platform-maven-prod
FORCE_OVERWRITE ?= false

# JFrog Security Scanning Configuration
SCAN_RESULT_MAIN_APP := scan-result-main-app.json
SCAN_RESULT_EMR_SPARK := scan-result-emr-spark.json
SCAN_PATH := ai-platform-generic-subprod/docker-scans
MIN_SEVERITY ?= High
FIXABLE_ONLY ?= true

# Image names for upload paths (image-name/tag structure)
MAIN_APP_IMAGE_NAME_SIMPLE := chronon-orchestrator
EMR_SPARK_IMAGE_NAME_SIMPLE := chronon-spark-emr

# Scan result filename (just scan-result.json)
SCAN_RESULT_FILENAME := scan-result.json

# Helper to find the spark-assembly JAR
find-spark-jar:
	@echo "🔍 Looking for spark-assembly JAR in chronon-artifacts..."
	@JAR_FILE=$$(find chronon-artifacts -type f -name "*spark-assembly*.jar" | grep -v '.sha256' | head -1); \
	if [ -z "$$JAR_FILE" ]; then \
	   echo "❌ Error: No spark-assembly JAR found in chronon-artifacts/"; \
	   echo "Available files:"; \
	   ls -la chronon-artifacts/ || echo "chronon-artifacts directory not found"; \
	   echo ""; \
	   echo "💡 Hint: Run 'make prepare-artifacts' or 'make prepare-artifact-spark-assembly' first to generate the JAR files."; \
	   exit 1; \
	else \
	   echo "✅ Found JAR: $$JAR_FILE"; \
	   JAR_SIZE=$$(stat -f%z "$$JAR_FILE" 2>/dev/null || stat -c%s "$$JAR_FILE" 2>/dev/null); \
	   echo "JAR_FILE=$$JAR_FILE" > .spark_jar_info; \
	   echo "JAR_SIZE=$$JAR_SIZE" >> .spark_jar_info; \
	   echo "📦 JAR size: $$JAR_SIZE bytes"; \
	fi

# Deploy target
.PHONY: deploy-spark-jar-s3

deploy-spark-jar-s3: find-spark-jar
	@. .spark_jar_info; \
	JAR_FILENAME=$$(basename "$$JAR_FILE"); \
	JAR_DIRNAME=$$(dirname "$$JAR_FILE"); \
	S3_PATH="s3://$(S3_BUCKET)/$(S3_PREFIX)/$$JAR_FILENAME"; \
	if [ "$(DRY_RUN)" = "true" ]; then \
	   echo "🔍 DRY RUN - Would upload:"; \
	   echo "  Source: $$JAR_FILE"; \
	   echo "  Destination: $$S3_PATH"; \
	   echo "  Size: $$JAR_SIZE bytes"; \
	else \
	   echo "🚀 Uploading $$JAR_FILENAME to S3..."; \
	   echo "Source: $$JAR_FILE"; \
	   echo "Destination: $$S3_PATH"; \
	   (cd "$$JAR_DIRNAME" && aws s3 cp "$$JAR_FILENAME" "$$S3_PATH" --region $(S3_REGION)); \
	   if [ $$? -eq 0 ]; then \
		  echo "✅ Successfully uploaded to $$S3_PATH"; \
	   else \
		  echo "❌ Upload failed"; \
		  exit 1; \
	   fi; \
	fi; \
	echo "--- Deployment Summary ---"; \
	echo "- S3 Bucket: $(S3_BUCKET)"; \
	echo "- S3 Prefix: $(S3_PREFIX)"; \
	echo "- JAR File: $$JAR_FILENAME"; \
	echo "- JAR Size: $$JAR_SIZE bytes"; \
	GIT_HASH=$$(git rev-parse --short HEAD 2>/dev/null || echo "N/A"); \
	echo "- Git Hash: $$GIT_HASH"

# Artifactory Repository Promotion Targets
# These targets handle the staged promotion process: subprod -> prod

# Main promotion target - promotes to subprod first, then to prod
promote-artifacts: promote-to-subprod promote-to-prod
	@echo "✅ Complete promotion pipeline finished successfully!"

# Promote artifacts to subprod repository
promote-to-subprod:
	@echo "🚀 Promoting artifacts to $(ARTIFACTORY_SUBPROD_REPO)..."
	@if [ ! -f "chronon-artifacts/ARTIFACT_MANIFEST.txt" ]; then \
	   echo "❌ Error: ARTIFACT_MANIFEST.txt not found. Run 'make prepare-artifacts' first."; \
	   exit 1; \
	fi
	@$(MAKE) _upload-to-repo REPO=$(ARTIFACTORY_SUBPROD_REPO)
	@echo "✅ Successfully promoted to $(ARTIFACTORY_SUBPROD_REPO)"

# Promote artifacts from subprod to prod using JFrog CLI copy
promote-to-prod:
	@echo "🚀 Promoting artifacts from $(ARTIFACTORY_SUBPROD_REPO) to $(ARTIFACTORY_PROD_REPO)..."
	@if [ ! -f "chronon-artifacts/ARTIFACT_MANIFEST.txt" ]; then \
	   echo "❌ Error: ARTIFACT_MANIFEST.txt not found. Run 'make prepare-artifacts' first."; \
	   exit 1; \
	fi
	@$(MAKE) _copy-to-prod
	@echo "✅ Successfully promoted to $(ARTIFACTORY_PROD_REPO)"

# Internal target to upload artifacts to a specific repository
_upload-to-repo:
	@echo "📦 Uploading artifacts to $(REPO)..."
	@DRY_RUN_FLAG=""; \
	if [ "$(DRY_RUN)" = "true" ]; then \
	   DRY_RUN_FLAG="--dry-run"; \
	fi; \
	GROUP_PATH="$(shell echo '$(GROUP_ID)' | tr . /)"; \
	while IFS='=' read -r key value; do \
	   if [[ "$$key" == "ARTIFACT_ID" ]]; then \
		  ARTIFACT_ID="$$value"; \
	   elif [[ "$$key" == "JAR_FILE" ]]; then \
		  JAR_FILE="$$value"; \
	   elif [[ "$$key" == "POM_FILE" ]]; then \
		  POM_FILE="$$value"; \
	   elif [[ "$$key" == "CHECKSUM_FILE" ]]; then \
		  CHECKSUM_FILE="$$value"; \
		  echo "  Processing artifact: $$ARTIFACT_ID"; \
		  JAR_PATH="$(REPO)/$$GROUP_PATH/$$ARTIFACT_ID/$(FULL_VERSION)/$$JAR_FILE"; \
		  POM_PATH="$(REPO)/$$GROUP_PATH/$$ARTIFACT_ID/$(FULL_VERSION)/$$POM_FILE"; \
		  \
		  if [ "$(FORCE_OVERWRITE)" = "false" ] && [ -z "$$DRY_RUN_FLAG" ]; then \
			 if jf rt s "$$JAR_PATH" | grep -q '"path"'; then \
				echo "    ❌ Artifact already exists at $$JAR_PATH. Failing as force_overwrite is false."; \
				exit 1; \
			 fi; \
		  fi; \
		  \
		  echo "    🚀 Uploading to $(REPO)..."; \
		  jf rt u $$DRY_RUN_FLAG "chronon-artifacts/$$JAR_FILE" "$$JAR_PATH"; \
		  if [ -f "chronon-artifacts/$$POM_FILE" ]; then \
			 jf rt u $$DRY_RUN_FLAG "chronon-artifacts/$$POM_FILE" "$$POM_PATH"; \
		  fi; \
		  echo "    ✅ Completed $$ARTIFACT_ID"; \
	   fi; \
	done < chronon-artifacts/ARTIFACT_MANIFEST.txt

# Internal target to copy artifacts from subprod to prod using JFrog CLI
_copy-to-prod:
	@echo "📋 Copying artifacts from $(ARTIFACTORY_SUBPROD_REPO) to $(ARTIFACTORY_PROD_REPO)..."
	@DRY_RUN_FLAG=""; \
	if [ "$(DRY_RUN)" = "true" ]; then \
	   DRY_RUN_FLAG="--dry-run"; \
	fi; \
	GROUP_PATH="$(shell echo '$(GROUP_ID)' | tr . /)"; \
	while IFS='=' read -r key value; do \
	   if [[ "$$key" == "ARTIFACT_ID" ]]; then \
		  ARTIFACT_ID="$$value"; \
	   elif [[ "$$key" == "JAR_FILE" ]]; then \
		  JAR_FILE="$$value"; \
	   elif [[ "$$key" == "POM_FILE" ]]; then \
		  POM_FILE="$$value"; \
	   elif [[ "$$key" == "CHECKSUM_FILE" ]]; then \
		  CHECKSUM_FILE="$$value"; \
		  echo "  Copying artifact: $$ARTIFACT_ID"; \
		  SOURCE_JAR_PATH="$(ARTIFACTORY_SUBPROD_REPO)/$$GROUP_PATH/$$ARTIFACT_ID/$(FULL_VERSION)/$$JAR_FILE"; \
		  TARGET_JAR_PATH="$(ARTIFACTORY_PROD_REPO)/$$GROUP_PATH/$$ARTIFACT_ID/$(FULL_VERSION)/$$JAR_FILE"; \
		  SOURCE_POM_PATH="$(ARTIFACTORY_SUBPROD_REPO)/$$GROUP_PATH/$$ARTIFACT_ID/$(FULL_VERSION)/$$POM_FILE"; \
		  TARGET_POM_PATH="$(ARTIFACTORY_PROD_REPO)/$$GROUP_PATH/$$ARTIFACT_ID/$(FULL_VERSION)/$$POM_FILE"; \
		  \
		  if [ "$(FORCE_OVERWRITE)" = "false" ] && [ -z "$$DRY_RUN_FLAG" ]; then \
			 if jf rt s "$$TARGET_JAR_PATH" | grep -q '"path"'; then \
				echo "    ❌ Artifact already exists at $$TARGET_JAR_PATH. Failing as force_overwrite is false."; \
				exit 1; \
			 fi; \
		  fi; \
		  \
		  echo "    🔄 Copying JAR from subprod to prod..."; \
		  jf rt cp $$DRY_RUN_FLAG "$$SOURCE_JAR_PATH" "$(ARTIFACTORY_PROD_REPO)/"; \
		  if jf rt s "$$SOURCE_POM_PATH" | grep -q '"path"'; then \
			 echo "    🔄 Copying POM from subprod to prod..."; \
			 jf rt cp $$DRY_RUN_FLAG "$$SOURCE_POM_PATH" "$(ARTIFACTORY_PROD_REPO)/"; \
		  fi; \
		  echo "    ✅ Completed copying $$ARTIFACT_ID"; \
	   fi; \
	done < chronon-artifacts/ARTIFACT_MANIFEST.txt

# ==============================================================================
# JFROG SECURITY SCANNING TARGETS
# ==============================================================================

# Scan the Chronon Orchestrator Docker image (assumes image is already built)
.PHONY: scan-main-app
scan-main-app:
	@echo "🔍 Scanning locally built Chronon Orchestrator image: $(MAIN_APP_IMAGE_URL)"
	@if [ -z "$(MAIN_APP_IMAGE_URL)" ]; then \
		echo "❌ Error: MAIN_APP_IMAGE_URL is not set. Make sure VERSION file exists."; \
		exit 1; \
	fi
	@echo "Scanning with minimum severity: $(MIN_SEVERITY)"
	@echo "Fixable only: $(FIXABLE_ONLY)"
	@jf docker scan $(MAIN_APP_IMAGE_URL) \
		--min-severity $(MIN_SEVERITY) \
		$(if $(filter true,$(FIXABLE_ONLY)),--fixable-only) \
		--format json \
		--fail | tee $(SCAN_RESULT_MAIN_APP); exit $${PIPESTATUS[0]}
	@echo "📋 Scan Result for Main App:"
	@cat $(SCAN_RESULT_MAIN_APP) | jq . || cat $(SCAN_RESULT_MAIN_APP)
	@echo "📤 Uploading scan result to Artifactory..."
	@jf rt u "$(SCAN_RESULT_MAIN_APP)" "$(SCAN_PATH)/$(MAIN_APP_IMAGE_NAME_SIMPLE)/$(MAIN_APP_TAG)/$(SCAN_RESULT_FILENAME)"
	@echo "✅ Main app scan completed and uploaded"

# Scan the EMR Spark Docker image
.PHONY: scan-emr-spark
scan-emr-spark:
	@echo "🔍 Scanning EMR Spark image: $(EMR_SPARK_IMAGE_NAME):$(EMR_SPARK_TAG)"
	@if [ -z "$(EMR_SPARK_TAG)" ]; then \
		echo "❌ Error: EMR_SPARK_TAG is not set. Make sure VERSION.emr-spark file exists."; \
		exit 1; \
	fi
	@echo "Scanning with minimum severity: $(MIN_SEVERITY)"
	@echo "Fixable only: $(FIXABLE_ONLY)"
	@jf docker scan $(EMR_SPARK_IMAGE_NAME):$(EMR_SPARK_TAG) \
		--min-severity $(MIN_SEVERITY) \
		$(if $(filter true,$(FIXABLE_ONLY)),--fixable-only) \
		--format json \
		--fail | tee $(SCAN_RESULT_EMR_SPARK); exit $${PIPESTATUS[0]}
	@echo "📋 Scan Result for EMR Spark:"
	@cat $(SCAN_RESULT_EMR_SPARK) | jq . || cat $(SCAN_RESULT_EMR_SPARK)
	@echo "📤 Uploading scan result to Artifactory..."
	@jf rt u "$(SCAN_RESULT_EMR_SPARK)" "$(SCAN_PATH)/$(EMR_SPARK_IMAGE_NAME_SIMPLE)/$(EMR_SPARK_TAG)/$(SCAN_RESULT_FILENAME)"
	@echo "✅ EMR Spark scan completed and uploaded"

# Scan both images
.PHONY: scan-all
scan-all: scan-main-app scan-emr-spark
	@echo "✅ All security scans completed successfully!"

# Clean up scan result files
.PHONY: clean-scan-results
clean-scan-results:
	@echo "🧹 Cleaning up scan result files..."
	@rm -f $(SCAN_RESULT_MAIN_APP) $(SCAN_RESULT_EMR_SPARK)
	@echo "✅ Scan result files cleaned up"

