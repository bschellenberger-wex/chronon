#!/bin/bash

# Build script for aws_online JARs
# Builds all three JAR types: slim, EMR medium, and Spring shaded
# All builds run in a single SBT session for efficiency
#
# This script is called by the Makefile target: make build-aws-online
# Prefer using the Makefile: make build-aws-online
#
# Usage:
#   ./build_aws_online_jars.sh [--publish-local] [--delete]
#
# Options:
#   --publish-local  Build all JARs and publish the shaded JAR to local Maven repository (~/.m2/repository)
#   --delete         Delete the artifact from local Maven repository (if used alone, only deletes and exits)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Simple command presence guard
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}❌ Required command not found: $cmd${NC}" >&2
    exit 1
  fi
}

# Parse arguments
PUBLISH_LOCAL=false
DELETE_ARTIFACT=false

for arg in "$@"; do
    case "$arg" in
        --publish-local)
            PUBLISH_LOCAL=true
            ;;
        --delete)
            DELETE_ARTIFACT=true
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            echo "Usage: $0 [--publish-local] [--delete]"
            exit 1
            ;;
    esac
done

# Maven artifact coordinates
MAVEN_GROUP_ID="ai.chronon"
MAVEN_ARTIFACT_ID="aws_online_2.12_spark_3.5.5"
MAVEN_REPO_PATH="$HOME/.m2/repository/$(printf '%s' "$MAVEN_GROUP_ID" | tr '.' '/')/$MAVEN_ARTIFACT_ID"

# Helper function to delete artifact from local Maven repository
delete_artifact() {
    echo -e "${BLUE}🗑️  Deleting artifact from local Maven repository...${NC}"
    if [ -d "$MAVEN_REPO_PATH" ]; then
        rm -rf "$MAVEN_REPO_PATH"
        echo -e "${GREEN}✅ Deleted: $MAVEN_REPO_PATH${NC}"
    else
        echo -e "${YELLOW}⚠️  Artifact not found: $MAVEN_REPO_PATH${NC}"
    fi
}

# If --delete is specified without --publish-local, only delete and exit
if [ "$DELETE_ARTIFACT" = true ] && [ "$PUBLISH_LOCAL" = false ]; then
    delete_artifact
    echo ""
    echo -e "${GREEN}✅ Deletion complete. Exiting.${NC}"
    exit 0
fi

# Delete artifact first if --delete is specified (before building/publishing)
if [ "$DELETE_ARTIFACT" = true ]; then
    delete_artifact
    echo ""
fi

# Build JARs (always build unless we're only deleting)
# Output directory
OUTPUT_DIR="aws_online/target/scala-2.12"

echo -e "${GREEN}🏗️  Building all aws_online JARs in a single SBT session${NC}"
echo "=================================="
echo ""
echo -e "${YELLOW}Building:${NC}"
echo "  1. Slim JAR (classes only)"
echo "  2. EMR Medium JAR (excludes Spark/Hadoop)"
echo "  3. Spring Shaded JAR (includes Spark 3.5.5, shaded)"
echo ""

# Build all three JAR types in a single SBT invocation
# JVM settings: 2GB max heap, G1GC for better pause times during assembly
require_cmd sbt
if sbt \
    -J-Xmx2g \
    -J-XX:+UseG1GC \
    "set ThisBuild / use_spark_3_5 := true" \
    "project aws_online" \
    "test" \
    "package" \
    "assemblyForEmrServerless" \
    "assemblyForSpring"; then
    echo ""
    echo -e "${GREEN}✅ All JARs built successfully!${NC}"
else
    echo ""
    echo -e "${RED}❌ Failed to build JARs${NC}"
    exit 1
fi

