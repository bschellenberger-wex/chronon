#!/bin/bash

# ---
# A helper script for local development to quickly update a running Chronon Docker container.
#
# This script is an alternative to the standard bootstrap process that downloads resources from S3.
# It allows you to manually inject a JAR or configuration files directly from your local filesystem,
# which is useful for testing and development without needing to upload new assets to S3.
#
# Usage: ./update_chronon_container.sh [path_to_jar] [path_to_configs] [container_name_or_id]
# All arguments are optional.
#
# Examples:
#   ./update_chronon_container.sh                           # Find container automatically
#   ./update_chronon_container.sh my.jar                   # Update only JAR
#   ./update_chronon_container.sh "" ./configs             # Update only configs
#   ./update_chronon_container.sh my.jar ./configs main    # Specify all parameters
# ---

# --- Configuration ---
set -euxo pipefail

# --- Destination paths inside the container ---
readonly CHRONON_BASE_PATH="/srv/chronon"
readonly JAR_DEST_PATH="${CHRONON_BASE_PATH}/jars/spark_embedded.jar"
readonly CONFIGS_DEST_PATH="${CHRONON_BASE_PATH}/configs"
readonly TMP_ZIP_PATH="/tmp/configs.zip"

# --- Color and Logging Setup ---
# Check if the terminal supports colors.
if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
  readonly C_INFO='\e[34m'
  readonly C_SUCCESS='\e[32m'
  readonly C_ERROR='\e[31m'
  readonly C_RESET='\e[0m'
else
  readonly C_INFO=''
  readonly C_SUCCESS=''
  readonly C_ERROR=''
  readonly C_RESET=''
fi

# Use printf for more reliable output across different shells.
log_info() {
    printf "${C_INFO}[INFO]${C_RESET} %s\n" "$1"
}

log_success() {
    printf "${C_SUCCESS}[SUCCESS]${C_RESET} %s\n" "$1"
}

log_error() {
    # Print to standard error (stderr)
    printf "${C_ERROR}[ERROR]${C_RESET} %s\n" "$1" >&2
    exit 1
}

show_usage() {
    cat << EOF
Usage: $0 [path_to_jar] [path_to_configs] [container_name_or_id]

This script updates a running Chronon Docker container with local JAR and/or config files.
All arguments are optional.

Arguments:
  path_to_jar         Path to the JAR file to copy (optional)
  path_to_configs     Path to configs directory or zip file (optional)
  container_name_or_id Container name or ID to use (optional, auto-detected if not provided)

Examples:
  $0                           # Find container automatically
  $0 my.jar                   # Update only JAR
  $0 "" ./configs             # Update only configs
  $0 my.jar ./configs main    # Specify all parameters

The script will automatically find a running container named 'main' or 'chronon' if no container is specified.
EOF
}

# --- Core Functions ---

##
# Validates input parameters before processing
##
validate_inputs() {
    local jar_src="$1"
    local configs_src="$2"
    
    if [[ -n "$jar_src" ]]; then
        if [[ ! -f "$jar_src" ]]; then
            log_error "JAR file does not exist: $jar_src"
        fi
        log_info "JAR file validated: $jar_src"
    fi
    
    if [[ -n "$configs_src" ]]; then
        if [[ ! -e "$configs_src" ]]; then
            log_error "Configs path does not exist: $configs_src"
        fi
        if [[ -f "$configs_src" && "$configs_src" != *.zip ]]; then
            log_error "Config file must be a directory or a .zip file: $configs_src"
        fi
        log_info "Configs path validated: $configs_src"
    fi
}

##
# Validates that the container exists and is running
##
validate_container() {
    local container_id="$1"
    
    if ! docker ps -q --filter id="$container_id" | grep -q .; then
        log_error "Container not found or not running: $container_id"
    fi
    
    log_info "Container validated: $container_id"
}

##
# Finds a running Docker container ID.
##
find_chronon_container() {
    local names_to_try=("main" "chronon")
    for name in "${names_to_try[@]}"; do
        local container_id
        container_id=$(docker ps --filter "name=${name}" -q | head -n 1)
        if [[ -n "$container_id" ]]; then
            echo "$container_id"
            return
        fi
    done
}

