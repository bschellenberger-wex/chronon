# Building Chronon at WEX

* [Prerequisites](#prerequisites)
* [Java Setup with SDKMAN](#java-setup-with-sdkman)
* [VPN and Java Keystore](#vpn-and-java-keystore)
* [Building with SBT](#building-with-sbt)
    * [Building All JARs](#building-all-jars)
    * [Building Specific JARs](#building-specific-jars)
    * [Building with or without Tests](#building-with-or-without-tests)
* [Artifact Preparation and Publishing](#artifact-preparation-and-publishing)
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

This document outlines the process for building Chronon artifacts at WEX. The project uses **SBT** as the build system and requires **Java 1.8** for compilation. Due to specific version requirements for Spark, it's necessary to build Chronon from source to ensure compatibility.

> **Note**: This project migrated from Bazel to SBT. For migration context, see [MIGRATION_TO_SBT.md](MIGRATION_TO_SBT.md).

## Prerequisites

- **Install SDKMAN**: SDKMAN is required for managing Java versions. Install it following the [official instructions](https://sdkman.io/install):
  ```bash
  curl -s "https://get.sdkman.io" | bash
  source "$HOME/.sdkman/bin/sdkman-init.sh"
  ```

- **Install Thrift v0.13**: Thrift v0.13 is required for both Linux and macOS builds. For macOS, it is recommended to use Homebrew as the build scripts have been adjusted for it. Please see `devnotes.md` for specific commands.

- **Python**: Python is installed (required for Python API builds).

## Java Setup with SDKMAN

This project requires **Java 1.8** for building. SDKMAN is used to ensure consistent Java version management across all developers.

### Initial Setup

1. **Install the required Java version**:
   ```bash
   sdk env install
   ```
   This reads `.sdkmanrc` and installs the specified Java version (8.482.08.1-amzn).

2. **Activate the Java version**:
   ```bash
   sdk env
   ```
   This sets `JAVA_HOME` to the correct Java installation.

3. **Verify the setup**:
   ```bash
   java -version
   # Should show: openjdk version "1.8.0_482" (or similar)
   
   echo $JAVA_HOME
   # Should point to the SDKMAN Java installation
   ```

### Pro-Tip: Automatic Java Version Switching

SDKMAN can automatically switch Java versions when you enter the project directory. Enable this feature by adding to your `~/.sdkman/etc/config`:

```bash
sdkman_auto_env=true
```

With this enabled, SDKMAN will automatically run `sdk env` when you `cd` into the project directory, ensuring you're always using the correct Java version specified in `.sdkmanrc`.

**Note**: This requires SDKMAN to be initialized in your shell (add to `~/.zshrc` or `~/.bashrc`):
```bash
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
```

### Verifying Java Setup

The Makefile includes a pre-flight check to verify your Java environment:

```bash
make check-java
```

This will:
- Verify `JAVA_HOME` is set
- Check that the Java version matches what's specified in `.sdkmanrc`
- Provide helpful error messages if something is wrong

## VPN and Java Keystore (Optional - Only if Needed)

> **Note**: This section is only required if you encounter SSL/TLS certificate errors during builds. If your builds work without this setup, you can skip this section.

If you are behind a VPN or using Zero Trust networking, you may need to add the root CA certificates to the Java keystore (cacerts) of your JDK. This is required for Java applications to trust SSL/TLS connections through corporate proxies or VPN infrastructure.

**When is this needed?**
- You're behind a corporate VPN that intercepts SSL/TLS connections
- You're using corporate/private Maven repositories (e.g., Artifactory) that require corporate CA certificates
- You see SSL/TLS errors during SBT builds: `javax.net.ssl.SSLHandshakeException: PKIX path building failed`
- Your build fails when downloading dependencies with certificate validation errors

**When is this NOT needed?**
- You're using public Maven repositories (Maven Central) without VPN
- Your builds complete successfully without certificate errors
- You're not behind a corporate proxy or Zero Trust network

If you're unsure, try building first. Only set up certificates if you encounter SSL/TLS errors.

### Setting Up Zero Trust CA Certificates

Use the provided Makefile target to import CA certificates into your JVM. The target uses `JAVA_HOME` from SDKMAN, so you only need to provide the PEM bundle path.

```bash
# 1. Extract macOS system certificates to a PEM bundle
mkdir -p ~/certs
(security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain && \
 security find-certificate -a -p /Library/Keychains/System.keychain) > ~/certs/bundle.pem

# 2. Ensure SDKMAN Java is active
sdk env

# 3. Test with dry-run to preview what will be imported
make setup-jvm-cas \
  PEM_BUNDLE="$HOME/certs/bundle.pem" \
  DRY_RUN=1

# 4. Import certificates into the JVM keystore
make setup-jvm-cas \
  PEM_BUNDLE="$HOME/certs/bundle.pem"

# 5. Verify import
keytool -list -keystore "$JAVA_HOME/jre/lib/security/cacerts" \
  -storepass changeit | grep corp-
```

**Key Points:**
- **Only PEM_BUNDLE is required** - The Makefile uses `JAVA_HOME` from SDKMAN automatically
- The script automatically backs up your cacerts file before making changes
- Certificates are imported with the `corp-` alias prefix for easy identification
- Re-running the command is safe - duplicate certificates are automatically skipped
- With SDKMAN-managed JDKs, sudo is typically not required (JDKs are user-writable)
- Optional flags: Add `VERBOSE=1` for detailed output or `DRY_RUN=1` to preview changes

**Troubleshooting**: 
- **Try building first** - Run `make build SKIP_TESTS=true` before setting up certificates.
- **Only configure certificates if you see SSL/TLS errors** - If your build fails with `javax.net.ssl.SSLHandshakeException` or `PKIX path building failed`, then follow the certificate setup steps above.
- **Common scenario**: If you're using public repositories (Maven Central) and not behind a corporate VPN, you likely don't need this setup.

For more detailed information, see [docs/zero-trust-ca-setup.md](docs/zero-trust-ca-setup.md).

## Building with SBT

The project uses **SBT** (Simple Build Tool) for building all JAR artifacts. The build system is configured to:
- Use **Spark 3.5.5** (`use_spark_3_5 := true`)
- Use **Scala 2.12** as the default
- Compile with **Java 1.8** bytecode (enforced via SDKMAN)

> **Note**: If you encounter SSL/TLS certificate errors during builds (especially when downloading dependencies), see the [VPN and Java Keystore](#vpn-and-java-keystore-optional---only-if-needed) section above. Most developers using public repositories don't need certificate setup.

### Building All JARs

To build all JAR targets (spark-assembly and aws-online):

```bash
# Build all JARs with tests
make build

# Build all JARs without tests (faster)
make build SKIP_TESTS=true
```

This will build:
- `spark_uber` project → `spark-assembly` JAR
- `aws_online` project → `aws-online` JARs (slim, EMR, and shaded variants)

Built JARs are placed in `build/jars/` (or `$CHRONON_BUILD_DIR/jars/` if set).

### Building Specific JARs

To build only specific JARs:

```bash
# Build only spark-assembly JAR
make build-spark-assembly

# Build only spark-assembly without tests
make build-spark-assembly SKIP_TESTS=true

# Build only aws-online JARs
make build-aws-online

# Build only aws-online without tests
make build-aws-online SKIP_TESTS=true
```

### Building with or without Tests

Tests can be very slow, so you may want to skip them during development:

```bash
# With tests (default)
make build

# Without tests (faster)
make build SKIP_TESTS=true

# Specific JAR without tests
make build-spark-assembly SKIP_TESTS=true
```

**Note**: The `spark_uber` project tests are skipped by default in the build script (they're run in CI/CD in the OSS repo). The `aws_online` project tests run by default unless `SKIP_TESTS=true` is set.

### Build Output Locations

- **Default location**: `build/jars/`
- **Custom location**: Set `CHRONON_BUILD_DIR` environment variable
- **JAR naming**:
  - Spark: `spark_uber-assembly-<version>.jar`
  - AWS Online: `aws-online_2.12-<version>.jar`, `aws-online-emr-assembly-<version>.jar`, `aws-online-shaded-assembly-<version>.jar`

## Artifact Preparation and Publishing

After building JARs, you can prepare them for Maven publishing:

```bash
# Prepare all artifacts for publishing
make prepare-artifacts

# Force rebuild before preparing
make prepare-artifacts FORCE_REBUILD=true
```

This will:
- Build JARs if they don't exist (or if `FORCE_REBUILD=true`)
- Create Maven artifacts (JAR, POM, SHA256) in `chronon-artifacts/`
- Generate an artifact manifest (`ARTIFACT_MANIFEST.ini`)

### Listing Available JAR Targets

To see what JAR targets are available:

```bash
make list-jars
```

### Uploading Artifacts to S3

To upload the Spark JAR to S3:

```bash
make deploy-spark-jar-s3 S3_BUCKET=your-bucket-name
```

To upload the AWS Online EMR JAR:

```bash
make deploy-aws-online-jar-s3 S3_BUCKET=your-bucket-name
```

To upload all JARs:

```bash
make deploy-all-jars-s3 S3_BUCKET=your-bucket-name
```

**Make sure you are logged into the appropriate AWS environment** (e.g., using `aws sso login` or setting the correct AWS profile) before running the upload commands.

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

- **Build and Publish JARs:**
  - Workflow: `.github/workflows/build.yml`
  - Builds all JARs using SBT via `make build`
  - Prepares artifacts and publishes to Artifactory
  - Uses semantic version tags

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
