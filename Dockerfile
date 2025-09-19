# Start from a Python 3.12 base image and add Java
FROM python:3.12-slim

# Install system dependencies, including JRE, AWS CLI, and GnuPG for verification
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg \
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
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Set versions as environment variables for easy updates
ENV SCALA_VERSION="2.12.20"

# Copy Scala .deb from build context (downloaded by Makefile)
COPY scala-2.12.20.deb /tmp/scala.deb
RUN apt-get update && apt-get install -y --allow-downgrades /tmp/scala.deb && \
    rm /tmp/scala.deb

# Set Scala environment variables
ENV SCALA_HOME="/usr/bin/scala"
ENV PATH=${PATH}:${SCALA_HOME}/bin


# --- SPARK INSTALLATION ---
# Set Spark home directory and workdir
ENV SPARK_HOME="/opt/spark"
WORKDIR ${SPARK_HOME}

ENV SPARK_VERSION="3.5.5"
# Note: The spark distribution for 3.5.x is just hadoop3, not a specific version like 3.2
ENV HADOOP_VERSION="3"
# Spark download configuration

# Set the Spark filename for reuse
ENV SPARK_FILENAME="spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz"

# Step 1: Copy Spark file from build context (downloaded by Makefile)
COPY ${SPARK_FILENAME} /tmp/${SPARK_FILENAME}

# Step 2: Extract and install Spark
WORKDIR ${SPARK_HOME}

RUN \
    echo "📦 Extracting Spark..." && \
    tar xzf "/tmp/${SPARK_FILENAME}" --directory /opt/spark --strip-components 1 && \
    echo "🧹 Cleaning up temporary files..." && \
    rm -rf /tmp/${SPARK_FILENAME}* && \
    echo "✅ Spark installed successfully"

# Create a non-root user and group for running Chronon
RUN groupadd --gid 1001 chronon \
    && useradd --uid 1001 --gid 1001 --create-home --home-dir /srv/chronon chronon

# Install Python dependencies
COPY --chown=chronon:chronon requirements_wex.txt /srv/chronon/requirements.txt
RUN pip3 install --no-cache-dir -r /srv/chronon/requirements.txt

# Create necessary directories and set permissions
RUN mkdir -p /srv/chronon/jars \
    && chown chronon:chronon /srv/chronon/jars

# Set user to chronon for all subsequent commands
USER chronon
ENV USER=chronon

# Set Spark environment variables
ENV PATH="/opt/spark/sbin:/opt/spark/bin:${PATH}"
ENV SPARK_HOME="/opt/spark"
ENV PYTHONPATH=$SPARK_HOME/python/:/srv/chronon/configs/:$PYTHONPATH

# Set Default CHRONN_DRIVER_JAR environment variable - To be reworked later
ENV CHRONON_DRIVER_JAR="/srv/chronon/jars/spark_embedded.jar"

# Copy all docker scripts and make them executable
COPY --chown=chronon:chronon docker-scripts /srv/chronon
RUN chmod +x /srv/chronon/*.sh

# Set the working directory to the configs directory
WORKDIR /srv/chronon