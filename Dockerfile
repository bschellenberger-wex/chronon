# Start from a Python 3.12 base image and add Java
FROM python:3.12-slim

# TODO Revisit potentially and consider --no-install-recommends
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-jre-headless \
    less \
    vim \
    wget \
    procps \
    tar \
    unzip \
    ca-certificates \
    thrift-compiler \
    && update-ca-certificates \
    # Install AWS CLI v2 (official installer, works for both ARM and x86) \
    && ARCH=$(uname -m) \
    && if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"; \
    else \
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"; \
    fi \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && apt-get remove --purge -y unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*


# Set versions as environment variables for easy updates
ENV SCALA_VERSION="2.12.20"
ENV SPARK_VERSION="3.5.5"
# Note: The spark distribution for 3.5.x is just hadoop3, not a specific version like 3.2
ENV HADOOP_VERSION="3"

# TODO: Dynamically load Chronon configurations from a Git repository.
# Note: run the prepare_docker_build_context.sh script to load the configurations from a Git repository on your system
# Current: Copies configs from the 'aips-chronon-config' directory (expected in the build context) for POC testing.

# Make sure to run prepare_docker_build_context.sh before building the Docker image

# Install Scala
ADD "https://downloads.lightbend.com/scala/${SCALA_VERSION}/scala-${SCALA_VERSION}.deb" /tmp/scala.deb
RUN apt-get update && apt-get install -y --allow-downgrades /tmp/scala.deb && \
    rm /tmp/scala.deb

# Set Scala environment variables
ENV SCALA_HOME="/usr/bin/scala"
ENV PATH=${PATH}:${SCALA_HOME}/bin

# Download and install Spark
ENV SPARK_HOME="/opt/spark"
WORKDIR ${SPARK_HOME}

# Use ADD instead of wget - ADD will only download if the file has changed
ADD "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz" /tmp/spark.tgz
RUN tar xvzf /tmp/spark.tgz --directory /opt/spark --strip-components 1 \
 && rm -rf /tmp/spark.tgz


# Create a non-root user and group for running Chronon
RUN groupadd --gid 1001 chronon \
    && useradd --uid 1001 --gid 1001 --create-home --home-dir /srv/chronon chronon

# Install Python dependencies
COPY --chown=chronon:chronon requirements_wex.txt /srv/chronon/requirements.txt
RUN pip3 install --no-cache-dir -r /srv/chronon/requirements.txt

# Copy configs, then set permissions
COPY --chown=chronon:chronon aips-chronon-config /srv/chronon/configs
RUN mkdir -p /srv/chronon/jars \
    && chown chronon:chronon /srv/chronon/jars \
    && chmod 700 /srv/chronon/jars

# Set user to chronon for all subsequent commands
USER chronon
ENV USER=chronon

# Set Spark environment variables
ENV PATH="/opt/spark/sbin:/opt/spark/bin:${PATH}"
ENV SPARK_HOME="/opt/spark"
ENV PYTHONPATH=$SPARK_HOME/python/:/srv/chronon/configs/:$PYTHONPATH

# Place the Chronon JAR in a directory owned by chronon
ENV DRIVER_JAR_PATH="/srv/chronon/jars/spark_embedded.jar"
COPY --chown=chronon:chronon chronon_jars/chronon_spark_driver.jar "$DRIVER_JAR_PATH"
# The JAR will be downloaded at runtime by a bootstrap script. Ensure chronon user has access.
# Example: The bootstrap script should download the JAR to $DRIVER_JAR_PATH
ENV CHRONON_DRIVER_JAR="${DRIVER_JAR_PATH}"

# Set the working directory to the configs directory
WORKDIR /srv/chronon/configs
