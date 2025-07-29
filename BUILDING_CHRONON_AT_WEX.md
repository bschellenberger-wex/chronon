# Building Chronon at WEX

* [Prerequisites](#prerequisites)
* [Building with Bazel](#building-with-bazel)
    * [Selecting Java Version](#selecting-java-version)
    * [VPN and Java Keystore](#vpn-and-java-keystore)
    * [Building for a specific Spark version](#building-for-a-specific-spark-version)
    * [Building the Spark JAR](#building-the-spark-jar)
    * [Uploading Artifacts to S3](#uploading-artifacts-to-s3)
    * [Available Spark Versions](#available-spark-versions)
* [Building Other Artifacts](#building-other-artifacts)
* [Docker](#docker)
    * [Prerequisites for Docker Builds](#prerequisites-for-docker-builds)
    * [Building the Main Chronon Docker Image](#building-the-main-chronon-docker-image)
    * [Building the EMR Spark Docker Image](#building-the-emr-spark-docker-image)
    * [Defense Mechanisms](#defense-mechanisms)
* [SBT Build (Not Recommended)](#sbt-build-not-recommended)

This document outlines the process for building Chronon artifacts at WEX. Due to specific version requirements for Spark, it's necessary to build Chronon from source to ensure compatibility.

## Prerequisites

- **Install Thrift v0.13**: Thrift v0.13 is required for both Linux and macOS builds. For macOS, it is recommended to use Homebrew as the build scripts have been adjusted for it. Please see `devnotes.md` for specific commands.
- **Install Bazelisk**: Install Bazelisk, a user-friendly launcher for Bazel.
  ```shell
  brew install bazelisk
  ```
- Java Development Kit (JDK) is installed.
- Python is installed.

## Building with Bazel

The Bazel build system is configured to produce versioned artifacts that include the Spark and Scala versions in the name. This is the recommended way to build Chronon. Spark versions are generally binary compatible within minor versions. For example, a build for a `3.5.x` version of Spark is compatible with all other `3.5.x` versions, a build for `3.4.x` is compatible with all other `3.4.x` versions, and so on.

We provide helper scripts to simplify building and publishing Chronon artifacts. These scripts ensure that your JARs are versioned with the Chronon, Spark, and Scala versions for traceability and compatibility.

### Selecting Java Version

You can specify the Java version for the compilation by using the appropriate `--config` flag. For example, to build with Java 11, you would use `--config java_11`.

It's important to note that Bazel manages its own JDK toolchains for compilation. This means that even if you are running Bazel with a newer JDK (e.g., your `$JAVA_HOME` is set to Java 21), you can still compile Chronon against an older version like Java 11 by using the corresponding flag.

### VPN and Java Keystore

If you are behind a VPN, you may need to add the root CA to the Java keystore of the JDK that Bazel uses to run. You can point Bazel to this JDK by setting the `--server_javabase` flag.

The following command shows how to run Bazel with a Java 21 JDK, but compile the code using the Java 11 toolchain:

```bash
bazel --server_javabase=$JAVA_HOME build --config java_11 --config scala_2.12 --config spark_3.5 //spark:spark-assembly_deploy.jar
```

### Building for a specific Spark version

To build Chronon for a specific Spark version, you need to use the appropriate build flags. For example, to build for Spark 3.5, you would use the `--config spark_3.5` flag.

The following command will build the `spark-assembly` target for Spark 3.5 with Scala 2.12 and the Java 11 toolchain:

```bash
bazel build --config java_11 --config scala_2.12 --config spark_3.5 //spark:spark-assembly_deploy.jar
```

### Building the Spark JAR

Use the provided script to build the Spark JAR with Bazel and produce a versioned artifact:

```bash
./build_spark_jar.sh
```

This will output a JAR named like:

```
chronon-spark-assembly_<CHRONON_VERSION>_spark<SPARK_VERSION>_scala<SCALA_VERSION>.jar
```

You can override the Spark, Scala, or Java version by setting environment variables before running the script:

```bash
SPARK_VERSION_OVERRIDE=3.5 SCALA_VERSION_OVERRIDE=2.12 JAVA_CONFIG_OVERRIDE=java_11 ./build_spark_jar.sh
```

### Uploading Artifacts to S3

To upload the most recent versioned Spark JAR to S3, use the provided script:

```bash
./push_spark_jar_to_s3.sh [dev|stage|prod]
```

- The default environment is `dev`.
- The JAR will be uploaded to:
  - `s3://ai-chronon-emr-serverless-resources-<env>/chronon-driver-jars/`

**Make sure you are logged into the appropriate AWS environment (e.g., using `aws sso login` or setting the correct AWS profile) before running the upload script.**

Example:

```bash
./push_spark_jar_to_s3.sh stage
```

This will upload to the `stage` bucket. The script will print the S3 path of the uploaded artifact.

### Available Spark Versions

The available Spark versions are defined in `jvm/spark_repos.bzl`. You can check this file to see the available versions and their corresponding build flags.

## Building Other Artifacts

Besides the Spark uber JAR, you may need to build other Chronon artifacts. The `devnotes.md` file contains a comprehensive list of build targets and commands.

Here are some common examples:

- **Build all targets:**
  ```bash
  bazel build //...
  ```

- **Build a specific module:**
  ```bash
  # Build the aggregator module
  bazel build //aggregator:aggregator

  # Build the online module
  bazel build //online:online
  ```

For more detailed information on building, testing, and dependency management, please refer to the [devnotes.md](devnotes.md) file.

## Docker

This section provides instructions for building and publishing the Chronon Docker image for local development and testing (to Artifactory), as well as the EMR Spark image for EMR Serverless (to ECR).

### Prerequisites for Docker Builds

- **Set Required Environment Variables:**
  - `CHRONON_CONFIG_PATH`: Path to your local `chronon` configuration directory (e.g., `/path/to/aips-chronon-config/chronon`).
  - `CHRONON_SPARK_JAR`: Path to your Chronon Spark JAR (e.g., `/path/to/bazel-bin/spark/spark-assembly_deploy.jar`).
- **Authenticate to Registries Before Pushing:**
  - For Artifactory: `docker login usartifactorywexinc.jfrog.io -u {wexid}`
    - When prompted for a password, use your Artifactory API Key.
  - For ECR: `aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 975049916663.dkr.ecr.us-east-1.amazonaws.com`

### Building the Main Chronon Docker Image

1. **Prepare the Build Context**

   The `prepare_docker_build_context.sh` script copies the Chronon Spark JAR and your local Chronon configurations into the Docker build context. You must set the required environment variables before running the build:

   ```bash
   export CHRONON_CONFIG_PATH=/path/to/aips-chronon-config/chronon
   export CHRONON_SPARK_JAR=/path/to/bazel-bin/spark/spark-assembly_deploy.jar
   make image-package
   ```

   The Makefile will check for these environment variables and fail early if they are not set.

2. **Build the Image**

   The `image-package` target will run the build scripts and produce a Docker image tagged for Artifactory. The tag is always read from the `VERSION` file—passing a tag as an argument is not allowed and will result in an error.

3. **Push the Image (Release Only)**

   Only strict semantic version tags (e.g., `1.2.3`) can be pushed. The Makefile will block pushes for SNAPSHOT or non-semver tags, and will also prevent overwriting existing tags in Artifactory.

   ```bash
   make image-push
   ```

   **Note:** Authenticate to Artifactory before pushing.

### Building the EMR Spark Docker Image

1. **Build the Image**

   The EMR Spark image can be built using the Makefile target (recommended):

   ```bash
   make image-package-emr-spark
   ```

   Alternatively, you can use the `build_emr_spark.sh` script directly. The script will always use the tag specified in the `VERSION.emr-spark` file:

   ```bash
   ./build_emr_spark.sh 975049916663 us-east-1 chronon-spark-emr
   ```

   Any tag is allowed for building, but only strict semantic version tags (e.g., `1.2.3`) can be pushed to ECR.

2. **Push the Image (Release Only)**

   The Makefile's `image-push-emr-spark` target enforces semantic versioning and will block pushes for SNAPSHOT or non-semver tags, and will prevent overwriting existing tags in ECR.

   ```bash
   make image-push-emr-spark
   ```

   **Note:** Authenticate to ECR before pushing.

### Defense Mechanisms

Both the Makefile and build scripts include defense mechanisms to prevent accidental overwriting of existing tags in Artifactory and ECR. If you attempt to push a tag that already exists, the push will be blocked and an error will be shown.

For more details on the build and push process, see the comments in the Makefile and scripts.

## SBT Build (Not Recommended)

While the Chronon project also includes support for SBT, it is **not recommended** for use at WEX at this time. The SBT build process has limitations in how it handles Spark versions and produces artifacts with names that can be ambiguous.

For consistency and to ensure you are building against the correct Spark version, please use the Bazel build instructions outlined in this document.
