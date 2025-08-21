#!/bin/bash
set -euo pipefail

# --- Chronon Config S3 Pull Script ---
# This script pulls the latest Chronon config zip from S3 and unzips it to /srv/chronon

# Required env vars (should be set via Helm/values):
#   S3_BUCKET_NAME
#   S3_CONFIG_PATH
# Optional override:
#   CHRONON_CONFIG_ZIP_OVERRIDE

CONFIG_DIR="/srv/chronon/configs"

if [[ -z "${S3_BUCKET_NAME:-}" || -z "${S3_CONFIG_PATH:-}" ]]; then
  echo "[ERROR] S3_BUCKET_NAME and S3_CONFIG_PATH environment variables must be set."
  exit 1
fi

# Determine zip file name
if [[ -n "${CHRONON_CONFIG_ZIP_OVERRIDE:-}" ]]; then
  ZIP_FILE_NAME="$CHRONON_CONFIG_ZIP_OVERRIDE"
  echo "[INFO] Using override zip file: $ZIP_FILE_NAME"
else
  # Download latest.txt to get the latest zip file name
  LATEST_FILE=$(mktemp)
  aws s3 cp "s3://$S3_BUCKET_NAME/$S3_CONFIG_PATH/latest.txt" "$LATEST_FILE"
  ZIP_FILE_NAME=$(tr -d '\r\n' < "$LATEST_FILE")
  rm -f "$LATEST_FILE"
  if [[ -z "$ZIP_FILE_NAME" ]]; then
    echo "[ERROR] latest.txt is empty or missing."
    exit 1
  fi
  echo "[INFO] Using zip file from latest.txt: $ZIP_FILE_NAME"
fi

# Download the zip file
aws s3 cp "s3://$S3_BUCKET_NAME/$S3_CONFIG_PATH/$ZIP_FILE_NAME" /tmp/chronon-configs.zip

# Unzip to config directory (overwrite existing)
if [[ -z "${CONFIG_DIR:-}" ]]; then
  echo "[ERROR] CONFIG_DIR is not set. Aborting to prevent data loss."
  exit 1
fi

# Remove CONFIG_DIR to ensure it is empty
rm -rf "${CONFIG_DIR:?}"

if unzip -o /tmp/chronon-configs.zip -d "${CONFIG_DIR:?}"; then
  echo "[INFO] Unzip successful."
  rm -f /tmp/chronon-configs.zip
else
  echo "[ERROR] Failed to unzip /tmp/chronon-configs.zip to ${CONFIG_DIR:?}."
  exit 1
fi

echo "[INFO] Chronon configs updated in $CONFIG_DIR."
