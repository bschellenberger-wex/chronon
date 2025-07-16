# Start from a Debian base image with Java 11
FROM openjdk:11-jre-slim

# TODO Revisit potentially and consider --no-install-recommends
RUN apt-get update && apt-get install -y \
    curl \
    python3.9 \
    python3.9-dev \
    python3.9-distutils \
    python3-setuptools \
    vim \
    wget \
    procps \
    python3-pip \
    thrift-compiler \
    tar \
    unzip \
    && update-ca-certificates \
    # Install AWS CLI v2 (official installer, works for both ARM and x86)
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

# Set python3 alternatives to python3.9
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1

# Set versions as environment variables for easy updates
ENV SCALA_VERSION="2.12.20"
ENV SPARK_VERSION="3.5.5"
# Note: The spark distribution for 3.5.x is just hadoop3, not a specific version like 3.2
ENV HADOOP_VERSION="3"

# TODO: Dynamically load Chronon configurations from a Git repository.
# Note: run the prepare_docker_build_context.sh script to load the configurations from a Git repository on your system
# Current: Copies configs from the 'aips-chronon-config' directory (expected in the build context) for POC testing.

# Make sure to run prepare_docker_build_context.sh before building the Docker image
COPY aips-chronon-config /srv/chronon

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


# Install Python dependencies
COPY requirements_wex.txt /srv/chronon/requirements.txt
RUN pip3 install -r /srv/chronon/requirements.txt

# Set user to root - revisit later
ENV USER=root

# Set Spark environment variables
ENV PATH="/opt/spark/sbin:/opt/spark/bin:${PATH}"
ENV SPARK_HOME="/opt/spark"
ENV PYTHONPATH=$SPARK_HOME/python/:/srv/chronon/:$PYTHONPATH

# TODO - We need to pull the JAR form artifactory and for the correct spark cluster version
# For Local development, we copy the JAR from the local 'chronon_jars' directory in the meantime
# Define Chronon JAR path and copy the JAR
# TODO Revisit later, we are leveraging chronon defaults for now and we may need to configure multiple spark versions in the future.
ENV DRIVER_JAR_PATH="/srv/spark/spark_embedded.jar"
COPY chronon_jars/chronon_spark_driver.jar "${DRIVER_JAR_PATH}"
ENV CHRONON_DRIVER_JAR="${DRIVER_JAR_PATH}"

# Set a final working directory for the application
WORKDIR /srv/chronon
