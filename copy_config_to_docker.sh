#!/bin/bash
# Script to copy/update chronon config files to a running Docker container

# Configuration - set your source path here
if [ -z "$1" ]; then
    echo "Error: Please provide the source path for the Chronon configurations."
    echo "Usage: $0 <source-path>"
    echo "Example: $0 /Users/W517590/Projects/aips-chronon-config/chronon"
    exit 1
fi

SOURCE_PATH="$1"
if [[ ! "$SOURCE_PATH" =~ chronon$ ]]; then
    echo "Provided path doesn't end with 'chronon'. Appending '/chronon' to the path."
    SOURCE_PATH="$SOURCE_PATH/chronon"
fi

if [ ! -d "$SOURCE_PATH" ]; then
    echo "ERROR: The configuration directory '$SOURCE_PATH' does not exist."
    echo "Please provide a valid path to your 'aips-chronon-config' repository."
    exit 1
fi

# Destination path in the Docker container
DEST_PATH="/srv/chronon"

# Get the running Docker Compose service container name for 'main'
CONTAINER_ID=$(docker-compose ps -q main)

if [ -z "$CONTAINER_ID" ]; then
  echo "Error: No running Docker Compose container found for service 'main'"
  exit 1
fi

echo "Found container: $CONTAINER_ID"

# First, clear out the existing contents of the destination directory in the container
echo "Clearing existing files in $DEST_PATH..."
docker exec $CONTAINER_ID bash -c "rm -rf $DEST_PATH/* $DEST_PATH/.[!.]*"

# Copy all files from the local directory to the container
# Use docker cp to copy the entire contents (including hidden files) in one command

docker cp "$SOURCE_PATH/." $CONTAINER_ID:$DEST_PATH/

# Verify the copy was successful
echo "Verifying files were copied..."
docker exec $CONTAINER_ID ls -la $DEST_PATH

echo "Done! Files have been completely overwritten in the container."
