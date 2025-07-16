#!/bin/bash
# Usage: ./build_emr_spark.sh <aws_account_id> <region> <repository> <tag>
# Example: ./build_emr_spark.sh 123456789012 us-east-1 my-repository 0.0.1

set -euo pipefail

REGION=${2:-"us-east-1"}
TAG=${4:-"0.0.1"}

IMAGE_URI="975049916663.dkr.ecr.$REGION.amazonaws.com/chronon-spark-emr:$TAG"

echo "Building Docker image: $IMAGE_URI"
docker build --platform linux/amd64 -f emr-spark.Dockerfile . -t "$IMAGE_URI"
