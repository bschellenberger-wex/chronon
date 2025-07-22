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

# Check if the artifact already exists in S3
if aws s3 ls "$S3_PATH/$JAR" >/dev/null 2>&1; then
  if [[ "$JAR" == *SNAPSHOT* ]]; then
    echo "Warning: Overwriting existing SNAPSHOT artifact in S3: $S3_PATH/$JAR"
    read -p "Are you sure you want to overwrite this SNAPSHOT artifact? Type YES to continue: " confirm
    if [[ "$confirm" != "YES" ]]; then
      echo "Aborting upload."
      exit 4
    fi
  else
    echo "Error: Artifact $S3_PATH/$JAR already exists and is not a SNAPSHOT. Aborting to prevent overwrite." >&2
    exit 3
  fi
fi

echo "Uploading $JAR to $S3_PATH/"
aws s3 cp "$JAR" "$S3_PATH/"

if [ $? -eq 0 ]; then
  echo "Successfully uploaded to $S3_PATH/$JAR"
else
  echo "Upload failed."
  exit 2
fi
