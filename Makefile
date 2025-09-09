# Use bash for all shell commands
SHELL := /bin/bash

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

.PHONY: lint image-package image-push local-run docker-shell compose-up print-image-info image-package-emr-spark image-push-emr-spark build test prepare-artifacts list-jars promote-artifacts promote-to-subprod promote-to-prod
lint:
	echo "👕 lint"
	black src
	isort --profile black src
# NOTE: these are legacy commands that will get refactored when we automate the build process for the Dockerfiles.
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