#!/usr/bin/env bash

# ==============================================================================
# Run Terraform
# ==============================================================================
# Provisions Azure infrastructure using Terraform based on .machines.conf.csv
# configuration. Loads environment variables from .env and exports them as
# both standard and TF_VAR_ prefixed variables for Terraform consumption.
#
# Inputs:
#   - .env: Environment configuration file
#   - terraform/: Terraform configuration directory
#   - .machines.conf.csv: VM definitions (read by Terraform locals)
# Outputs:
#   - logs/tf-apply.log: Full Terraform execution log
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
LOGS_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOGS_DIR/tf-apply.log"

# --- VALIDATE ENVIRONMENT FILE ---
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# --- SETUP LOGGING ---
mkdir -p "$LOGS_DIR"
: > "$LOG_FILE"

echo "⚙️  Starting Terraform execution..." >&2
echo "--- $(date) ---" >> "$LOG_FILE"

# --- LOAD SSH KEYS ---
SSH_KEYS_DIR="$PROJECT_ROOT/.ssh-keys"
SSH_PRIVATE_KEY_PATH="$SSH_KEYS_DIR/id_ed25519"
SSH_PUBLIC_KEY_PATH="$SSH_KEYS_DIR/id_ed25519.pub"

if [ ! -f "$SSH_PUBLIC_KEY_PATH" ]; then
    echo "❌ Error: SSH public key not found at $SSH_PUBLIC_KEY_PATH" >&2
    echo "   Run ./scripts/setup-ssh-keys.sh first" >&2
    exit 1
fi

export SSH_PRIVATE_KEY_PATH
export SSH_PUBLIC_KEY_CONTENT="$(cat "$SSH_PUBLIC_KEY_PATH")"
echo "✅ Using SSH keys from $SSH_KEYS_DIR" >&2

# --- LOAD ENVIRONMENT VARIABLES ---
echo "📦 Loading environment variables from $ENV_FILE..." >> "$LOG_FILE"

# Load .env and export both regular and Terraform-style vars
while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    eval "export $line"
    key="$(echo "$line" | cut -d '=' -f1)"
    lower_key="$(echo "$key" | tr '[:upper:]' '[:lower:]')"
    tfvar_name="TF_VAR_${lower_key}"
    eval "export $tfvar_name='${!key}'"
done < "$ENV_FILE"

echo "✅ Environment variables loaded. Running: terraform $*" >> "$LOG_FILE"

# --- SET ARM_SUBSCRIPTION_ID FROM AZURE CLI ---
echo "🔑 Setting ARM_SUBSCRIPTION_ID from Azure CLI..." >> "$LOG_FILE"
ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>>"$LOG_FILE")
if [ -z "$ARM_SUBSCRIPTION_ID" ]; then
    echo "❌ Error: Could not retrieve subscription ID from Azure CLI" >&2
    echo "ERROR: Failed to get subscription ID from 'az account show'" >> "$LOG_FILE"
    exit 1
fi
export ARM_SUBSCRIPTION_ID
echo "✅ ARM_SUBSCRIPTION_ID set to: $ARM_SUBSCRIPTION_ID" >> "$LOG_FILE"

# --- EXPORT SSH KEYS AS TERRAFORM VARIABLES ---
export TF_VAR_ssh_private_key_path="$SSH_PRIVATE_KEY_PATH"
export TF_VAR_ssh_public_key_content="$SSH_PUBLIC_KEY_CONTENT"

# Export debugging public key if explicitly configured and exists
if [ -n "${DEBUGGING_SSH_KEY_PATH:-}" ]; then
    # Expand tilde in path
    EXPANDED_DEBUG_KEY_PATH="${DEBUGGING_SSH_KEY_PATH/#\~/$HOME}"
    if [ -f "${EXPANDED_DEBUG_KEY_PATH}.pub" ]; then
        export TF_VAR_ssh_debugging_public_key="$(cat "${EXPANDED_DEBUG_KEY_PATH}.pub")"
        echo "✅ Debugging SSH public key exported from ${EXPANDED_DEBUG_KEY_PATH}.pub" >> "$LOG_FILE"
        echo "   VMs will have both ephemeral key (for automation) and debugging key (for manual access)" >> "$LOG_FILE"
    else
        export TF_VAR_ssh_debugging_public_key=""
        echo "⚠️  DEBUGGING_SSH_KEY_PATH set but ${EXPANDED_DEBUG_KEY_PATH}.pub not found" >> "$LOG_FILE"
        echo "   VMs will only have ephemeral key" >> "$LOG_FILE"
    fi
else
    export TF_VAR_ssh_debugging_public_key=""
    echo "ℹ️  No DEBUGGING_SSH_KEY_PATH configured, using only ephemeral key" >> "$LOG_FILE"
    echo "   You can SSH with: ssh -i .ssh-keys/id_ed25519 $SSH_USER@<vm-fqdn>" >> "$LOG_FILE"
fi

echo "✅ SSH keys exported as Terraform variables" >> "$LOG_FILE"

# --- TERRAFORM BACKEND CONFIGURATION ---
# Build backend config flags for Azure Storage (same as GitHub workflow)
AZURE_BLOB_STORAGE_TF_STATE_CONTAINER="${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER:-tfstate}"
BACKEND_CONFIG=(
    -backend-config="storage_account_name=${AZURE_BLOB_STORAGE}"
    -backend-config="container_name=${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER}"
    -backend-config="key=terraform.tfstate"
    -backend-config="resource_group_name=${AZURE_RESOURCE_GROUP}"
    -backend-config="subscription_id=${ARM_SUBSCRIPTION_ID}"
)

echo "📋 Backend config: storage_account=${AZURE_BLOB_STORAGE}, container=${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER}, resource_group=${AZURE_RESOURCE_GROUP}" >> "$LOG_FILE"

# --- TERRAFORM EXECUTION ---
# Execute Terraform in a sub-shell to redirect all output and capture exit code
# Temporarily disable exit-on-error to capture the exit code
set +e
(
    terraform -chdir=terraform init "${BACKEND_CONFIG[@]}" "$@"
    terraform -chdir=terraform apply -auto-approve "$@"
) >> "$LOG_FILE" 2>&1
TERRAFORM_EXIT_CODE=$?
set -e

# --- FINAL STATUS ---
if [ $TERRAFORM_EXIT_CODE -eq 0 ]; then
    echo "✅ Terraform apply completed successfully. Full log: $LOG_FILE" >&2
else
    echo "❌ Terraform apply FAILED (Exit Code: $TERRAFORM_EXIT_CODE). Check $LOG_FILE for details." >&2
    exit $TERRAFORM_EXIT_CODE
fi