# List built JARs
echo ""
echo -e "${GREEN}📋 Built JARs:${NC}"
echo "=================================="
if [ -d "${OUTPUT_DIR}" ]; then
    # Safely glob JARs and print only those matching our patterns. Use bash nullglob to
    # avoid literal glob when no files are found.
    shopt -s nullglob
    jar_files=("${OUTPUT_DIR}"/*.jar)
    if [ ${#jar_files[@]} -eq 0 ]; then
        echo "No JARs found"
    else
        matched=false
        for jf in "${jar_files[@]}"; do
            base=$(basename "$jf")
            case "$base" in
                *aws_online*|*assembly*) ls -lh "$jf"; matched=true ;;
            esac
        done
        if ! $matched; then
            echo "No matching JARs found"
        fi
    fi
    shopt -u nullglob
else
    echo -e "${RED}❌ Output directory not found: ${OUTPUT_DIR}${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ All aws_online JARs built successfully!${NC}"

# Publish to local Maven repository if requested
if [ "$PUBLISH_LOCAL" = true ]; then
    echo ""
    echo -e "${BLUE}📦 Publishing shaded JAR to local Maven repository...${NC}"
    echo "=================================="

    # Find the shaded JAR by exact name pattern
    # The build creates: aws_online-shaded-assembly-<version>.jar
    shopt -s nullglob
    SHADED_JAR=""
    
    # Look for the exact pattern in the output directory
    for jar_file in "$OUTPUT_DIR"/aws_online-shaded-assembly-*.jar; do
        if [ -f "$jar_file" ]; then
            SHADED_JAR="$jar_file"
            break
        fi
    done
    shopt -u nullglob

    if [ -z "$SHADED_JAR" ] || [ ! -f "$SHADED_JAR" ]; then
        echo -e "${RED}❌ Shaded JAR not found in $OUTPUT_DIR${NC}"
        echo -e "${YELLOW}   Expected pattern: aws_online-shaded-assembly-*.jar${NC}"
        echo -e "${YELLOW}   Listing all JARs in directory:${NC}"
        ls -lh "$OUTPUT_DIR"/*.jar 2>/dev/null || echo "No JARs found"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Found shaded JAR: $(basename "$SHADED_JAR")${NC}"

    # Extract version from JAR filename
    # Pattern expected exactly: aws_online-shaded-assembly-<version>.jar
    JAR_BASENAME="$(basename "$SHADED_JAR")"

    # Validate filename pattern before extraction (guards against unexpected naming)
    if [[ ! "$JAR_BASENAME" =~ ^aws_online-shaded-assembly-.*\.jar$ ]]; then
      echo -e "${RED}❌ Shaded JAR filename does not match expected pattern: $JAR_BASENAME${NC}" >&2
      echo -e "${RED}   Expected: aws_online-shaded-assembly-<version>.jar${NC}" >&2
      exit 1
    fi

    # Remove prefix and suffix using parameter expansion (preferred over external sed)
    VERSION="${JAR_BASENAME#aws_online-shaded-assembly-}"  # strip prefix
    VERSION="${VERSION%.jar}"                             # strip suffix

    # Double-check extraction result
    if [[ -z "$VERSION" ]]; then
      echo -e "${RED}❌ Version extraction produced empty string from: $JAR_BASENAME${NC}" >&2
      exit 1
    fi

    # Sanity: ensure version doesn't accidentally equal the full basename (failure case)
    if [[ "$VERSION" == "$JAR_BASENAME" ]]; then
      echo -e "${RED}❌ Version extraction failed (value equals basename): $VERSION${NC}" >&2
      exit 1
    fi

    # Require mvn only at publish time
    require_cmd mvn

    echo -e "${YELLOW}JAR:${NC} $SHADED_JAR"
    echo -e "${YELLOW}Version:${NC} $VERSION"
    echo -e "${YELLOW}GroupId:${NC} $MAVEN_GROUP_ID"
    echo -e "${YELLOW}ArtifactId:${NC} $MAVEN_ARTIFACT_ID"
    echo ""
    
    # Publish using mvn install:install-file
    if mvn install:install-file \
        -Dfile="$SHADED_JAR" \
        -DgroupId="$MAVEN_GROUP_ID" \
        -DartifactId="$MAVEN_ARTIFACT_ID" \
        -Dversion="$VERSION" \
        -Dpackaging=jar \
        -DgeneratePom=true; then
        echo ""
        echo -e "${GREEN}✅ Successfully published to local Maven repository${NC}"
        echo -e "${GREEN}   Location: $MAVEN_REPO_PATH/$VERSION${NC}"
    else
        echo ""
        echo -e "${RED}❌ Failed to publish to local Maven repository${NC}"
        exit 1
    fi
fi
