#!/bin/bash
set -euo pipefail

# Script to upload artifacts to Artifactory repository
# Usage: upload_artifacts.sh <REPO> <DRY_RUN> <FORCE_OVERWRITE>
#   REPO: Artifactory repository name (e.g., ai-platform-maven-subprod)
#   DRY_RUN: "true" to simulate upload, "false" to actually upload
#   FORCE_OVERWRITE: "true" to overwrite existing artifacts, "false" to fail if exists
# Uploads all artifacts listed in chronon-artifacts/ARTIFACT_MANIFEST.ini, including JARs, POMs, and checksum files.
REPO="${1:?Error: REPO argument required}"
DRY_RUN="${2:-false}"
FORCE_OVERWRITE="${3:-false}"

# Get version and group information
FULL_VERSION=$(./.github/scripts/generate_version.sh version)
GROUP_ID=$(awk -F= '/^group_id/ {print $2}' .github/MAVEN_VERSION | tr -d ' "')
GROUP_PATH=$(echo "$GROUP_ID" | tr . /)

# Set dry-run flag for JFrog CLI
DRY_RUN_FLAG=""
if [ "$DRY_RUN" = "true" ]; then
    DRY_RUN_FLAG="--dry-run"
fi

echo "📦 Uploading artifacts to $REPO..."

# Parse manifest and upload artifacts
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
            echo "  Processing artifact: $ARTIFACT_ID"
            JAR_PATH="$REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$JAR_FILE"
            POM_PATH="$REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$POM_FILE"

            # Check if artifact already exists (unless dry-run or force-overwrite)
            if [ "$FORCE_OVERWRITE" = "false" ] && [ -z "$DRY_RUN_FLAG" ]; then
                if jf rt s "$JAR_PATH" | grep -q '"path"'; then
                    echo "    ❌ Artifact already exists at $JAR_PATH. Failing as force_overwrite is false."
                    exit 1
                fi
            fi

            echo "    🚀 Uploading to $REPO..."
            jf rt u $DRY_RUN_FLAG "chronon-artifacts/$JAR_FILE" "$JAR_PATH"

            # Upload POM if it exists
            if [ -n "$POM_FILE" ] && [ -f "chronon-artifacts/$POM_FILE" ]; then
                jf rt u $DRY_RUN_FLAG "chronon-artifacts/$POM_FILE" "$POM_PATH"
            fi

            echo "    ✅ Completed $ARTIFACT_ID"
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
    echo "  Processing artifact: $ARTIFACT_ID"
    JAR_PATH="$REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$JAR_FILE"
    POM_PATH="$REPO/$GROUP_PATH/$ARTIFACT_ID/$FULL_VERSION/$POM_FILE"

    # Check if artifact already exists (unless dry-run or force-overwrite)
    if [ "$FORCE_OVERWRITE" = "false" ] && [ -z "$DRY_RUN_FLAG" ]; then
        if jf rt s "$JAR_PATH" | grep -q '"path"'; then
            echo "    ❌ Artifact already exists at $JAR_PATH. Failing as force_overwrite is false."
            exit 1
        fi
    fi

    echo "    🚀 Uploading to $REPO..."
    jf rt u $DRY_RUN_FLAG "chronon-artifacts/$JAR_FILE" "$JAR_PATH"

    # Upload POM if it exists
    if [ -n "$POM_FILE" ] && [ -f "chronon-artifacts/$POM_FILE" ]; then
        jf rt u $DRY_RUN_FLAG "chronon-artifacts/$POM_FILE" "$POM_PATH"
    fi

    echo "    ✅ Completed $ARTIFACT_ID"
fi

