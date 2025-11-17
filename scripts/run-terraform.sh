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

# --- TERRAFORM EXECUTION ---
# Execute Terraform in a sub-shell to redirect all output and capture exit code
# Temporarily disable exit-on-error to capture the exit code
set +e
(
    terraform -chdir=terraform init "$@"
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