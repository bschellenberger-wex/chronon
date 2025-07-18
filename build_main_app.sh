#!/bin/bash
# Usage: ./build_main_app.sh
# Example: ./build_main_app.sh
#
# Tag is always read from VERSION file. Passing a tag as an argument is not allowed.

set -euo pipefail

ARTIFACTORY_REGISTRY_URL="usartifactorywexinc.jfrog.io"
MAIN_APP_IMAGE_NAME="ai-platform-docker-subprod/chronon-app"

if [ "$#" -ne 0 ]; then
  echo "ERROR: No arguments allowed. Tag is always read from VERSION file." >&2
  exit 1
fi

if [ -f VERSION ]; then
  TAG="$(cat VERSION)"
else
  echo "ERROR: VERSION file not found." >&2
  exit 1
fi

IMAGE_URI="$ARTIFACTORY_REGISTRY_URL/$MAIN_APP_IMAGE_NAME:$TAG"

echo "Building Docker image: $IMAGE_URI"
docker build --platform linux/amd64 -f Dockerfile . -t "$IMAGE_URI"
