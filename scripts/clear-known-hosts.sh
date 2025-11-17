#!/usr/bin/env bash

# ==============================================================================
# Clear SSH Known Hosts
# ==============================================================================
# Removes SSH host keys from ~/.ssh/known_hosts for all VMs defined in
# .machines.conf.csv. This prevents SSH key verification issues when
# reprovisioning infrastructure with the same FQDNs.
#
# Inputs:
#   - .env: Environment configuration file
#   - .machines.conf.csv: VM definitions
# Outputs:
#   - Updates ~/.ssh/known_hosts by removing matching entries
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MACHINES_FILE="$PROJECT_ROOT/.machines.conf.csv"
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

# --- GLOBAL VARIABLES ---
REMOVED_COUNT=0
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
if [ -z "${AZURE_VMS_LOCATION:-}" ]; then
    echo "❌ Error: AZURE_VMS_LOCATION is not set in .env" >&2
    exit 1
fi

# --- VALIDATE MACHINES FILE ---
if [ ! -f "$MACHINES_FILE" ]; then
    echo "❌ Error: Machines configuration file not found at $MACHINES_FILE" >&2
    exit 1
fi

# --- CHECK KNOWN_HOSTS FILE ---
if [ ! -f "$KNOWN_HOSTS_FILE" ]; then
    echo "ℹ️  No known_hosts file found at $KNOWN_HOSTS_FILE - nothing to clear" >&2
    exit 0
fi

echo "⏳ Clearing SSH known_hosts entries..." >&2

# --- REMOVE KNOWN_HOSTS ENTRIES ---
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

        MACHINE_COUNT=$((MACHINE_COUNT + 1))

        fqdn="${prefix}${slesVersion}sp${spVersion}${suffix}.${AZURE_VMS_LOCATION}.cloudapp.azure.com"

        # Remove entry from known_hosts
        if ssh-keygen -R "$fqdn" >/dev/null 2>&1; then
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
            echo "   🗑️  Removed: $fqdn" >&2
        fi
    done
} < <(sed 's/\r$//' "$MACHINES_FILE")

# --- FINAL STATUS ---
echo "" >&2
echo "Total machines processed: $MACHINE_COUNT" >&2

if [ "$REMOVED_COUNT" -gt 0 ]; then
    echo "✅ Removed $REMOVED_COUNT SSH host key(s) from known_hosts" >&2
elif [ "$MACHINE_COUNT" -gt 0 ]; then
    echo "ℹ️  No existing SSH host keys found to remove" >&2
else
    echo "⚠️  No valid machine definitions found in CSV file" >&2
fi
