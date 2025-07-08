#!/bin/bash
# This script prepares the build environment by copying the necessary configuration files.
#
# This is a temporary workaround until a more permanent solution is implemented to make
# configurations available to Chronon through other means.
#
# This script is also useful for local development when using the Dockerfile.
#
# The infrastructure repository contains another script, copy_config_to_pod.sh, to help populate these
# configurations to a running pod in Kubernetes, so you don't have to rebuild the image.

# Exit immediately if a command exits with a non-zero status.
set -e

# Check if a source directory is provided
if [ -z "$1" ]; then
  echo "Error: No source directory provided."
  echo "Usage: ./prepare_docker_build_context.sh /path/to/chronon/configs"
  echo "The path should point to the 'chronon' directory within your local checkout of the aips-chronon-config repository (https://github.com/wexinc/aips-chronon-config)."
  echo "For example: ./prepare_docker_build_context.sh /path/to/aips-chronon-config/chronon"
  exit 1
fi

# Define the source and destination directories
# The destination directory is included in .gitignore to avoid committing it.
CHRONON_CONFIG_SRC="$1"
if [[ ! "$CHRONON_CONFIG_SRC" =~ chronon$ ]]; then
    echo "Provided path doesn't end with 'chronon'. Appending '/chronon' to the path."
    CHRONON_CONFIG_SRC="$CHRONON_CONFIG_SRC/chronon"
fi

if [ ! -d "$CHRONON_CONFIG_SRC" ]; then
    echo "ERROR: The configuration directory '$CHRONON_CONFIG_SRC' does not exist."
    echo "Please provide a valid path to your 'aips-chronon-config' repository."
    exit 1
fi

DEST_DIR="./aips-chronon-config"

# Remove the destination directory if it already exists to ensure a clean copy
if [ -d "$DEST_DIR" ]; then
  echo "Removing existing destination directory: $DEST_DIR"
  rm -rf "$DEST_DIR"
fi

# Copy the source directory to a temp location first
TMP_DIR="./aips-chronon-config-tmp"

# Ensure the temp directory is cleaned up on script exit
trap 'rm -rf "$TMP_DIR"' EXIT
if [ -d "$TMP_DIR" ]; then
  echo "Removing existing temp directory: $TMP_DIR"
  rm -rf "$TMP_DIR"
fi

echo "Copying configuration files from $CHRONON_CONFIG_SRC to $TMP_DIR"
cp -r "$CHRONON_CONFIG_SRC" "$TMP_DIR"

# Remove the production directory from the temp location if it exists
# As we don't want to include production configs in the build yet.
# This may change in the future
if [ -d "$TMP_DIR/production" ]; then
  echo "Removing production directory from temp: $TMP_DIR/production"
  rm -rf "$TMP_DIR/production"
fi

# Now copy from temp to destination
cp -a "$TMP_DIR"/. "$DEST_DIR"/

# Remove the temp directory
rm -rf "$TMP_DIR"

# Define and copy the Chronon Spark Driver JAR - currently needs to be built manually
# TODO: Automate downloading JARs from Artifactory later in Dockerfile.
if [ -z "$CHRONON_SPARK_JAR" ]; then
  echo "ERROR: CHRONON_SPARK_JAR environment variable not set."
  echo "Please build the Chronon Spark JAR first. See BUILDING_CHRONON_AT_WEX.md for instructions."
  exit 1
fi

JAR_SOURCE_PATH="$CHRONON_SPARK_JAR"

# Check if the provided path ends with .jar
if [[ ! "$JAR_SOURCE_PATH" =~ \.jar$ ]]; then
  echo "ERROR: CHRONON_SPARK_JAR must point to a .jar file. Got: $JAR_SOURCE_PATH"
  exit 1
fi

JAR_DEST_DIR="./chronon_jars" # This directory is included in .gitignore

# Check if the JAR file exists before attempting to copy
if [ ! -f "$JAR_SOURCE_PATH" ]; then
  echo "ERROR: JAR file not found at $JAR_SOURCE_PATH"
  echo "Please build or download the JAR file first, or update the JAR_SOURCE_PATH."
  exit 1
fi

# Remove the destination directory if it already exists to ensure a clean copy
if [ -d "$JAR_DEST_DIR" ]; then
  echo "Removing existing JAR destination directory: $JAR_DEST_DIR"
  rm -rf "$JAR_DEST_DIR"
fi

# Create the destination directory if it doesn't exist
mkdir -p "$JAR_DEST_DIR"

echo "Copying Chronon JAR to $JAR_DEST_DIR"
cp "$JAR_SOURCE_PATH" "$JAR_DEST_DIR/chronon_spark_driver.jar"

echo "Preparation complete. You can now build the Docker image."
