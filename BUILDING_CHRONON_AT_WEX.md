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
    * [Runtime Bootstrap Process](#runtime-bootstrap-process)
    * [Local Development: Updating a Running Container](#local-development-updating-a-running-container)
    * [Spark Download and Verification in Dockerfile](#spark-download-and-verification-in-dockerfile)
    * [Defense Mechanisms](#defense-mechanisms)
* [Continuous Integration and Deployment (CI/CD)](#continuous-integration-and-deployment-cicd)
    * [GitHub Actions Workflows](#github-actions-workflows)
    * [Local Development: Building and Testing Docker Images](#local-development-building-and-testing-docker-images)
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

Chronon now uses a runtime bootstrap process to fetch configuration and JAR files from S3 when the container starts. This eliminates the need to copy local configs or JARs into the Docker build context. The Docker image includes scripts in the `docker-scripts/` directory to automate this process.

### Prerequisites for Docker Builds

Before building or running Chronon Docker containers, consider which workflow you will use:

- **Building the Docker Image (Local Development):**
  - The Docker build now expects Scala and Spark artifacts to be present in the build context. Use the Makefile targets to download these from Artifactory:
    - `make download-scala`
    - `make download-spark`
  - No S3 credentials or environment variables are required to build the Docker image itself. The image can be built without access to S3 or any runtime configuration.

- **Running the Container with S3 Bootstrap (Optional):**
  - If you want the container to automatically download configs and JARs from S3 at runtime (using the bootstrap process), you must provide AWS credentials and set the following environment variables:
    - `S3_BUCKET_NAME`: Name of the S3 bucket containing Chronon configs and JARs.
    - `S3_CONFIG_PATH`: Path within the bucket to the Chronon config zips.
    - `S3_CHRONON_DRIVER_JAR_PATH`: Path within the bucket to the Chronon driver JAR.
    - `S3_CHRONON_DRIVER_JAR_FILENAME`: Name of the JAR file to download.
    - (Optional) `CHRONON_CONFIG_ZIP_OVERRIDE`: Override the config zip file name if you don't want to use latest configs.
    - (Optional) `DRIVER_JAR_PATH`: Override the default location where the downloaded JAR is stored (default is `/srv/chronon/jars/spark_embedded.jar`).
  - These are only required if you want to use the automated S3 bootstrap process at container startup.

- **Local Development / Manual Config & JAR Injection:**
  - If you prefer to manually inject configs and JARs (e.g., for local development or testing), you can use the `update_chronon_container.sh` script. In this case, S3 credentials and environment variables are not required.

- **Authenticate to Registries Before Pushing:**
  - For Artifactory: `docker login usartifactorywexinc.jfrog.io -u {wexid}`
    - Use your Artifactory API Key as the password.
  - For ECR: `aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 975049916663.dkr.ecr.us-east-1.amazonaws.com`

### Building the Main Chronon Docker Image

1. **Download Required Artifacts (Local Development Only)**

   Before building, download Scala and Spark artifacts from Artifactory:

   ```bash
   make download-scala
   make download-spark
   ```

2. **Build the Image (Local Development Only)**

   The Docker build no longer requires local config or JAR injection. The image will fetch these at runtime. Simply run:

   ```bash
   make image-package
   ```

   The Makefile will build the Docker image using the tag from the `VERSION` file.

3. **Push the Image (Release Only, via CI/CD)**

   Only strict semantic version tags (e.g., `1.2.3`) can be pushed. The Makefile will block pushes for SNAPSHOT or non-semver tags, and will also prevent overwriting existing tags in Artifactory.

   > **Note:** Image pushes are now handled by GitHub Actions workflows. Local pushes are for development only.

### Building the EMR Spark Docker Image

1. **Download Required Artifacts (Local Development Only)**

   ```bash
   make download-scala
   make download-spark
   ```

2. **Build the Image (Local Development Only)**

   The EMR Spark image can be built using the Makefile target:

   ```bash
   make build-emr-spark
   ```

   The tag is specified in the `VERSION.emr-spark` file.

3. **Push the Image (Release Only, via CI/CD)**

   > **Note:** Image pushes are now handled by GitHub Actions workflows. Local pushes are for development only.

### Runtime Bootstrap Process

The container does not automatically run the bootstrap process by default. In production (e.g., Kubernetes), your deployment should be configured to invoke the `docker-scripts/bootstrap.sh` script as the container entrypoint or command. This script will:

- Call `pull_chronon_configs.sh` to download the latest Chronon config zip from S3 and unzip it to `/srv/chronon/configs`.
- Call `pull_chronon_driver_jar.sh` to download the Chronon driver JAR from S3 to `/srv/chronon/jars/spark_embedded.jar` (or as specified).
- Launch the orchestrator.

If you shell into a running container, you can also manually invoke the bootstrap process by running:

```bash
/srv/chronon/bootstrap.sh
```

All required environment variables must be set for these scripts to function.

### Local Development: Updating a Running Container

For local development, you can use the `update_chronon_container.sh` script to manually inject a JAR or configuration files into a running Chronon Docker container, bypassing the S3 bootstrap process. This is useful for rapid iteration and testing.

```bash
./update_chronon_container.sh [path_to_jar] [path_to_configs] [container_name_or_id]
```

- All arguments are optional. If not specified, the script will attempt to find a running container named `main` or `chronon`.
- You can provide a path to a JAR, a configs directory or zip, and a container name or ID.

### Spark Download and Verification in Dockerfile

The Dockerfile now expects Scala and Spark artifacts to be present in the build context, downloaded via the Makefile. Verification steps (PGP/SHA) are no longer performed in the Dockerfile. See the Makefile for details on artifact download.

### Defense Mechanisms

Both the Makefile and build scripts include defense mechanisms to prevent accidental overwriting of existing tags in Artifactory and ECR. If you attempt to push a tag that already exists, the push will be blocked and an error will be shown.

For more details on the build and push process, see the comments in the Makefile and scripts.

## Continuous Integration and Deployment (CI/CD)

Chronon now uses GitHub Actions workflows to build and publish Docker images for both the main orchestrator and EMR Spark components. This ensures consistent, secure, and automated deployment to Artifactory and AWS ECR across all environments.

### GitHub Actions Workflows

- **Main Chronon Orchestrator Image:**
  - Workflow: `.github/workflows/publish-chronon-orchestrator.yml`
  - Builds the Docker image using the Makefile and publishes to Artifactory.
  - Supports promotion to production via workflow dispatch input.
  - Uses semantic version tags from the `VERSION` file.

- **EMR Spark Image:**
  - Workflow: `.github/workflows/publish-spark-emr.yml`
  - Builds the EMR Spark Docker image and publishes to AWS ECR.
  - Uses a matrix strategy to publish to multiple AWS accounts and regions (dev, stage, prod; us-east-1, us-west-2).
  - Uses semantic version tags from the `VERSION.emr-spark` file.

- **Versioning:**
  - Only strict semantic version tags (e.g., `0.0.1`) are allowed for pushes. SNAPSHOT tags are blocked.
  - The workflows prevent overwriting existing tags in Artifactory and ECR.

### Local Development: Building and Testing Docker Images

- Local builds are supported for development and testing only. Use the Makefile targets to download required artifacts and build images.
- Pushing images to registries should be done via CI/CD workflows. Local pushes are blocked for non-semver tags and if the tag already exists.
- For EMR Spark, use:
  ```bash
  make build-emr-spark
  ```
- For the main orchestrator, use:
  ```bash
  make image-package
  ```

## SBT Build (Not Recommended)

While the Chronon project also includes support for SBT, it is **not recommended** for use at WEX at this time. The SBT build process has limitations in how it handles Spark versions and produces artifacts with names that can be ambiguous.

For consistency and to ensure you are building against the correct Spark version, please use the Bazel build instructions outlined in this document.
