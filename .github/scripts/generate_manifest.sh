#!/bin/bash
set -euo pipefail

# Script to generate ARTIFACT_MANIFEST.ini from prepared artifacts
# Usage: generate_manifest.sh

# Get version and group information
FULL_VERSION=$(./.github/scripts/generate_version.sh version)
GROUP_ID=$(awk -F= '/^group_id/ {print $2}' .github/MAVEN_VERSION | tr -d ' "')

# Helper function to add artifact entry to manifest
# Usage: add_artifact_entry <section_name> <artifact_id> <jar_file> [pom_file]
add_artifact_entry() {
    local section_name="$1"
    local artifact_id="$2"
    local jar_file="$3"
    local pom_file="${4:-}"
    
    if [ -f "chronon-artifacts/$jar_file" ]; then
        {
            echo "[$section_name]"
            echo "ARTIFACT_ID=$artifact_id"
            echo "JAR_FILE=$jar_file"
            [ -n "$pom_file" ] && echo "POM_FILE=$pom_file"
            echo "CHECKSUM_FILE=${jar_file}.sha256"
            echo ""
        } >> chronon-artifacts/ARTIFACT_MANIFEST.ini
    fi
}

echo "📋 Generating artifact manifest (INI format)..."

# Create manifest header
{
    echo "# Chronon Artifact Manifest (INI format)"
    echo "# Generated on: $(date)"
    echo "# Full Version: $FULL_VERSION"
    echo "# Group ID: $GROUP_ID"
    echo ""
} > chronon-artifacts/ARTIFACT_MANIFEST.ini

# Add spark-assembly entry
spark_artifact_id=$(./.github/scripts/generate_version.sh artifact_id --name=spark-assembly)
add_artifact_entry "spark-assembly" "$spark_artifact_id" \
    "$spark_artifact_id-$FULL_VERSION.jar" \
    "$spark_artifact_id-$FULL_VERSION.pom"

# Add aws-online entries
aws_online_artifact_id=$(./.github/scripts/generate_version.sh artifact_id --name=aws-online)

# Default artifact: slim JAR (no classifier) - has POM
add_artifact_entry "aws-online" "$aws_online_artifact_id" \
    "$aws_online_artifact_id-$FULL_VERSION.jar" \
    "$aws_online_artifact_id-$FULL_VERSION.pom"

# EMR artifact with 'emr' classifier (no POM)
add_artifact_entry "aws-online-emr" "$aws_online_artifact_id" \
    "$aws_online_artifact_id-$FULL_VERSION-emr.jar"

# Shaded artifact with 'shaded' classifier (no POM)
add_artifact_entry "aws-online-shaded" "$aws_online_artifact_id" \
    "$aws_online_artifact_id-$FULL_VERSION-shaded.jar"

