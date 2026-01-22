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

.PHONY: lint image-package image-push local-run docker-shell compose-up print-image-info build test prepare-artifacts list-jars promote-artifacts promote-to-subprod promote-to-prod scan-main-app scan-emr-spark scan-all clean-scan-results clean setup-jvm-cas

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
FULL_VERSION ?= $(shell ./.github/scripts/generate_version.sh version)

# Build configuration - SBT 

# Helper function to get artifact ID for a given base name
get-artifact-id = $(shell ./.github/scripts/generate_version.sh artifact_id --name=$(1))

# Build all JAR targets using SBT (default, recommended)
# Usage: make build [SKIP_TESTS=true]
SKIP_TESTS ?= false
build:
	@echo "🚀 Building all Chronon JAR targets with SBT (Spark 3.5.5)..."
	@if [ "$(SKIP_TESTS)" = "true" ]; then \
		echo "⏭️  Skipping tests"; \
	fi
	@FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	if [ "$(SKIP_TESTS)" = "true" ]; then \
		bash .github/scripts/build_sbt_jars.sh --version=$$FULL_VERSION --skip-tests; \
	else \
		bash .github/scripts/build_sbt_jars.sh --version=$$FULL_VERSION; \
	fi
	@echo "✅ All builds completed successfully!"


# Build a specific JAR target (SBT)
# Usage: make build-spark-assembly [SKIP_TESTS=true]
build-%:
	@echo "🚀 Building specific JAR target: $*"
	@if [ "$(SKIP_TESTS)" = "true" ]; then \
		echo "⏭️  Skipping tests"; \
	fi
	@FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	SKIP_FLAG=""; \
	if [ "$(SKIP_TESTS)" = "true" ]; then \
		SKIP_FLAG="--skip-tests"; \
	fi; \
	case "$*" in \
		"spark-assembly"|"spark") \
			bash .github/scripts/build_sbt_jars.sh --version=$$FULL_VERSION --projects=spark $$SKIP_FLAG ;; \
		"aws-online"|"aws_online") \
			bash .github/scripts/build_sbt_jars.sh --version=$$FULL_VERSION --projects=aws_online $$SKIP_FLAG ;; \
		*) \
			echo "❌ Error: JAR target '$*' not found."; \
			echo "Available targets: spark-assembly, aws-online"; \
			exit 1 ;; \
	esac

# Run tests for all modules (SBT)
test:
	@echo "🧪 Running SBT tests..."
	@FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	bash .github/scripts/build_sbt_jars.sh --version=$$FULL_VERSION
	@echo "✅ All tests passed! 🎉"

# Prepare artifacts for all JAR targets (SBT-based)
# Usage: make prepare-artifacts [FORCE_REBUILD=true]
#   FORCE_REBUILD=true: Force rebuild even if JARs exist (default: false)
FORCE_REBUILD ?= false
prepare-artifacts:
	@echo "📝 Preparing Maven artifacts for all JAR targets..."
	@# Check if JARs exist, build if missing or FORCE_REBUILD=true
	@FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	BUILD_DIR="$${CHRONON_BUILD_DIR:-build}"; \
	SPARK_JAR=$$(find "$$BUILD_DIR/jars" -name "spark_uber-assembly-*.jar" -type f 2>/dev/null | head -1); \
	AWS_JAR=$$(find "$$BUILD_DIR/jars" -name "aws-online_2.12*.jar" -type f 2>/dev/null | head -1); \
	if [ "$(FORCE_REBUILD)" = "true" ] || [ -z "$$SPARK_JAR" ] || [ -z "$$AWS_JAR" ]; then \
		echo "🔨 Building JARs (FORCE_REBUILD=$(FORCE_REBUILD), Spark=$$([ -n "$$SPARK_JAR" ] && echo "exists" || echo "missing"), AWS=$$([ -n "$$AWS_JAR" ] && echo "exists" || echo "missing"))..."; \
		$(MAKE) build SKIP_TESTS=true; \
	else \
		echo "✅ JARs already built, skipping build step"; \
	fi
	@# Create a clean artifacts directory
	@rm -rf chronon-artifacts
	@mkdir -p chronon-artifacts
	@# Prepare spark-assembly artifacts (SBT build)
	@$(MAKE) prepare-artifact-spark-assembly FORCE_REBUILD=false
	@# Prepare aws_online artifacts (SBT build)
	@$(MAKE) prepare-artifact-aws-online FORCE_REBUILD=false
	@echo "✅ All Maven artifacts prepared successfully!"
	@# Generate artifact manifest in INI format for GitHub Actions
	@bash ./.github/scripts/generate_manifest.sh
	@echo "📦 Artifacts ready in chronon-artifacts/:"
	@ls -la chronon-artifacts/
	@echo ""
	@echo "📋 Artifact manifest:"
	@cat chronon-artifacts/ARTIFACT_MANIFEST.ini

