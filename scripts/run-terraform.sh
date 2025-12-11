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

# --- LOAD .ENV FILE ---
# Load .env for environment variables and PUBLIC_SSH_KEY_CONTENT (needed by Terraform)
set -a
source "$ENV_FILE"
set +a

# --- VALIDATE SSH KEYS EXIST ---
# Keys should be created by setup-ssh-keys.sh script
SSH_KEYS_DIR="$PROJECT_ROOT/.ssh-keys"
SSH_PRIVATE_KEY_PATH="$SSH_KEYS_DIR/id_ed25519"
SSH_PUBLIC_KEY_PATH="$SSH_KEYS_DIR/id_ed25519.pub"

if [ ! -f "$SSH_PRIVATE_KEY_PATH" ] || [ ! -f "$SSH_PUBLIC_KEY_PATH" ]; then
    echo "❌ Error: SSH keys not found in $SSH_KEYS_DIR" >&2
    echo "   Please run: ./scripts/setup-ssh-keys.sh" >&2
    exit 1
fi

# Validate PUBLIC_SSH_KEY_CONTENT from .env (required by Terraform)
if [ -z "${PUBLIC_SSH_KEY_CONTENT:-}" ]; then
    echo "❌ Error: PUBLIC_SSH_KEY_CONTENT is not set in .env file" >&2
    echo "   Please set PUBLIC_SSH_KEY_CONTENT in .env" >&2
    exit 1
fi

export SSH_PRIVATE_KEY_PATH
echo "✅ Using SSH keys from $SSH_KEYS_DIR" >&2

# --- EXPORT TERRAFORM VARIABLES ---
echo "📦 Exporting Terraform variables..." >> "$LOG_FILE"

# Export Terraform-style variables from already loaded .env
# SSH keys
export TF_VAR_ssh_private_key_path="$SSH_PRIVATE_KEY_PATH"
export TF_VAR_ssh_public_key_content="$PUBLIC_SSH_KEY_CONTENT"

# Azure configuration
export TF_VAR_azure_resource_group="${AZURE_RESOURCE_GROUP}"
export TF_VAR_azure_owner_tag="${AZURE_OWNER_TAG}"

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
echo "   You can SSH with: ssh -i .ssh-keys/id_ed25519 cloudadmin@<vm-fqdn>" >> "$LOG_FILE"

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