##
# Copies the JAR file into the specified container.
##
update_jar() {
    local jar_src="$1"
    local container_id="$2"
    
    log_info "Creating JAR directory in container..."
    if ! docker exec --user root "$container_id" mkdir -p "$(dirname "$JAR_DEST_PATH")"; then
        log_error "Failed to create JAR directory in container"
    fi
    
    log_info "Copying JAR to ${container_id}:${JAR_DEST_PATH}"
    if ! docker cp "$jar_src" "${container_id}:${JAR_DEST_PATH}"; then
        log_error "Failed to copy JAR file to container"
    fi
    
    # Verify the JAR was copied successfully
    if ! docker exec "$container_id" test -f "$JAR_DEST_PATH"; then
        log_error "JAR file verification failed - file not found in container"
    fi
    
    log_info "JAR file copied and verified successfully"
}

##
# Copies the configuration files into the specified container.
##
update_configs() {
    local configs_src="$1"
    local container_id="$2"
    
    log_info "Recreating configs directory in container..."
    if ! docker exec --user root "$container_id" sh -c "rm -rf '${CONFIGS_DEST_PATH}' && mkdir -p '${CONFIGS_DEST_PATH}'"; then
        log_error "Failed to recreate configs directory in container"
    fi
    
    if [[ "$configs_src" == *.zip ]]; then
        log_info "Copying and extracting zip file to ${container_id}:${CONFIGS_DEST_PATH}"
        if ! docker cp "$configs_src" "${container_id}:${TMP_ZIP_PATH}"; then
            log_error "Failed to copy zip file to container"
        fi
        if ! docker exec "$container_id" sh -c "unzip -o '${TMP_ZIP_PATH}' -d '${CONFIGS_DEST_PATH}' && rm '${TMP_ZIP_PATH}'"; then
            log_error "Failed to extract zip file in container"
        fi
    else
        log_info "Copying configs directory to ${container_id}:${CONFIGS_DEST_PATH}"
        if ! docker cp "${configs_src}/." "${container_id}:${CONFIGS_DEST_PATH}/"; then
            log_error "Failed to copy configs directory to container"
        fi
    fi
    
    # Verify the configs directory exists and has content
    if ! docker exec "$container_id" test -d "$CONFIGS_DEST_PATH"; then
        log_error "Configs directory verification failed - directory not found in container"
    fi
    
    local file_count
    file_count=$(docker exec "$container_id" find "$CONFIGS_DEST_PATH" -type f | wc -l)
    if [[ "$file_count" -eq 0 ]]; then
        log_error "Configs directory verification failed - no files found in configs directory"
    fi
    
    log_info "Configs copied and verified successfully (${file_count} files)"
}


# --- Main Execution ---
main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi

    local jar_src="${1:-}"
    local configs_src="${2:-}"
    local container_arg="${3:-}"
    local container_id

    # Show what we're about to do
    log_info "=== Chronon Container Update Script ==="
    log_info "JAR source: ${jar_src:-"(not specified)"}"
    log_info "Configs source: ${configs_src:-"(not specified)"}"
    log_info "Container: ${container_arg:-"(auto-detect)"}"
    printf "\n"

    # Validate inputs early
    validate_inputs "$jar_src" "$configs_src"

    # Determine container ID
    if [[ -n "$container_arg" ]]; then
        container_id="$container_arg"
        log_info "Using specified container: ${container_id}"
    else
        log_info "No container specified, searching for a running 'main' or 'chronon' container..."
        container_id=$(find_chronon_container)
        if [[ -z "$container_id" ]]; then
            log_error "No running 'main' or 'chronon' container found. Please specify one."
        fi
        log_info "Found container: ${container_id}"
    fi

    # Validate container exists and is running
    validate_container "$container_id"

    # Update JAR if provided
    if [[ -n "$jar_src" ]]; then
        update_jar "$jar_src" "$container_id"
        log_success "JAR file updated."
    else
        log_info "No JAR path provided, skipping JAR update."
    fi

    # Update configs if provided
    if [[ -n "$configs_src" ]]; then
        update_configs "$configs_src" "$container_id"
        log_success "Configs updated."
    else
        log_info "No configs path provided, skipping config update."
    fi

    # Set proper ownership for all files
    log_info "Setting ownership for all files in ${CHRONON_BASE_PATH} to chronon..."
    if ! docker exec --user root "$container_id" chown -R chronon:chronon "${CHRONON_BASE_PATH}"; then
        log_error "Failed to set ownership for files in container"
    fi
    log_success "Ownership updated successfully."

    printf "\n"
    log_success "Script finished successfully."
}

# Pass all command-line arguments to the main function.
main "$@"