# Prepare artifacts for a specific JAR target
prepare-artifact-%: build-%
	@echo "📝 Preparing Maven artifacts for JAR target: $*"
	@case "$*" in \
		"spark-assembly"|"spark") \
			$(MAKE) prepare-artifact-spark-assembly ;; \
		"aws-online"|"aws_online") \
			$(MAKE) prepare-artifact-aws-online ;; \
		*) \
			echo "❌ Error: JAR target '$*' not found."; \
			echo "Available targets: spark-assembly, aws-online"; \
			exit 1 ;; \
	esac

# List available JAR targets
list-jars:
	@echo "Available JAR targets:"
	@echo ""
	@echo "SBT-based"
	@echo "  - spark-assembly: $$(./.github/scripts/generate_version.sh artifact_id --name=spark-assembly) (SBT: spark_uber)"
	@echo "  - aws-online: $$(./.github/scripts/generate_version.sh artifact_id --name=aws-online) (SBT: aws_online)"
	@echo ""
	@echo "Usage:"
	@echo "  make build              # Build all with SBT (default)"
	@echo "  make build-spark-assembly  # Build spark with SBT"

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
	   (cd "$$JAR_DIRNAME" && aws s3 cp "$$JAR_FILENAME" "$$S3_PATH"); \
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

# Helper to find the aws-online EMR JAR
find-aws-online-jar:
	@echo "🔍 Looking for aws-online EMR JAR in chronon-artifacts..."
	@JAR_FILE=$$(find chronon-artifacts -type f -name "*aws-online*-emr.jar" | grep -v '.sha256' | head -1); \
	if [ -z "$$JAR_FILE" ]; then \
	   echo "❌ Error: No aws-online EMR JAR found in chronon-artifacts/"; \
	   echo "Available files:"; \
	   ls -la chronon-artifacts/ || echo "chronon-artifacts directory not found"; \
	   echo ""; \
	   echo "💡 Hint: Run 'make prepare-artifacts' or 'make prepare-artifact-aws-online' first to generate the JAR files."; \
	   exit 1; \
	else \
	   echo "✅ Found JAR: $$JAR_FILE"; \
	   JAR_SIZE=$$(stat -f%z "$$JAR_FILE" 2>/dev/null || stat -c%s "$$JAR_FILE" 2>/dev/null); \
	   echo "JAR_FILE=$$JAR_FILE" > .aws_online_jar_info; \
	   echo "JAR_SIZE=$$JAR_SIZE" >> .aws_online_jar_info; \
	   echo "📦 JAR size: $$JAR_SIZE bytes"; \
	fi

# Deploy aws-online EMR JAR target
.PHONY: deploy-aws-online-jar-s3

deploy-aws-online-jar-s3: find-aws-online-jar
	@. .aws_online_jar_info; \
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
	   (cd "$$JAR_DIRNAME" && aws s3 cp "$$JAR_FILENAME" "$$S3_PATH"); \
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

# Deploy all JARs to S3 (spark-assembly and aws-online EMR)
.PHONY: deploy-all-jars-s3

deploy-all-jars-s3: deploy-spark-jar-s3 deploy-aws-online-jar-s3
	@echo "✅ All JARs deployed successfully!"

# Artifactory Repository Promotion Targets
# These targets handle the staged promotion process: subprod -> prod

# Main promotion target - promotes to subprod first, then to prod
promote-artifacts: promote-to-subprod promote-to-prod
	@echo "✅ Complete promotion pipeline finished successfully!"

# Promote artifacts to subprod repository
promote-to-subprod:
	@echo "🚀 Promoting artifacts to $(ARTIFACTORY_SUBPROD_REPO)..."
	@if [ ! -f "chronon-artifacts/ARTIFACT_MANIFEST.ini" ]; then \
	   echo "❌ Error: ARTIFACT_MANIFEST.ini not found. Run 'make prepare-artifacts' first."; \
	   exit 1; \
	fi
	@$(MAKE) _upload-to-repo REPO=$(ARTIFACTORY_SUBPROD_REPO)
	@echo "✅ Successfully promoted to $(ARTIFACTORY_SUBPROD_REPO)"

# Promote artifacts from subprod to prod using JFrog CLI copy
promote-to-prod:
	@echo "🚀 Promoting artifacts from $(ARTIFACTORY_SUBPROD_REPO) to $(ARTIFACTORY_PROD_REPO)..."
	@if [ ! -f "chronon-artifacts/ARTIFACT_MANIFEST.ini" ]; then \
	   echo "❌ Error: ARTIFACT_MANIFEST.ini not found. Run 'make prepare-artifacts' first."; \
	   exit 1; \
	fi
	@$(MAKE) _copy-to-prod
	@echo "✅ Successfully promoted to $(ARTIFACTORY_PROD_REPO)"

