FROM public.ecr.aws/emr-serverless/spark/emr-7.9.0:latest

# Switch to root user for installation
USER root

# === ZERO TRUST FIX (LOCAL BUILDS ONLY) ===
# The following is required only for local Docker builds, to allow yum and pip to trust your organization's Root CA.
# This will be removed once CI/CD is set up to handle trusted builds.
# Do NOT include this in production images unless the image needs to access internal resources at runtime.
# COPY nscacert.pem.crt /etc/pki/ca-trust/source/anchors/
# RUN update-ca-trust

# === INSTALL DEPENDENCIES ===
# Copy requirements file
COPY requirements_emr_spark.txt /opt/requirements.txt

# Install Python dependencies in a single, clean step
# Note: Removed the problematic 'pip3 install --upgrade pip'
RUN yum update -y && \
    yum install -y python3-pip && \
    pip3 install -r /opt/requirements.txt && \
    yum clean all # Clean up yum cache to reduce image size

# EMRS will run the image as hadoop
USER hadoop:hadoop