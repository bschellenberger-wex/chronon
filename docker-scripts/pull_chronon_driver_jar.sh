#!/bin/bash
# Script to pull the Chronon driver JAR from S3
# This script pulls the Chronon driver JAR from a configurable S3 bucket/path/filename and saves it to DRIVER_JAR_PATH (default: /srv/chronon/jars/spark_embedded.jar)

set -euo pipefail

# Validate required environment variables
missing_vars=()
if [[ -z "${S3_BUCKET_NAME:-}" ]]; then missing_vars+=("S3_BUCKET_NAME"); fi
if [[ -z "${S3_CHRONON_DRIVER_JAR_PATH:-}" ]]; then missing_vars+=("S3_CHRONON_DRIVER_JAR_PATH"); fi
if [[ -z "${S3_CHRONON_DRIVER_JAR_FILENAME:-}" ]]; then missing_vars+=("S3_CHRONON_DRIVER_JAR_FILENAME"); fi
if (( ${#missing_vars[@]} )); then
  echo "[ERROR] The following required environment variables are missing: ${missing_vars[*]}" >&2
  exit 1
fi

# S3 bucket, path, and filename for the Chronon driver JAR (can be overridden by env vars)
S3_CHRONON_DRIVER_JAR="s3://$S3_BUCKET_NAME/$S3_CHRONON_DRIVER_JAR_PATH/$S3_CHRONON_DRIVER_JAR_FILENAME"

# Use DRIVER_JAR_PATH or default
DRIVER_JAR_PATH="${DRIVER_JAR_PATH:-/srv/chronon/jars/spark_embedded.jar}"

mkdir -p "$(dirname "$DRIVER_JAR_PATH")"

echo "[INFO] Downloading Chronon driver JAR from S3: $S3_CHRONON_DRIVER_JAR to $DRIVER_JAR_PATH"
if aws s3 cp "$S3_CHRONON_DRIVER_JAR" "$DRIVER_JAR_PATH"; then
  echo "[INFO] Successfully downloaded Chronon driver JAR to $DRIVER_JAR_PATH"
else
  echo "[ERROR] Failed to download Chronon driver JAR from $S3_CHRONON_DRIVER_JAR"
  exit 2
fi
