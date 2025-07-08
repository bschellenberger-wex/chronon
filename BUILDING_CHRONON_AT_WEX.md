# Building Chronon at WEX

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

This section provides instructions for building the Chronon Docker image for local development and testing.

### Building the Docker Image

Building the Docker image requires two main steps: preparing the necessary files using the `prepare_docker_build_context.sh` script and then running the `docker build` command.

1.  **Prepare the Build Context**

    First, you need to run the `prepare_docker_build_context.sh` script. This script copies the Chronon Spark JAR and your local Chronon configurations into the Docker build context. Before running it, make sure you have:

    *   Built the Chronon uber JAR (see [Building with Bazel](#building-with-bazel)).
    *   Set the `CHRONON_SPARK_JAR` environment variable to point to the JAR file.
    *   A local checkout of the `aips-chronon-config` repository.

    Run the script from the root of this repository, passing the path to your local `chronon` configurations directory:

    ```bash
    # Example assuming aips-chronon-config is in a sibling directory
    ./prepare_docker_build_context.sh ../aips-chronon-config
    ```

2.  **Build the Image**

    Once the script completes successfully, you can build the Docker image:

    ```bash
    docker build -t chronon:latest .
    ```

### Using Docker Compose

A `docker-compose.yml` file is included to simplify local development by orchestrating the startup of the main Chronon container and its dependencies, such as Kafka, Zookeeper, and MongoDB.

To start the environment, run:

```bash
docker-compose up -d
```

While `docker-compose` is useful for quick, isolated testing, the local Kubernetes deployment is recommended for a development environment that more closely resembles production. You can also use the Kubernetes deployment from the IaC repository to deploy the image you build, if you prefer.

To sync local configurations to the running docker container, you can use the `copy_config_to_docker.sh` script.

```bash
# Example assuming aips-chronon-config is in a sibling directory
./copy_config_to_docker.sh ../aips-chronon-config
```

### How `prepare_docker_build_context.sh` Works

If you are building and running the Docker file for publishing or development reasons, the `prepare_docker_build_context.sh` script sets up the incoming JAR for the Dockerfile and the initial set of Chronon configurations to build into the Docker image. It performs two main functions:

1.  **Injecting the Spark JAR**: Before running the script, you must build the Chronon uber JAR as described in the [Building with Bazel](#building-with-bazel) section. The script then uses the `CHRONON_SPARK_JAR` environment variable to identify the Chronon Spark JAR that needs to be included in the Docker build.
2.  **Copying Configurations**: It copies your local feature definitions and Chronon configurations into the build context, so they are included in the Docker image.

This script is primarily for local development to streamline testing and iteration. It will be replaced by a more robust solution for production environments.

To use the script, you first need to build the "uber" JAR that contains all the necessary dependencies. The build process will generate a JAR file in the `bazel-bin/spark` directory with the name `spark-assembly_deploy.jar`.

You will then need to set the `CHRONON_SPARK_JAR` environment variable to the path of the generated JAR.

If you intend to use the `prepare_docker_build_context.sh` script, you will need to set the `CHRONON_SPARK_JAR` environment variable to the path of the generated JAR. For example:

```bash
export CHRONON_SPARK_JAR="$(pwd)/bazel-bin/spark/spark-assembly_deploy.jar"
```

To make this setting persistent, you can add the `export` command to your shell's startup file (e.g., `~/.zshrc` or `~/.bashrc`).

For long-term development, you may want to copy the generated JAR to a more permanent location on your local system, as the `bazel-bin` directory can be cleared. If you do so, remember to update the `CHRONON_SPARK_JAR` environment variable to point to the new path. You can reuse this JAR for subsequent Docker builds and only need to rebuild it when you have a new version of the Chronon source code.

### Syncing Configurations to a Live Pod

If you are using the IaC repository with the local Kubernetes deployment, there is a `copy_config_to_pod.sh` script that can be used to sync configurations with the live pod. This is useful for development as it avoids having to rebuild the image every time you change a configuration.

## SBT Build (Not Recommended)

While the Chronon project also includes support for SBT, it is **not recommended** for use at WEX at this time. The SBT build process has limitations in how it handles Spark versions and produces artifacts with names that can be ambiguous.

For consistency and to ensure you are building against the correct Spark version, please use the Bazel build instructions outlined in this document.
