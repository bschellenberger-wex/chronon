#!/bin/bash
set -euo pipefail

# Script to prepare aws_online artifacts for Maven publishing
# Usage: prepare_aws_online.sh [FORCE_REBUILD]
#   FORCE_REBUILD: "true" to force rebuild, "false" to skip if JARs exist (default: "false")
# If FORCE_REBUILD is false and JARs already exist, the script will skip the build and proceed directly to artifact preparation.

FORCE_REBUILD="${1:-false}"

# Get version and artifact information
FULL_VERSION=$(./.github/scripts/generate_version.sh version)
ARTIFACT_ID=$(./.github/scripts/generate_version.sh artifact_id --name=aws-online)
GROUP_ID=$(awk -F= '/^group_id/ {print $2}' .github/MAVEN_VERSION | tr -d ' "')
BUILD_DIR="${CHRONON_BUILD_DIR:-build}"

# Check if we need to build
AWS_JAR=$(find "$BUILD_DIR/jars" -name "aws-online_2.12*.jar" -type f 2>/dev/null | head -1)
if [ "$FORCE_REBUILD" = "true" ] || [ -z "$AWS_JAR" ]; then
    echo "🔨 Building aws_online JARs..."
    make build-aws-online SKIP_TESTS=true
fi

# Ensure artifacts directory exists
mkdir -p chronon-artifacts

echo "📝 Preparing Maven artifacts for aws-online JARs..."
echo "Processing aws-online JARs (slim=default, emr=classifier, shaded=classifier)..."

# Process slim JAR (default artifact, no classifier)
SLIM_JAR=$(find "$BUILD_DIR/jars" -name "aws-online_2.12*.jar" -type f 2>/dev/null | grep -v assembly | head -1)
if [ -n "$SLIM_JAR" ] && [ -f "$SLIM_JAR" ]; then
    echo "  📦 Processing slim JAR (default artifact, no classifier): $(basename "$SLIM_JAR")"
    cp "$SLIM_JAR" "chronon-artifacts/$ARTIFACT_ID-$FULL_VERSION.jar"
    sed -e "s/{{GROUP_ID}}/$GROUP_ID/g" \
        -e "s/{{ARTIFACT_ID}}/$ARTIFACT_ID/g" \
        -e "s/{{VERSION}}/$FULL_VERSION/g" \
        ".github/wex.pom.xml.tpl" > "chronon-artifacts/$ARTIFACT_ID-$FULL_VERSION.pom"
    (cd chronon-artifacts && sha256sum "$ARTIFACT_ID-$FULL_VERSION.jar" > "$ARTIFACT_ID-$FULL_VERSION.jar.sha256")
    echo "    ✅ Slim JAR prepared (default artifact)"
fi

# Process EMR JAR (emr classifier)
EMR_JAR=$(find "$BUILD_DIR/jars" -name "aws-online-emr-assembly-*.jar" -type f 2>/dev/null | head -1)
if [ -n "$EMR_JAR" ] && [ -f "$EMR_JAR" ]; then
    echo "  📦 Processing EMR medium JAR (emr classifier): $(basename "$EMR_JAR")"
    cp "$EMR_JAR" "chronon-artifacts/$ARTIFACT_ID-$FULL_VERSION-emr.jar"
    (cd chronon-artifacts && sha256sum "$ARTIFACT_ID-$FULL_VERSION-emr.jar" > "$ARTIFACT_ID-$FULL_VERSION-emr.jar.sha256")
    echo "    ✅ EMR medium JAR prepared (emr classifier)"
fi

# Process Shaded JAR (shaded classifier)
SHADED_JAR=$(find "$BUILD_DIR/jars" -name "aws-online-shaded-assembly-*.jar" -type f 2>/dev/null | head -1)
if [ -n "$SHADED_JAR" ] && [ -f "$SHADED_JAR" ]; then
    echo "  📦 Processing Spring shaded JAR (shaded classifier): $(basename "$SHADED_JAR")"
    cp "$SHADED_JAR" "chronon-artifacts/$ARTIFACT_ID-$FULL_VERSION-shaded.jar"
    (cd chronon-artifacts && sha256sum "$ARTIFACT_ID-$FULL_VERSION-shaded.jar" > "$ARTIFACT_ID-$FULL_VERSION-shaded.jar.sha256")
    echo "    ✅ Spring shaded JAR prepared (shaded classifier)"
fi

echo "✅ aws-online artifacts prepared successfully!"

