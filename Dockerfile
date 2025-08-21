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
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Set versions as environment variables for easy updates
ENV SCALA_VERSION="2.12.20"


# Install Scala
ADD "https://downloads.lightbend.com/scala/${SCALA_VERSION}/scala-${SCALA_VERSION}.deb" /tmp/scala.deb
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
# Set the cache downloads path for reuse
ENV CACHE_DOWNLOADS_PATH="/cache/downloads"

# Set the Spark filename for reuse
ENV SPARK_FILENAME="spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz"

# Step 1: Acquire Spark using the persistent cache, or download if missing.
RUN --mount=type=cache,target=${CACHE_DOWNLOADS_PATH} \
    if [ -f "${CACHE_DOWNLOADS_PATH}/${SPARK_FILENAME}" ]; then \
        echo "✓ CACHE HIT: Using cached Spark file from previous download." && \
        cp "${CACHE_DOWNLOADS_PATH}/${SPARK_FILENAME}" "/tmp/${SPARK_FILENAME}"; \
    else \
        echo "CACHE MISS: Downloading Spark for the first time..." && \
        curl -L "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_FILENAME}" -o "/tmp/${SPARK_FILENAME}" && \
        echo "💾 Saving Spark file to cache for future builds..." && \
        cp "/tmp/${SPARK_FILENAME}" "${CACHE_DOWNLOADS_PATH}/${SPARK_FILENAME}"; \
    fi

# Step 2: Verify Spark Authenticity (PGP) and Integrity (SHA512)
RUN \
    echo "🔎 Downloading verification files..." && \
    curl -L "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_FILENAME}.sha512" -o "/tmp/${SPARK_FILENAME}.sha512" && \
    curl -L "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_FILENAME}.asc" -o "/tmp/${SPARK_FILENAME}.asc" && \
    curl -L "https://downloads.apache.org/spark/KEYS" -o "/tmp/KEYS" && \
    echo "🔑 Importing PGP keys..." && \
    gpg --import /tmp/KEYS && \
    echo "🔐 Verifying PGP signature (authenticity)..." && \
    gpg --verify "/tmp/${SPARK_FILENAME}.asc" "/tmp/${SPARK_FILENAME}"

WORKDIR /tmp

RUN \
    echo "🧮 Verifying SHA512 checksum (integrity)..." && \
    if sha512sum -c "${SPARK_FILENAME}.sha512"; then \
        echo "✓ SHA512 checksum PASSED"; \
    else \
        echo "✗ Verification FAILED!"; \
        exit 1; \
    fi

WORKDIR ${SPARK_HOME}

# Step 3: Extract Spark and clean up
RUN \
    echo "📦 Extracting Spark..." && \
    tar xzf "/tmp/${SPARK_FILENAME}" --directory /opt/spark --strip-components 1 && \
    echo "🧹 Cleaning up temporary files and keyring..." && \
    rm -rf /tmp/${SPARK_FILENAME}* && \
    rm -f /tmp/KEYS && \
    rm -rf /root/.gnupg

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