#!/usr/bin/env bash

# ==============================================================================
# Setup SSH Keys
# ==============================================================================
# Sets up SSH keys for VM access during deployment. Uses keys from .env file
# (PRIVATE_SSH_KEY_CONTENT and PUBLIC_SSH_KEY_CONTENT) and writes them to the
# .ssh-keys directory.
#
# Also clears old host keys from ~/.ssh/known_hosts for all VMs defined in
# .machines.conf.csv to prevent SSH host key verification failures when VMs
# are recreated.
#
# Inputs:
#   - .env: Environment configuration file (required)
#     - PRIVATE_SSH_KEY_CONTENT: SSH private key content
#     - PUBLIC_SSH_KEY_CONTENT: SSH public key content
#     - AZURE_VMS_LOCATION (optional): Azure region for FQDNs
#   - .machines.conf.csv: VM definitions
# Outputs:
#   - .ssh-keys/id_ed25519: Private key (from .env)
#   - .ssh-keys/id_ed25519.pub: Public key (from .env)
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MACHINES_CSV="$PROJECT_ROOT/.machines.conf.csv"
SSH_KEYS_DIR="$PROJECT_ROOT/.ssh-keys"
PRIVATE_KEY_PATH="$SSH_KEYS_DIR/id_ed25519"
PUBLIC_KEY_PATH="$SSH_KEYS_DIR/id_ed25519.pub"

# --- VALIDATE ENVIRONMENT FILE ---
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# --- LOAD ENVIRONMENT VARIABLES ---
set -a
source "$ENV_FILE"
set +a
AZURE_VMS_LOCATION="${AZURE_VMS_LOCATION:-westeurope}"

# --- CLEAR OLD HOST KEYS FROM known_hosts ---
echo "🧹 Clearing old host keys from ~/.ssh/known_hosts..." >&2

if [ -f "$MACHINES_CSV" ]; then
    DOMAIN_SUFFIX="${AZURE_VMS_LOCATION}.cloudapp.azure.com"
    CLEARED_COUNT=0

    while IFS=',' read -r prefix slesVersion spVersion suffix || [ -n "$prefix" ]; do
        # Skip header line
        if [[ "$prefix" == "prefix" ]]; then
            continue
        fi

        # Normalize and clean CSV data
        prefix=$(echo "$prefix" | tr -d '\r' | xargs)
        slesVersion=$(echo "$slesVersion" | tr -d '\r' | xargs)
        spVersion=$(echo "$spVersion" | tr -d '\r' | xargs)
        suffix=$(echo "$suffix" | tr -d '\r' | xargs)

        # Skip empty lines
        if [ -z "$prefix" ] && [ -z "$slesVersion" ] && [ -z "$spVersion" ] && [ -z "$suffix" ]; then
            continue
        fi

        # Construct FQDN
        VM_NAME="${prefix}${slesVersion}sp${spVersion}${suffix}"
        FQDN="${VM_NAME}.${DOMAIN_SUFFIX}"

        # Remove host key if it exists
        if [ -f "$HOME/.ssh/known_hosts" ]; then
            if ssh-keygen -R "$FQDN" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
                CLEARED_COUNT=$((CLEARED_COUNT + 1))
            fi
        fi
    done < "$MACHINES_CSV"

    if [ $CLEARED_COUNT -gt 0 ]; then
        echo "✅ Cleared $CLEARED_COUNT old host key(s) from known_hosts" >&2
    else
        echo "ℹ️  No old host keys found to clear" >&2
    fi
else
    echo "⚠️  Warning: .machines.conf.csv not found, skipping known_hosts cleanup" >&2
fi

# --- CREATE SSH KEYS DIRECTORY ---
# Remove existing keys if present
if [ -d "$SSH_KEYS_DIR" ]; then
    rm -rf "$SSH_KEYS_DIR"
fi

mkdir -p "$SSH_KEYS_DIR"

# --- SETUP SSH KEY-PAIR FROM .ENV ---
echo "🔑 Setting up SSH keys from .env file..." >&2

# Validate that SSH key variables are set
if [ -z "${PRIVATE_SSH_KEY_CONTENT:-}" ]; then
    echo "❌ Error: PRIVATE_SSH_KEY_CONTENT is not set in .env file" >&2
    exit 1
fi

if [ -z "${PUBLIC_SSH_KEY_CONTENT:-}" ]; then
    echo "❌ Error: PUBLIC_SSH_KEY_CONTENT is not set in .env file" >&2
    exit 1
fi

# Write private key to file
echo "$PRIVATE_SSH_KEY_CONTENT" > "$PRIVATE_KEY_PATH"
chmod 600 "$PRIVATE_KEY_PATH"

# Write public key to file
echo "$PUBLIC_SSH_KEY_CONTENT" > "$PUBLIC_KEY_PATH"
chmod 644 "$PUBLIC_KEY_PATH"

echo "✅ SSH key-pair created from .env successfully" >&2
echo "   Private key: $PRIVATE_KEY_PATH" >&2
echo "   Public key:  $PUBLIC_KEY_PATH" >&2
