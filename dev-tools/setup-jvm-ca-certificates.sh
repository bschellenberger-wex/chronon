#!/usr/bin/env zsh
#
# setup-jvm-ca-certificates.sh
#
# Purpose: Import Zero Trust CA certs (and macOS system CAs) into a target JVM cacerts keystore on macOS.
# Supports Java 8 (Corretto) paths and generic $JAVA_HOME.
#
# This script:
# - Extracts individual certificates from a PEM bundle
# - Imports each cert into the JVM keystore with a unique, stable alias (based on SHA-256 fingerprint)
# - Backs up cacerts before modification
# - Skips already-imported certs on re-runs
# - Validates certificate format and detects cert count
#
# Usage:
#   ./setup-jvm-ca-certificates.sh \
#     --pem <path-to-pem-bundle> \
#     [--jvm <jvm-home>] \
#     [--storepass <password>] \
#     [--alias-prefix <prefix>] \
#     [--dry-run] \
#     [--verbose]
#
# Example (with macOS system certs):
#   (security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain && \
#    security find-certificate -a -p /Library/Keychains/System.keychain) > ~/Documents/certs/allCAbundle.pem
#
#   ./setup-jvm-ca-certificates.sh \
#     --pem ~/Documents/certs/allCAbundle.pem \
#     --jvm "/Users/$USER/Library/Java/JavaVirtualMachines/corretto-1.8.0_462/Contents/Home" \
#     --alias-prefix corp
#
# Prerequisites:
# - keytool (bundled with Java installation)
# - openssl
# - security command (macOS)
# - read/write permissions to cacerts
#
set -euo pipefail

# Verbose logging helper
vlog() {
  if [[ $VERBOSE -eq 1 ]]; then
    echo "[VERBOSE] $*" >&2
  fi
}

print_usage() {
  cat <<'EOF'
Import CA certificates into a JVM keystore (cacerts) on macOS.

USAGE:
  setup-jvm-ca-certificates.sh --pem <path> [OPTIONS]

REQUIRED:
  --pem <path>              Path to a PEM bundle file (one or more certificates).

OPTIONS:
  --jvm <path>              Path to JVM home directory. Defaults to $JAVA_HOME.
                            Example: /path/to/corretto-1.8.0_462/Contents/Home

  --storepass <password>    Keystore password. Default: changeit

  --alias-prefix <str>      Prefix for certificate aliases. Default: imported
                            Each cert gets: <prefix>-<index>-<sha256-fingerprint>

  --dry-run                 Preview actions without modifying cacerts.

  --verbose                 Enable verbose output (show each cert's details).

  --help, -h                Show this help message.

BEHAVIOR:
  - Splits the PEM bundle into individual certificates
  - Backs up cacerts with a timestamp before any modifications
  - Imports each certificate with a unique alias (fingerprint-based for stability)
  - Skips already-imported certificates on re-runs
  - Validates certificate format and reports counts
  - Creates and manages temp files automatically

EXAMPLE (macOS System & Zero Trust CAs):
  # 1. Extract macOS system certificates
  (security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain && \
   security find-certificate -a -p /Library/Keychains/System.keychain) > ~/certs/bundle.pem

  # 2. Preview import (dry-run)
  ./setup-jvm-ca-certificates.sh --pem ~/certs/bundle.pem \
    --jvm /path/to/java/home --alias-prefix corp --dry-run

  # 3. Perform actual import
  ./setup-jvm-ca-certificates.sh --pem ~/certs/bundle.pem \
    --jvm /path/to/java/home --alias-prefix corp

  # 4. Verify import
  keytool -list -keystore /path/to/java/home/jre/lib/security/cacerts \
    -storepass changeit | grep corp-

TROUBLESHOOTING:
  - "Could not find cacerts": Check JVM path. Java 8 uses jre/lib/security/, newer uses lib/security/
  - "Permission denied": Ensure write access to cacerts and its directory
  - "SSLHandshakeException after import": Reload Java process or IDE to pick up new certs
  - Check backup at: cacerts.YYYYMMDD_HHMMSS.bak in the same directory as cacerts

EOF
}

PEM_BUNDLE=""
JVM_HOME=${JAVA_HOME:-""}
STOREPASS="changeit"
ALIAS_PREFIX="imported"
DRY_RUN=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pem)
      PEM_BUNDLE="$2"; shift 2;;
    --jvm)
      JVM_HOME="$2"; shift 2;;
    --storepass)
      STOREPASS="$2"; shift 2;;
    --alias-prefix)
      ALIAS_PREFIX="$2"; shift 2;;
    --dry-run)
      DRY_RUN=1; shift;;
    --verbose)
      VERBOSE=1; shift;;
    --help|-h)
      print_usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; print_usage; exit 1;;
  esac