# Internal target to upload artifacts to a specific repository
# Parses INI format manifest and uploads each artifact
_upload-to-repo:
	@bash ./.github/scripts/upload_artifacts.sh "$(REPO)" "$(DRY_RUN)" "$(FORCE_OVERWRITE)"

# Internal target to copy artifacts from subprod to prod using JFrog CLI
# Parses INI format manifest and copies each artifact
_copy-to-prod:
	@ARTIFACTORY_SUBPROD_REPO="$(ARTIFACTORY_SUBPROD_REPO)" \
	 ARTIFACTORY_PROD_REPO="$(ARTIFACTORY_PROD_REPO)" \
	 bash ./.github/scripts/copy_artifacts.sh "$(DRY_RUN)" "$(FORCE_OVERWRITE)"

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

# ==============================================================================
# AWS ONLINE JAR BUILD TARGETS
# ==============================================================================

# Build all aws_online JARs (slim, EMR medium, Spring shaded)
# Usage: make build-aws-online [ARGS="--publish-local --delete"]
#   --publish-local  Build all JARs and publish the shaded JAR to local Maven repository (uses old script)
#   --delete         Delete the artifact from local Maven repository (uses old script)
#   If no ARGS provided, uses unified build script
.PHONY: build-aws-online
build-aws-online:
	@echo "🏗️  Building all aws_online JARs..."
	@FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	if [ -n "$(ARGS)" ]; then \
		# Use old script for --publish-local and --delete options \
		bash .github/scripts/build_aws_online_jars.sh --version=$$FULL_VERSION $(ARGS); \
	else \
		# Use unified script for standard builds \
		bash .github/scripts/build_sbt_jars.sh --version=$$FULL_VERSION --projects=aws_online; \
	fi
	@echo "✅ aws_online JAR build completed!"

