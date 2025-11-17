#!/usr/bin/env bash

# ==============================================================================
# Generate SSL Certificates
# ==============================================================================
# Generates self-signed SSL certificates for all VMs defined in
# .machines.conf.csv. Each certificate includes the VM's FQDN as both CN and
# SAN (Subject Alternative Name) for modern browser compatibility.
#
# Inputs:
#   - .env: Environment configuration file
#   - .machines.conf.csv: VM definitions
# Outputs:
#   - {ANSIBLE_VM_CERTS_PATH}/{fqdn}.crt: Certificate file for each VM
#   - {ANSIBLE_VM_CERTS_PATH}/{fqdn}.key: Private key file for each VM
#   - logs/generate-certs.log: OpenSSL execution log
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MACHINES_FILE="$PROJECT_ROOT/.machines.conf.csv"
LOGS_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOGS_DIR/generate-certs.log"

# --- GLOBAL VARIABLES ---
SUCCESS_COUNT=0
MACHINE_COUNT=0

# --- VALIDATE ENVIRONMENT FILE ---
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# --- LOAD ENVIRONMENT VARIABLES ---
set -a
source "$ENV_FILE"
set +a

# --- VALIDATE REQUIRED VARIABLES ---
if [ -z "${AZURE_VMS_LOCATION:-}" ] || [ -z "${ANSIBLE_VM_CERTS_PATH:-}" ]; then
    echo "❌ Error: AZURE_VMS_LOCATION or ANSIBLE_VM_CERTS_PATH not set in .env" >&2
    exit 1
fi

CERTS_DIR="$ANSIBLE_VM_CERTS_PATH"

# --- VALIDATE MACHINES FILE ---
if [ ! -f "$MACHINES_FILE" ]; then
    echo "❌ Error: Machines configuration file not found at $MACHINES_FILE" >&2
    exit 1
fi

# --- SETUP LOGGING ---
mkdir -p "$LOGS_DIR"
mkdir -p "$CERTS_DIR"
: > "$LOG_FILE"

echo "📁 Certificates directory: $CERTS_DIR" >&2
echo "⏳ Generating SSL certificates..." >&2

# --- GENERATE CERTIFICATES ---
{
    read -r header || true  # Skip header

    while IFS=',' read -r prefix slesVersion spVersion suffix || [ -n "$prefix" ]; do
        # Normalize and clean CSV data
        prefix=$(echo "$prefix" | tr -d '\r' | xargs)
        slesVersion=$(echo "$slesVersion" | tr -d '\r' | xargs)
        spVersion=$(echo "$spVersion" | tr -d '\r' | xargs)
        suffix=$(echo "$suffix" | tr -d '\r' | xargs)

        # Skip empty lines
        if [ -z "$prefix" ]; then
            continue
        fi

        # Skip SLES 16+ (manual installation, no Ansible)
        if [ "$slesVersion" -ge 16 ]; then
            echo "  ⏭️  Skipping ${prefix}${slesVersion}sp${spVersion}${suffix} (SLES $slesVersion - manual installation)" >&2
            continue
        fi

        # Skip helm suffix (manual installation, no Ansible)
        if [[ "$suffix" == "helm" ]]; then
            echo "  ⏭️  Skipping ${prefix}${slesVersion}sp${spVersion}${suffix} (Helm - manual installation)" >&2
            continue
        fi

        MACHINE_COUNT=$((MACHINE_COUNT + 1))

        fqdn="${prefix}${slesVersion}sp${spVersion}${suffix}.${AZURE_VMS_LOCATION}.cloudapp.azure.com"
        crt_path="${CERTS_DIR}/${fqdn}.crt"
        key_path="${CERTS_DIR}/${fqdn}.key"

        # Create temporary OpenSSL config with SAN extension
        TMP_CNF=$(mktemp)
        cat > "$TMP_CNF" << EOF_CNF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${fqdn}

[v3_req]
subjectAltName = DNS:${fqdn}
EOF_CNF

        # Generate certificate and key
        openssl req -newkey rsa:2048 \
            -nodes \
            -keyout "$key_path" \
            -x509 \
            -days 365 \
            -out "$crt_path" \
            -subj "/CN=${fqdn}" \
            -reqexts v3_req \
            -extensions v3_req \
            -config "$TMP_CNF" </dev/null >> "$LOG_FILE" 2>&1

        rm -f "$TMP_CNF"

        if [[ -f "$crt_path" && -f "$key_path" ]]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "   ⚠️  Failed to create certificate for $fqdn (Check $LOG_FILE)" >&2
        fi
    done
} < <(sed 's/\r$//' "$MACHINES_FILE")

# --- FINAL STATUS ---
echo "" >&2
echo "Total machines processed: $MACHINE_COUNT" >&2

if [ "$SUCCESS_COUNT" -eq "$MACHINE_COUNT" ] && [ "$MACHINE_COUNT" -gt 0 ]; then
    echo "✅ All $SUCCESS_COUNT certificates generated successfully" >&2
elif [ "$MACHINE_COUNT" -eq 0 ]; then
    echo "⚠️  No valid machine definitions found in CSV file" >&2
else
    echo "⚠️  Generated $SUCCESS_COUNT out of $MACHINE_COUNT certificates. Check $LOG_FILE" >&2
fi