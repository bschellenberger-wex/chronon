#!/bin/bash

# Usage: ./push_spark_jar_to_s3.sh [dev|stage|prod]
# Default environment is dev

set -e

ENV="${1:-dev}"
BUCKET="ai-chronon-emr-serverless-resources-${ENV}"
S3_PATH="s3://${BUCKET}/chronon-driver-jars"

# Find the most recent versioned JAR in the current directory
JAR=$(find . -maxdepth 1 -type f -name 'chronon-spark-assembly_*.jar' -print0 | xargs -0 ls -t | head -n1 | sed 's|^./||')

if [ -z "$JAR" ]; then
  echo "Error: No chronon-spark-assembly_*.jar found in the current directory." >&2
  exit 1
fi

echo "Uploading $JAR to $S3_PATH/"
aws s3 cp "$JAR" "$S3_PATH/"

if [ $? -eq 0 ]; then
  echo "Successfully uploaded to $S3_PATH/$JAR"
else
  echo "Upload failed."
  exit 2
fi