# Prepare spark-assembly artifacts for Maven publishing
# SBT builds spark_uber project which outputs: spark_uber-assembly-{version}.jar
.PHONY: prepare-artifact-spark-assembly
# Usage: make prepare-artifact-spark-assembly [FORCE_REBUILD=true]
prepare-artifact-spark-assembly:
	@# Only build if JAR doesn't exist or FORCE_REBUILD is true
	@FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	BUILD_DIR="$${CHRONON_BUILD_DIR:-build}"; \
	SPARK_JAR=$$(find "$$BUILD_DIR/jars" -name "spark_uber-assembly-*.jar" -type f 2>/dev/null | head -1); \
	if [ "$(FORCE_REBUILD)" = "true" ] || [ -z "$$SPARK_JAR" ]; then \
		echo "🔨 Building spark-assembly JAR..."; \
		$(MAKE) build-spark-assembly SKIP_TESTS=true; \
	fi
	@echo "📝 Preparing Maven artifacts for spark-assembly JAR..."; \
	FULL_VERSION=$$(./.github/scripts/generate_version.sh version); \
	ARTIFACT_ID=$$(./.github/scripts/generate_version.sh artifact_id --name=spark-assembly); \
	GROUP_ID=$$(awk -F= '/^group_id/ {print $$2}' .github/MAVEN_VERSION | tr -d ' "'); \
	BUILD_DIR="$${CHRONON_BUILD_DIR:-build}"; \
	SBT_JAR=$$(find "$$BUILD_DIR/jars" -name "spark_uber-assembly-*.jar" -type f 2>/dev/null | head -1); \
	if [ -n "$$SBT_JAR" ] && [ -f "$$SBT_JAR" ]; then \
		echo "  📦 Processing spark-assembly JAR: $$(basename $$SBT_JAR)"; \
		cp "$$SBT_JAR" "chronon-artifacts/$$ARTIFACT_ID-$$FULL_VERSION.jar"; \
		sed -e "s/{{GROUP_ID}}/$$GROUP_ID/g" \
			-e "s/{{ARTIFACT_ID}}/$$ARTIFACT_ID/g" \
			-e "s/{{VERSION}}/$$FULL_VERSION/g" \
			".github/wex.pom.xml.tpl" > "chronon-artifacts/$$ARTIFACT_ID-$$FULL_VERSION.pom"; \
		(cd chronon-artifacts && sha256sum "$$ARTIFACT_ID-$$FULL_VERSION.jar" > "$$ARTIFACT_ID-$$FULL_VERSION.jar.sha256"); \
		echo "    ✅ Spark-assembly JAR prepared"; \
		echo "✅ spark-assembly artifacts prepared successfully!"; \
	else \
		echo "    ❌ Spark-assembly JAR not found: $$SBT_JAR"; \
		echo "    Looking in: $$BUILD_DIR/jars/"; \
		ls -lh "$$BUILD_DIR/jars"/*.jar 2>/dev/null || echo "      No JARs found"; \
		exit 1; \
	fi

# Prepare aws_online artifacts for Maven publishing
# Similar to prepare-artifact-spark-assembly but for aws_online JARs
# Usage: make prepare-artifact-aws-online [FORCE_REBUILD=true]
.PHONY: prepare-artifact-aws-online
prepare-artifact-aws-online:
	@bash ./.github/scripts/prepare_aws_online.sh "$(FORCE_REBUILD)"

# Clean build artifacts and generated files
# Usage: make clean
# Removes:
#   - SBT build artifacts (via sbt clean)
#   - CHRONON_BUILD_DIR (default: build/)
#   - chronon-artifacts/ directory (including manifest)
.PHONY: clean
clean:
	@echo "🧹 Cleaning build artifacts and generated files..."
	@echo "Running SBT clean..."
	@sbt clean || echo "⚠️  SBT clean failed or SBT not available, continuing..."
	@BUILD_DIR="$${CHRONON_BUILD_DIR:-build}"; \
	if [ -d "$$BUILD_DIR" ]; then \
		echo "Removing build directory: $$BUILD_DIR"; \
		rm -rf "$$BUILD_DIR"; \
		echo "  ✅ Removed $$BUILD_DIR"; \
	else \
		echo "  ℹ️  Build directory not found: $$BUILD_DIR"; \
	fi
	@if [ -d "chronon-artifacts" ]; then \
		echo "Removing chronon-artifacts directory..."; \
		rm -rf chronon-artifacts; \
		echo "  ✅ Removed chronon-artifacts/"; \
	else \
		echo "  ℹ️  chronon-artifacts/ directory not found"; \
	fi
	@echo "✅ Clean complete!"

# Setup JVM CA Certificates
# Imports Zero Trust CA certificates into the JVM keystore for build configuration.
# Supports Java 8+ (auto-detects cacerts location).
# See: docs/zero-trust-ca-setup.md for complete documentation.
#
# REQUIRED PARAMETERS:
#   JVM_HOME=/path/to/java/home    Path to the JVM to configure
#   PEM_BUNDLE=/path/to/bundle.pem Path to the PEM certificate bundle
#
# OPTIONAL PARAMETERS:
#   VERBOSE=1   Show detailed output
#   DRY_RUN=1   Preview changes without modifying cacerts
#
# Examples:
#   make setup-jvm-cas JVM_HOME=/path/to/java/home PEM_BUNDLE=~/certs/bundle.pem
#   make setup-jvm-cas JVM_HOME=/path/to/java/home PEM_BUNDLE=~/certs/bundle.pem DRY_RUN=1
#   make setup-jvm-cas JVM_HOME=/path/to/java/home PEM_BUNDLE=~/certs/bundle.pem VERBOSE=1
#
.PHONY: setup-jvm-cas
setup-jvm-cas:
	@echo "Setting up Zero Trust JVM CA certificates..."
	@set -euo pipefail; \
	JVM_HOME_VAL="${JVM_HOME}"; \
	PEM_BUNDLE_VAL="${PEM_BUNDLE}"; \
	if [ -z "$$JVM_HOME_VAL" ]; then \
	  echo "ERROR: JVM_HOME is required."; \
	  echo "Usage: make setup-jvm-cas JVM_HOME=/path/to/java/home PEM_BUNDLE=/path/to/bundle.pem"; \
	  exit 1; \
	fi; \
	if [ -z "$$PEM_BUNDLE_VAL" ]; then \
	  echo "ERROR: PEM_BUNDLE is required."; \
	  echo "Usage: make setup-jvm-cas JVM_HOME=/path/to/java/home PEM_BUNDLE=/path/to/bundle.pem"; \
	  exit 1; \
	fi; \
	if [ ! -f "$$PEM_BUNDLE_VAL" ]; then \
	  echo "ERROR: PEM bundle not found: $$PEM_BUNDLE_VAL"; \
	  exit 1; \
	fi; \
	echo "JVM Home: $$JVM_HOME_VAL"; \
	echo "PEM Bundle: $$PEM_BUNDLE_VAL"; \
	./dev-tools/setup-jvm-ca-certificates.sh \
	  --pem "$$PEM_BUNDLE_VAL" \
	  --jvm "$$JVM_HOME_VAL" \
	  --alias-prefix corp \
	  $(if $(VERBOSE),--verbose) \
	  $(if $(DRY_RUN),--dry-run)