done

if [[ -z "$PEM_BUNDLE" ]]; then
  echo "--pem is required (path to PEM bundle)" >&2
  exit 1
fi

if [[ ! -f "$PEM_BUNDLE" ]]; then
  echo "PEM bundle not found: $PEM_BUNDLE" >&2
  exit 1
fi

if [[ -z "$JVM_HOME" ]]; then
  echo "--jvm not specified and JAVA_HOME not set. Please provide JVM home path." >&2
  exit 1
fi

# Detect cacerts path (Java 8 vs later)
CACERTS=""
if [[ -f "$JVM_HOME/jre/lib/security/cacerts" ]]; then
  CACERTS="$JVM_HOME/jre/lib/security/cacerts"
elif [[ -f "$JVM_HOME/lib/security/cacerts" ]]; then
  CACERTS="$JVM_HOME/lib/security/cacerts"
else
  echo "Could not find cacerts under $JVM_HOME. Checked jre/lib/security and lib/security." >&2
  exit 1
fi

echo "Using JVM home: $JVM_HOME"
echo "Using cacerts: $CACERTS"
echo "Using storepass: (hidden)"

# Create temp working dir
WORKDIR=$(mktemp -d -t import-ca-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# Split PEM bundle into individual cert files
CERT_DIR="$WORKDIR/certs"
mkdir -p "$CERT_DIR"

# Portable split using awk (compatible with macOS/BSD awk)
awk -v outdir="$CERT_DIR" '
  /-----BEGIN CERTIFICATE-----/ { n++; }
  {
    if (n > 0) {
      printf "%s\n", $0 >> sprintf("%s/cert_%03d.pem", outdir, n);
    }
  }
' "$PEM_BUNDLE"

# Collect cert files robustly
CERT_FILES=()
while IFS= read -r -d '' f; do
  CERT_FILES+=("$f")
done < <(find "$CERT_DIR" -type f -name 'cert_*.pem' -print0)

vlog "Found ${#CERT_FILES[@]} cert file(s) after awk split"

# Filter empty or invalid files
VALID_CERTS=()
for f in "${CERT_FILES[@]}"; do
  if [[ -s "$f" ]] && grep -q -- "-----BEGIN CERTIFICATE-----" "$f"; then
    VALID_CERTS+=("$f")
  else
    vlog "Skipping invalid/empty cert: $f"
    rm -f "$f"
  fi
done

COUNT=${#VALID_CERTS[@]}
if [[ "$COUNT" -eq 0 ]]; then
  echo "No certificates found in bundle after splitting: $PEM_BUNDLE" >&2
  exit 1
fi

echo "Found $COUNT cert(s) to import."
vlog "Valid certs: ${VALID_CERTS[*]}"

# Backup cacerts
BACKUP="$CACERTS.$(date +%Y%m%d_%H%M%S).bak"
if [[ $DRY_RUN -eq 0 ]]; then
  cp "$CACERTS" "$BACKUP"
fi
echo "Backup created: $BACKUP"

# Iterate and import certs
INDEX=1
IMPORTED=0
SKIPPED=0

for CERT in "${VALID_CERTS[@]}"; do
  SUBJECT=$(openssl x509 -noout -subject -in "$CERT" 2>/dev/null || echo "unknown")
  FPR=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT" | cut -d'=' -f2 | tr -d ':')
  ALIAS="${ALIAS_PREFIX}-${INDEX}-${FPR}"

  echo "Processing cert #$INDEX/$COUNT"
  vlog "  Subject: $SUBJECT"
  vlog "  Fingerprint: $FPR"
  vlog "  Alias: $ALIAS"

  if keytool -list -keystore "$CACERTS" -storepass "$STOREPASS" -alias "$ALIAS" >/dev/null 2>&1; then
    vlog "  Already present in keystore (skipping)"
    SKIPPED=$((SKIPPED+1))
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY-RUN] Would import as: $ALIAS"
      IMPORTED=$((IMPORTED+1))
    else
      if keytool -importcert -noprompt -trustcacerts \
        -file "$CERT" \
        -alias "$ALIAS" \
        -storepass "$STOREPASS" \
        -keystore "$CACERTS" 2>/dev/null; then
        echo "  ✓ Imported"
        IMPORTED=$((IMPORTED+1))
      else
        echo "  ✗ Failed to import" >&2
      fi
    fi
  fi
  INDEX=$((INDEX+1))
done

echo ""
echo "Summary:"
echo "  Total certs: $COUNT"
echo "  Imported/DRY-RUN: $IMPORTED"
echo "  Skipped (already present): $SKIPPED"
if [[ $DRY_RUN -eq 0 ]]; then
  echo "  Backup: $BACKUP"
fi
