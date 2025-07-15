#!/bin/bash
# Usage: ./build_emr_spark.sh <aws_account_id> <region> <repository> <tag>
# Example: ./build_emr_spark.sh 123456789012 us-east-1 my-repository 0.0.1

set -euo pipefail

REGION=${2:-"us-east-1"}
TAG=${4:-"0.0.1"}

IMAGE_URI="975049916663.dkr.ecr.$REGION.amazonaws.com/chronon-emr-spark:$TAG"

echo "Building Docker image: $IMAGE_URI"
docker build -f Dockerfile.emr-spark . -t "$IMAGE_URI"