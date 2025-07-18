#!/bin/bash
# Usage: ./build_emr_spark.sh <aws_account_id> <region> <repository>
# Example: ./build_emr_spark.sh 123456789012 us-east-1 chronon-spark-emr
#
# The tag is always read from VERSION.emr-spark. If the file is missing or empty, the script will fail.

set -euo pipefail

AWS_ACCOUNT_ID=${1:-"975049916663"}
REGION=${2:-"us-east-1"}
REPOSITORY=${3:-"chronon-spark-emr"}

if [ ! -f VERSION.emr-spark ]; then
  echo "ERROR: VERSION.emr-spark file not found. Please create this file with the desired tag." >&2
  exit 1
fi

TAG="$(tr -d '[:space:]' < VERSION.emr-spark)"
if [ -z "$TAG" ]; then
  echo "ERROR: VERSION.emr-spark is empty. Please specify a tag in this file." >&2
  exit 1
fi

IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPOSITORY:$TAG"

echo "Building Docker image: $IMAGE_URI"
docker build --platform linux/amd64 -f emr-spark.Dockerfile . -t "$IMAGE_URI"
