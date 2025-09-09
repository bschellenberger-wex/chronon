#!/bin/bash

# AIPS Chronon Version Generator
# Generates appropriate versions for Maven artifacts based on build configuration

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAVEN_VERSION_FILE="$PROJECT_ROOT/.github/MAVEN_VERSION"

# Default values
BASE_VERSION="0.0.1"
SCALA_VERSION=2.12
SPARK_VERSION=3.5
GROUP_ID="${GROUP_ID:-com.wex.chronon}"

# Load version from MAVEN_VERSION file if it exists
if [ ! -f "$MAVEN_VERSION_FILE" ]; then
    echo "❌ Error: MAVEN_VERSION file not found at $MAVEN_VERSION_FILE" >&2
    exit 1
fi

while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ $key =~ ^[[:space:]]*# ]] && continue
    [[ -z $key ]] && continue
    # Trim whitespace
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | xargs)"
    case "$key" in
        "base_version") BASE_VERSION="$value" ;;
        "group_id") GROUP_ID="$value" ;;
    esac
done < "$MAVEN_VERSION_FILE"

# Function to generate version string
generate_version() {
    echo "${BASE_VERSION}"
}

# Function to generate artifactId
# For 'spark-assembly': spark-assembly_{spark.version}_scala_{scala.version}
# For other artifacts: {base_name}_scala_{scala.version}
generate_artifact_id() {
    local spark_ver="$1"
    local scala_ver="$2"
    local base_name="${3:-spark-assembly}" # The base name of the artifact, e.g., 'spark-assembly', 'online-lib'

    if [ "$base_name" = "spark-assembly" ]; then
        echo "spark-assembly_${spark_ver}_scala_${scala_ver}"
    else
        echo "${base_name}_scala_${scala_ver}"
    fi
}

# Main execution
main() {
    local action="${1:-version}"
    local base_name="spark-assembly" # Default base name

    # Allow --name argument for explicit artifact base name
    for arg in "$@"; do
        case $arg in
            --name=*) base_name="${arg#*=}" ;;
        esac
    done

    case "$action" in
        "version")
            generate_version
            ;;
        "artifact_id")
            generate_artifact_id "$SPARK_VERSION" "$SCALA_VERSION" "$base_name"
            ;;
        *)
            echo "Usage: $0 [version|artifact_id] [--name=<artifact_base_name>]" >&2
            exit 1
            ;;
    esac
}

main "$@"

