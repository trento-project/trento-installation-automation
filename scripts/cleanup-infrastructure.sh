#!/usr/bin/env bash

# ==============================================================================
# Delete Azure VMs
# ==============================================================================
# Deletes all VMs and their dependencies (NICs, Disks, Public IPs) from the
# Azure resource group. Storage Accounts and Container Registries are preserved.
# The script performs multiple cleanup passes to handle dependency ordering.
#
# Inputs:
#   - .env: Environment configuration file
# Outputs:
#   - logs/azure-delete-vm.log: Full deletion execution log
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
LOGS_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOGS_DIR/azure-delete-vm.log"

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
if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
    echo "❌ Error: AZURE_RESOURCE_GROUP not set in .env" >&2
    exit 1
fi

RESOURCE_GROUP_NAME="$AZURE_RESOURCE_GROUP"

# --- SETUP LOGGING ---
mkdir -p "$LOGS_DIR"
: > "$LOG_FILE"

echo "🗑️  Delete process started for resource group: $RESOURCE_GROUP_NAME" >&2
echo "--- $(date) ---" >> "$LOG_FILE"

# --- WARNING AND CONFIRMATION ---
echo "" >&2
echo "⚠️  WARNING: This will delete ALL VMs and their dependencies in resource group '$RESOURCE_GROUP_NAME'" >&2
echo "   Resources to be deleted: VMs, NICs, Disks, Public IPs" >&2
echo "   Resources preserved: Storage Accounts, Container Registries" >&2
echo "" >&2
echo "Press Ctrl+C within 10 seconds to cancel..." >&2
for i in {10..1}; do
    printf "\r   Proceeding in %2d seconds... " "$i" >&2
    sleep 1
done
printf "\r   Proceeding now...            \n" >&2
echo "" >&2

# --- VERIFY RESOURCE GROUP EXISTENCE ---
echo "Verifying resource group existence..." >> "$LOG_FILE"
if ! az group show --name "$RESOURCE_GROUP_NAME" --output none >> "$LOG_FILE" 2>&1; then
    echo "❌ Error: Resource group '$RESOURCE_GROUP_NAME' does not exist or access denied" >&2
    echo "ERROR: Resource group not found or access denied" >> "$LOG_FILE"
    exit 1
fi
echo "Resource group '$RESOURCE_GROUP_NAME' verified" >> "$LOG_FILE"

# --- CLEANUP LOGIC ---
cleanup_vms_and_deps() {
    echo "Deleting VMs and dependencies (excluding Storage Accounts and Container Registries)" >> "$LOG_FILE"
    echo "Process runs multiple cleanup passes for reliability" >> "$LOG_FILE"

    MAX_DELETION_PASSES=3
    CURRENT_PASS=0

    while [ $CURRENT_PASS -lt $MAX_DELETION_PASSES ]; do
        CURRENT_PASS=$((CURRENT_PASS + 1))
        echo "" >> "$LOG_FILE"
        echo "--- Deletion Pass $CURRENT_PASS/$MAX_DELETION_PASSES ---" >> "$LOG_FILE"

        # 1. Delete all VMs first (only in the first pass)
        if [ $CURRENT_PASS -eq 1 ]; then
            ALL_VMS_IN_RG=$(az vm list --resource-group "$RESOURCE_GROUP_NAME" --query "[].name" -o tsv 2>>"$LOG_FILE")
            if [ -n "$ALL_VMS_IN_RG" ]; then
                echo "Deleting Virtual Machines..." >> "$LOG_FILE"
                for VM_NAME_TO_DELETE in $ALL_VMS_IN_RG; do
                    echo "  - Deleting VM '$VM_NAME_TO_DELETE'" >> "$LOG_FILE"
                    az vm delete --resource-group "$RESOURCE_GROUP_NAME" --name "$VM_NAME_TO_DELETE" --yes --no-wait >> "$LOG_FILE" 2>&1
                done
                echo "VM deletions initiated. Waiting 60 seconds..." >> "$LOG_FILE"
                sleep 60
            else
                echo "No Virtual Machines found to delete" >> "$LOG_FILE"
            fi
        fi

        # 2. List remaining resources (EXCLUDING Storage Accounts and ACRs)
        REMAINING_RESOURCE_IDS_STR=$(az resource list \
            --resource-group "$RESOURCE_GROUP_NAME" \
            --query "[?type!=\`Microsoft.Storage/storageAccounts\` && type!=\`Microsoft.ContainerRegistry/registries\`].id" \
            -o tsv 2>>"$LOG_FILE")

        if [ -z "$REMAINING_RESOURCE_IDS_STR" ]; then
            echo "No remaining non-excluded resources found in pass $CURRENT_PASS" >> "$LOG_FILE"
            break
        fi

        # Count resources (Bash 3.2 compatible)
        RESOURCES_COUNT=$(echo "$REMAINING_RESOURCE_IDS_STR" | wc -l | tr -d ' ')
        echo "Pass $CURRENT_PASS - Found $RESOURCES_COUNT resources to clean (NICs, Disks, IPs, etc.)" >> "$LOG_FILE"

        # 3. Delete remaining resources
        echo "Deleting remaining dependencies..." >> "$LOG_FILE"
        if [ -n "$REMAINING_RESOURCE_IDS_STR" ]; then
            echo "$REMAINING_RESOURCE_IDS_STR" | xargs -n 1 -I {} az resource delete --ids {} --no-wait >> "$LOG_FILE" 2>&1
        fi

        echo "Deletions initiated. Waiting 5 seconds before next pass..." >> "$LOG_FILE"
        sleep 5
    done

    echo "" >> "$LOG_FILE"
    echo "---------------------- FINAL CLEANUP STATUS ----------------------" >> "$LOG_FILE"
    FINAL_CLEANUP_STR=$(az resource list --resource-group "$RESOURCE_GROUP_NAME" --query "[?type!=\`Microsoft.Storage/storageAccounts\` && type!=\`Microsoft.ContainerRegistry/registries\`].id" -o tsv 2>>"$LOG_FILE")
    if [ -z "$FINAL_CLEANUP_STR" ]; then
        echo "VM and dependency cleanup complete" >> "$LOG_FILE"
        return 0
    else
        echo "WARNING: Some resources could not be deleted" >> "$LOG_FILE"
        return 1
    fi
}

# --- EXECUTION ---
# Temporarily disable exit-on-error to capture the exit code
set +e
cleanup_vms_and_deps
CLEANUP_EXIT_CODE=$?
set -e

# --- FINAL STATUS ---
if [ $CLEANUP_EXIT_CODE -eq 0 ]; then
    echo "✅ Delete process completed successfully. Full log: $LOG_FILE" >&2
else
    echo "⚠️  Delete process completed with warnings. Check $LOG_FILE for details" >&2
    exit $CLEANUP_EXIT_CODE
fi
