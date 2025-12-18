#!/bin/bash
set -euo pipefail

# Script to copy artifacts from subprod to prod repository in Artifactory
# Usage: copy_artifacts.sh <DRY_RUN> <FORCE_OVERWRITE>
#   DRY_RUN: "true" to simulate copy, "false" to actually copy
#   FORCE_OVERWRITE: "true" to overwrite existing artifacts, "false" to fail if exists

DRY_RUN="${1:-false}"
FORCE_OVERWRITE="${2:-false}"

# Get version and group information
FULL_VERSION=$(./.github/scripts/generate_version.sh version)
GROUP_ID=$(awk -F= '/^group_id/ {print $2}' .github/MAVEN_VERSION | tr -d ' "')
GROUP_PATH=$(echo "$GROUP_ID" | tr . /)

# Repository names (from Makefile variables, passed as environment or defaults)
ARTIFACTORY_SUBPROD_REPO="${ARTIFACTORY_SUBPROD_REPO:-ai-platform-maven-subprod}"
ARTIFACTORY_PROD_REPO="${ARTIFACTORY_PROD_REPO:-ai-platform-maven-prod}"

# Set dry-run flag for JFrog CLI
DRY_RUN_FLAG=""
if [ "$DRY_RUN" = "true" ]; then
    DRY_RUN_FLAG="--dry-run"
fi

# Skip copying SNAPSHOT versions to prod (they should only be in subprod)
if echo "$FULL_VERSION" | grep -qi "SNAPSHOT"; then
    echo "⚠️  Skipping copy to prod: SNAPSHOT versions ($FULL_VERSION) should not be promoted to production"
    echo "✅ Artifacts remain in $ARTIFACTORY_SUBPROD_REPO only"
    exit 0
fi

echo "📋 Copying artifacts from $ARTIFACTORY_SUBPROD_REPO to $ARTIFACTORY_PROD_REPO..."

# Parse manifest and copy artifacts
ARTIFACT_ID=""
JAR_FILE=""
POM_FILE=""
CHECKSUM_FILE=""

while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    # Check if this is a section header
    if echo "$line" | grep -qE '^\[.*\]$'; then
        # Process previous artifact if we have all required fields
        if [ -n "$ARTIFACT_ID" ] && [ -n "$JAR_FILE" ] && [ -n "$CHECKSUM_FILE" ]; then
            echo "  Copying artifact: $ARTIFACT_ID"
            SOURCE_JAR_PATH="$ARTIFACTORY_SUBPROD_REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$JAR_FILE"
            TARGET_JAR_PATH="$ARTIFACTORY_PROD_REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$JAR_FILE"
            SOURCE_POM_PATH="$ARTIFACTORY_SUBPROD_REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$POM_FILE"

            # Check if artifact already exists (unless dry-run or force-overwrite)
            if [ "$FORCE_OVERWRITE" = "false" ] && [ -z "$DRY_RUN_FLAG" ]; then
                if jf rt s "$TARGET_JAR_PATH" | grep -q '"path"'; then
                    echo "    ❌ Artifact already exists at $TARGET_JAR_PATH. Failing as force_overwrite is false."
                    exit 1
                fi
            fi

            echo "    🔄 Copying JAR from subprod to prod..."
            jf rt cp $DRY_RUN_FLAG "$SOURCE_JAR_PATH" "$ARTIFACTORY_PROD_REPO/"

            # Copy POM if it exists in source
            if [ -n "$POM_FILE" ] && jf rt s "$SOURCE_POM_PATH" | grep -q '"path"'; then
                echo "    🔄 Copying POM from subprod to prod..."
                jf rt cp $DRY_RUN_FLAG "$SOURCE_POM_PATH" "$ARTIFACTORY_PROD_REPO/"
            fi

            echo "    ✅ Completed copying $ARTIFACT_ID"
        fi

        # Reset for next artifact
        ARTIFACT_ID=""
        JAR_FILE=""
        POM_FILE=""
        CHECKSUM_FILE=""
    else
        # Parse key-value pairs
        IFS='=' read -r key value <<< "$line" || true
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        case "$key" in
            "ARTIFACT_ID") ARTIFACT_ID="$value" ;;
            "JAR_FILE") JAR_FILE="$value" ;;
            "POM_FILE") POM_FILE="$value" ;;
            "CHECKSUM_FILE") CHECKSUM_FILE="$value" ;;
        esac
    fi
done < chronon-artifacts/ARTIFACT_MANIFEST.ini

# Process last artifact (if manifest doesn't end with empty line)
if [ -n "$ARTIFACT_ID" ] && [ -n "$JAR_FILE" ] && [ -n "$CHECKSUM_FILE" ]; then
    echo "  Copying artifact: $ARTIFACT_ID"
    SOURCE_JAR_PATH="$ARTIFACTORY_SUBPROD_REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$JAR_FILE"
    TARGET_JAR_PATH="$ARTIFACTORY_PROD_REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$JAR_FILE"
    SOURCE_POM_PATH="$ARTIFACTORY_SUBPROD_REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$POM_FILE"

    # Check if artifact already exists (unless dry-run or force-overwrite)
    if [ "$FORCE_OVERWRITE" = "false" ] && [ -z "$DRY_RUN_FLAG" ]; then
        if jf rt s "$TARGET_JAR_PATH" | grep -q '"path"'; then
            echo "    ❌ Artifact already exists at $TARGET_JAR_PATH. Failing as force_overwrite is false."
            exit 1
        fi
    fi

    echo "    🔄 Copying JAR from subprod to prod..."
    jf rt cp $DRY_RUN_FLAG "$SOURCE_JAR_PATH" "$ARTIFACTORY_PROD_REPO/"

    # Copy POM if it exists in source
    if [ -n "$POM_FILE" ] && jf rt s "$SOURCE_POM_PATH" | grep -q '"path"'; then
        echo "    🔄 Copying POM from subprod to prod..."
        jf rt cp $DRY_RUN_FLAG "$SOURCE_POM_PATH" "$ARTIFACTORY_PROD_REPO/"
    fi

    echo "    ✅ Completed copying $ARTIFACT_ID"
fi

