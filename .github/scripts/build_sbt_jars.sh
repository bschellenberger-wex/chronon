#!/bin/bash
set -euo pipefail

# Unified script to build both Spark and AWS Online JARs using SBT
# Usage: build_sbt_jars.sh [--version=VERSION] [--projects=PROJECTS] [--skip-tests]
#   --version=VERSION: Custom version to use (overrides SBT git-based versioning)
#   --projects=PROJECTS: Comma-separated list of projects to build (spark,aws_online). Default: all
#   --skip-tests: Skip running tests during build

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
CUSTOM_VERSION=""
PROJECTS=""
SKIP_TESTS=false

for arg in "$@"; do
    case "$arg" in
        --version=*)
            CUSTOM_VERSION="${arg#*=}"
            ;;
        --projects=*)
            PROJECTS="${arg#*=}"
            ;;
        --skip-tests)
            SKIP_TESTS=true
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            echo "Usage: $0 [--version=VERSION] [--projects=PROJECTS] [--skip-tests]"
            exit 1
            ;;
    esac
done

# Set build output directory (can be overridden via CHRONON_BUILD_DIR env var)
export CHRONON_BUILD_DIR="${CHRONON_BUILD_DIR:-$(pwd)/build}"

# Ensure build directory exists
mkdir -p "$CHRONON_BUILD_DIR/jars"

echo -e "${GREEN}🏗️  Building Chronon JARs with SBT${NC}"
echo "=================================="
echo ""

# Determine which projects to build
if [ -z "$PROJECTS" ]; then
    # Build all projects
    PROJECTS_TO_BUILD=("spark_uber" "aws_online")
    echo -e "${YELLOW}Building all projects: spark_uber, aws_online${NC}"
else
    # Parse comma-separated project list
    IFS=',' read -ra PROJECT_ARRAY <<< "$PROJECTS"
    PROJECTS_TO_BUILD=()
    for proj in "${PROJECT_ARRAY[@]}"; do
        # Normalize project names
        case "$proj" in
            "spark"|"spark-assembly")
                PROJECTS_TO_BUILD+=("spark_uber")
                ;;
            "aws_online"|"aws-online")
                PROJECTS_TO_BUILD+=("aws_online")
                ;;
            *)
                echo -e "${RED}❌ Unknown project: $proj${NC}"
                echo "Available projects: spark, aws_online"
                exit 1
                ;;
        esac
    done
    echo -e "${YELLOW}Building projects: ${PROJECTS_TO_BUILD[*]}${NC}"
fi

# Build SBT commands
SBT_CMDS=(
    "set ThisBuild / use_spark_3_5 := true"
)

# Override version if custom version is provided
if [ -n "$CUSTOM_VERSION" ]; then
    echo -e "${YELLOW}Using custom version: $CUSTOM_VERSION${NC}"
fi

# Build each project
for project in "${PROJECTS_TO_BUILD[@]}"; do
    echo ""
    echo -e "${BLUE}📦 Building project: $project${NC}"
    
    PROJECT_CMDS=(
        "project $project"
    )
    
    # Set version at project level if custom version provided
    if [ -n "$CUSTOM_VERSION" ]; then
        PROJECT_CMDS+=("set version := \"$CUSTOM_VERSION\"")
    fi
    
    # Add build commands based on project
    case "$project" in
        "spark_uber")
            # We skip open source project tests for a few reasons:
            # 1. The tests are run as part of CI/CD in the OSS repo
            # 2. Long time to run and complexity of the tests
            # 3. We can re-use test results from the OSS repo since we have not made any changes to the code or tests
            PROJECT_CMDS+=("assembly")
            ;;
        "aws_online")
            # aws_online: Run tests unless --skip-tests is passed - runs our tests for our custom code
            if [ "$SKIP_TESTS" = "false" ]; then
                PROJECT_CMDS+=("test")
            fi
            PROJECT_CMDS+=("package")
            PROJECT_CMDS+=("assemblyForEmrServerless")
            PROJECT_CMDS+=("assemblyForSpring")
            ;;
    esac
    
    # Run SBT commands for this project
    if ! sbt -error -J-Xmx4g -J-Xms2g -J-XX:MaxMetaspaceSize=2048m "${SBT_CMDS[@]}" "${PROJECT_CMDS[@]}"; then
        echo -e "${RED}❌ Failed to build $project${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}✅ All JARs built successfully!${NC}"
echo ""
echo -e "${GREEN}📋 Built JARs:${NC}"
echo "=================================="
echo ""
echo "Directory: $CHRONON_BUILD_DIR/jars"
JAR_COUNT=0
if [ -d "$CHRONON_BUILD_DIR/jars" ]; then
    # Use shopt to handle cases where glob doesn't match
    shopt -s nullglob || true
    for jar in "$CHRONON_BUILD_DIR/jars"/*.jar; do
        if [ -f "$jar" ]; then
            # Get file size, with fallback if du fails
            SIZE=$(du -h "$jar" 2>/dev/null | cut -f1 || stat -f%z "$jar" 2>/dev/null || echo "unknown")
            echo "  $(basename "$jar") ($SIZE)"
            JAR_COUNT=$((JAR_COUNT + 1)) || true
        fi
    done
    shopt -u nullglob || true
    if [ $JAR_COUNT -eq 0 ]; then
        echo -e "${YELLOW}  ⚠️  No JARs found in $CHRONON_BUILD_DIR/jars${NC}"
        echo -e "${YELLOW}  Note: JARs may be in SBT's default target directories${NC}"
    fi
else
    echo -e "${YELLOW}  ⚠️  Build directory not found: $CHRONON_BUILD_DIR/jars${NC}"
fi
echo ""
echo -e "${GREEN}✅ All SBT JARs built successfully!${NC}"
