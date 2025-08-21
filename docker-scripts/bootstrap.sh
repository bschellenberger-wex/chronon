#!/bin/bash
set -euo pipefail

# --- Chronon Bootstrap Script ---
# 1. Pull latest configs
/srv/chronon/pull_chronon_configs.sh

# 2. Pull Chronon driver JAR from S3
/srv/chronon/pull_chronon_driver_jar.sh

# 3. Change to the chronon config directory
if [ -d /srv/chronon/configs/chronon ]; then
    cd /srv/chronon/configs/chronon
else
    echo "Error: Directory /srv/chronon/configs/chronon does not exist. Config download may have failed." >&2
    exit 1
fi

# 4. Run the orchestrator
# Pass all arguments through to the orchestrator
exec python3 chronon_orchestrator.py "$@"
