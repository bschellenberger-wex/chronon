#!/bin/bash

# Default versions
SPARK_VERSION="3.5"
SCALA_VERSION="2.12"
JAVA_CONFIG="java_11"

# Allow overrides via environment variables
SPARK_VERSION="${SPARK_VERSION_OVERRIDE:-$SPARK_VERSION}"
SCALA_VERSION="${SCALA_VERSION_OVERRIDE:-$SCALA_VERSION}"
JAVA_CONFIG="${JAVA_CONFIG_OVERRIDE:-$JAVA_CONFIG}"

# Extract Chronon version from version.sbt
CHRONON_VERSION=$(grep '^version *:=' version.sbt | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$CHRONON_VERSION" ]; then
  echo "Error: Could not extract Chronon version from version.sbt" >&2
  exit 1
fi

# Print settings
echo "Building Chronon Spark JAR with:"
echo "  Chronon version: $CHRONON_VERSION"
echo "  Spark version: $SPARK_VERSION"
echo "  Scala version: $SCALA_VERSION"
echo "  Java config: $JAVA_CONFIG"

# Run Bazel build
bazel build --config "$JAVA_CONFIG" --config "scala_$SCALA_VERSION" --config "spark_$SPARK_VERSION" //spark:spark-assembly_deploy.jar

# Output location of built JAR
JAR_PATH="bazel-bin/spark/spark-assembly_deploy.jar"
if [ ! -f "$JAR_PATH" ]; then
  echo "Error: Built JAR not found at $JAR_PATH" >&2
  exit 2
fi

# Versioned artifact name
VERSIONED_JAR="chronon-spark-assembly_${CHRONON_VERSION}_spark${SPARK_VERSION}_scala${SCALA_VERSION}.jar"
cp "$JAR_PATH" "$VERSIONED_JAR"
echo "Versioned Spark JAR: $VERSIONED_JAR"
