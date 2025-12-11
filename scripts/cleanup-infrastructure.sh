#!/usr/bin/env bash

# ==============================================================================
# Cleanup Infrastructure (Terraform Destroy)
# ==============================================================================
# Destroys all Terraform-managed Azure infrastructure using terraform destroy.
# Uses the same backend configuration as run-terraform.sh.
#
# Inputs:
#   - .env: Environment configuration file
#   - terraform/: Terraform configuration directory
# Outputs:
#   - logs/tf-destroy.log: Full Terraform destruction log
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
LOGS_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOGS_DIR/tf-destroy.log"

# --- VALIDATE ENVIRONMENT FILE ---
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# --- SETUP LOGGING ---
mkdir -p "$LOGS_DIR"
: > "$LOG_FILE"

echo "🗑️  Starting Terraform destroy..." >&2
echo "--- $(date) ---" >> "$LOG_FILE"

# --- LOAD ENVIRONMENT VARIABLES ---
echo "📦 Loading environment variables from $ENV_FILE..." >> "$LOG_FILE"

# Load .env file using source (handles multi-line values safely)
set -a
source "$ENV_FILE"
set +a

# Validate required variables from .env
if [ -z "${PUBLIC_SSH_KEY_CONTENT:-}" ]; then
    echo "❌ Error: PUBLIC_SSH_KEY_CONTENT is not set in .env file" >&2
    exit 1
fi

if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
    echo "❌ Error: AZURE_RESOURCE_GROUP is not set in .env file" >&2
    exit 1
fi

if [ -z "${AZURE_OWNER_TAG:-}" ]; then
    echo "❌ Error: AZURE_OWNER_TAG is not set in .env file" >&2
    exit 1
fi

# Export Terraform variables
export TF_VAR_ssh_public_key_content="$PUBLIC_SSH_KEY_CONTENT"
export TF_VAR_azure_resource_group="$AZURE_RESOURCE_GROUP"
export TF_VAR_azure_owner_tag="$AZURE_OWNER_TAG"

echo "✅ Environment variables loaded" >> "$LOG_FILE"

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

# --- TERRAFORM BACKEND CONFIGURATION ---
AZURE_BLOB_STORAGE_TF_STATE_CONTAINER="${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER:-tfstate}"
BACKEND_CONFIG=(
    -backend-config="storage_account_name=${AZURE_BLOB_STORAGE}"
    -backend-config="container_name=${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER}"
    -backend-config="key=terraform.tfstate"
    -backend-config="resource_group_name=${AZURE_RESOURCE_GROUP}"
    -backend-config="subscription_id=${ARM_SUBSCRIPTION_ID}"
)

echo "📋 Backend config: storage_account=${AZURE_BLOB_STORAGE}, container=${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER}, resource_group=${AZURE_RESOURCE_GROUP}" >> "$LOG_FILE"

# --- WARNING AND CONFIRMATION ---
echo "" >&2
echo "⚠️  WARNING: This will DESTROY all Terraform-managed infrastructure!" >&2
echo "   Resource group: ${AZURE_RESOURCE_GROUP}" >&2
echo "   State backend: ${AZURE_BLOB_STORAGE}/${AZURE_BLOB_STORAGE_TF_STATE_CONTAINER}" >&2
echo "" >&2
echo "Press Ctrl+C within 10 seconds to cancel..." >&2
for i in {10..1}; do
    printf "\r   Proceeding in %2d seconds... " "$i" >&2
    sleep 1
done
printf "\r   Proceeding now...            \n" >&2
echo "" >&2

# --- TERRAFORM EXECUTION ---
echo "🔄 Running terraform init..." >&2
set +e
(
    terraform -chdir=terraform init "${BACKEND_CONFIG[@]}"
) >> "$LOG_FILE" 2>&1
INIT_EXIT_CODE=$?

if [ $INIT_EXIT_CODE -ne 0 ]; then
    echo "❌ Terraform init failed. Check $LOG_FILE for details." >&2
    exit $INIT_EXIT_CODE
fi

echo "🗑️  Running terraform destroy..." >&2
(
    terraform -chdir=terraform destroy -auto-approve
) >> "$LOG_FILE" 2>&1
DESTROY_EXIT_CODE=$?
set -e

# --- FINAL STATUS ---
if [ $DESTROY_EXIT_CODE -eq 0 ]; then
    echo "✅ Terraform destroy completed successfully. Full log: $LOG_FILE" >&2
else
    echo "❌ Terraform destroy FAILED (Exit Code: $DESTROY_EXIT_CODE). Check $LOG_FILE for details." >&2
    exit $DESTROY_EXIT_CODE
fi
