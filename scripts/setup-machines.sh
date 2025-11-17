#!/usr/bin/env bash

# ==============================================================================
# Setup Machines
# ==============================================================================
# Initializes all VMs defined in .machines.conf.csv by executing remote setup
# commands via SSH. Runs in parallel across all VMs and performs SUSE system
# registration, module activation, Python installation, and RPM repository
# configuration for VMs with "rpm" suffix.
#
# Inputs:
#   - .env: Environment configuration file
#   - .machines.conf.csv: VM definitions
# Outputs:
#   - logs/{vm_name}.log: Individual VM setup log for each machine
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MACHINES_CSV="$PROJECT_ROOT/.machines.conf.csv"
LOGS_DIR="$PROJECT_ROOT/logs"

# --- GLOBAL VARIABLES ---
TEMP_MACHINES_FILE=$(mktemp)
declare -A PID_TO_VM_NAME=()
declare -a PIDS=()
ERROR_COUNT=0

# --- CLEANUP HANDLER ---
trap 'rm -f "$TEMP_MACHINES_FILE"' EXIT

# --- VALIDATE ENVIRONMENT FILE ---
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# --- LOAD ENVIRONMENT VARIABLES ---
set -a
source "$ENV_FILE"
set +a

DOMAIN_SUFFIX="${AZURE_VMS_LOCATION}.cloudapp.azure.com"

# --- VALIDATE MACHINES FILE ---
if [ ! -f "$MACHINES_CSV" ]; then
    echo "❌ Error: Machines configuration file not found at $MACHINES_CSV" >&2
    exit 1
fi

# --- VALIDATE REQUIRED VARIABLES ---
if [ -z "${SSH_USER:-}" ]; then
    echo "❌ Error: SSH_USER variable is not defined in .env" >&2
    exit 1
fi

# --- SETUP LOGGING ---
mkdir -p "$LOGS_DIR"
rm -f "$LOGS_DIR"/*.log

# --- PREPARE CSV DATA ---
grep -v '^$' "$MACHINES_CSV" > "$TEMP_MACHINES_FILE"

# --- VM INITIALIZATION FUNCTION ---
initialize_vm() {
    local FULL_FQDN=$1
    local VM_NAME_BASE=$2
    local USER="$SSH_USER"
    local FQDN="$FULL_FQDN"

    echo "🛠️  Starting initialization: $VM_NAME_BASE (Log: $LOGS_DIR/${VM_NAME_BASE}.log)"

    # Wait for SSH port availability
    echo "⏳ Waiting for SSH port (22) to be available on $FQDN..."
    local max_attempts=20
    local attempt=1
    while ! nc -z -w 5 "$FQDN" 22; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "❌ SSH port not reachable after $attempt attempts on $FQDN"
            return 1
        fi
        echo "   Attempt $attempt: Port 22 still closed, waiting 10s..."
        attempt=$((attempt+1))
        sleep 10
    done
    echo "✅ SSH port is available on $FQDN"

    # Wait for remote login readiness (nologin file check)
    echo "⏳ Waiting for remote login to be permitted..."
    local login_max_attempts=15
    local login_attempt=1

    while ! ssh -o StrictHostKeyChecking=accept-new -i "$SSH_PRIVATE_KEY_PATH" "$USER@$FQDN" true 2>/dev/null; do
        if [ "$login_attempt" -ge "$login_max_attempts" ]; then
            echo "❌ Remote login not permitted after $login_attempt attempts"
            return 1
        fi
        echo "   Login attempt $login_attempt: Still booting, waiting 15s..."
        login_attempt=$((login_attempt+1))
        sleep 15
    done
    echo "✅ SSH login is now permitted on $FQDN"

    # Execute remote commands
    if ssh -o StrictHostKeyChecking=accept-new -i "$SSH_PRIVATE_KEY_PATH" "$USER@$FQDN" bash <<EOF_REMOTE; then

# Register system with SUSEConnect
echo "🔑 Registering system with SUSEConnect..."
sudo SUSEConnect -r "$SUSE_REGISTRATION_CODE" -e "$SUSE_REGISTRATION_EMAIL" || echo "⚠️  Registration failed or already completed."

# Detect Service Pack version from hostname
SP_VERSION=\$(echo "\$HOSTNAME" | grep -o 'sp[0-9]*' | cut -c3-)
echo "🧩 Detected Service Pack version: \$SP_VERSION"

# Register SUSE modules
sudo SUSEConnect -p sle-module-basesystem/15.\$SP_VERSION/x86_64 || echo "⚠️  Basesystem module failed."
sudo SUSEConnect -p PackageHub/15.\$SP_VERSION/x86_64 || echo "⚠️  PackageHub failed."

if [ "\$SP_VERSION" -ge 5 ]; then
    sudo SUSEConnect -p sle-module-legacy/15.\$SP_VERSION/x86_64 || echo "⚠️  Legacy module failed."
fi

# Install Python 3.11 for SP versions <= 6
if [ "\$SP_VERSION" -le 6 ]; then
    (sudo zypper --non-interactive --gpg-auto-import-keys install --auto-agree-with-licenses python311-base) || \
    (echo "Retrying Python311..." && sleep 5 && sudo zypper --non-interactive --gpg-auto-import-keys install --auto-agree-with-licenses python311-base) || \
    echo "⚠️  Python311 installation failed."
fi

# RPM-specific setup for VMs with "rpm" in hostname
if [[ "\$HOSTNAME" == *rpm* ]]; then
    echo "📦 Setting up custom RPM repository..."

    SAS_QUERY_STRING="$AZURE_BLOB_STORAGE_SAS_TOKEN"
    URL_BASE='https://$AZURE_BLOB_STORAGE.blob.core.windows.net/$AZURE_BLOB_STORAGE_CONTAINER'
    DEST_PATH='/var/cache/zypper/custom_repo'
    REPO_NAME='custom_rpms'
    URL_ORIGIN="\$URL_BASE?\$SAS_QUERY_STRING"

    sudo zypper --non-interactive --gpg-auto-import-keys addrepo https://packages.microsoft.com/sles/15/prod/ microsoft-prod
    sudo zypper --non-interactive --gpg-auto-import-keys refresh

    # Install AzCopy with retry
    (sudo zypper --non-interactive --gpg-auto-import-keys install -y azcopy) || \
    (echo "Retrying AzCopy..." && sleep 5 && sudo zypper --non-interactive --gpg-auto-import-keys install -y azcopy) || \
    { echo '❌ ERROR: AzCopy installation failed.' >&2; exit 1; }

    sudo mkdir -p "\$DEST_PATH"
    sudo azcopy cp "\$URL_ORIGIN" "\$DEST_PATH" --recursive=true || { echo '❌ ERROR: AzCopy transfer failed.' >&2; exit 1; }

    sudo zypper --non-interactive --gpg-auto-import-keys install --auto-agree-with-licenses createrepo_c
    sudo createrepo_c "\$DEST_PATH" || { echo '❌ ERROR: createrepo failed.' >&2; exit 1; }

    echo -e "[\$REPO_NAME]\nname=Local Custom RPMs\nbaseurl=file://\$DEST_PATH/\nenabled=1\ngpgcheck=0\npriority=1" | sudo tee /etc/zypp/repos.d/\$REPO_NAME.repo > /dev/null

    sudo zypper clean --all
    sudo zypper --non-interactive --gpg-auto-import-keys refresh || { echo '❌ ERROR: zypper refresh failed.' >&2; exit 1; }
fi

EOF_REMOTE

        echo "✅ Initialization completed for $VM_NAME_BASE"
        return 0
    else
        echo "❌ SSH remote execution failed for $VM_NAME_BASE"
        return 1
    fi
}

# --- SLES 16+ VM INITIALIZATION FUNCTION ---
initialize_vm_sles16() {
    local FULL_FQDN=$1
    local VM_NAME_BASE=$2
    local USER="$SSH_USER"
    local FQDN="$FULL_FQDN"

    echo "🛠️  Starting SLES 16+ initialization: $VM_NAME_BASE (Log: $LOGS_DIR/${VM_NAME_BASE}.log)"

    # Wait for SSH port availability
    echo "⏳ Waiting for SSH port (22) to be available on $FQDN..."
    local max_attempts=20
    local attempt=1
    while ! nc -z -w 5 "$FQDN" 22; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "❌ SSH port not reachable after $attempt attempts on $FQDN"
            return 1
        fi
        echo "   Attempt $attempt: Port 22 still closed, waiting 10s..."
        attempt=$((attempt+1))
        sleep 10
    done
    echo "✅ SSH port is available on $FQDN"

    # Wait for remote login readiness
    echo "⏳ Waiting for remote login to be permitted..."
    local login_max_attempts=15
    local login_attempt=1

    while ! ssh -o StrictHostKeyChecking=accept-new -i "$SSH_PRIVATE_KEY_PATH" "$USER@$FQDN" true 2>/dev/null; do
        if [ "$login_attempt" -ge "$login_max_attempts" ]; then
            echo "❌ Remote login not permitted after $login_attempt attempts"
            return 1
        fi
        echo "   Login attempt $login_attempt: Still booting, waiting 15s..."
        login_attempt=$((login_attempt+1))
        sleep 15
    done
    echo "✅ SSH login is now permitted on $FQDN"

    # Execute SLES 16+ specific remote commands
    if ssh -o StrictHostKeyChecking=accept-new -i "$SSH_PRIVATE_KEY_PATH" "$USER@$FQDN" bash <<EOF_REMOTE; then

# Register system with SUSEConnect
echo "🔑 Registering system with SUSEConnect..."
sudo SUSEConnect -r "$SUSE_REGISTRATION_CODE" -e "$SUSE_REGISTRATION_EMAIL" || echo "⚠️  Registration failed or already completed."

echo "ℹ️  SLES 16+ setup complete. Manual Trento installation required."

EOF_REMOTE

        echo "✅ SLES 16+ initialization completed for $VM_NAME_BASE"
        return 0
    else
        echo "❌ SSH remote execution failed for $VM_NAME_BASE"
        return 1
    fi
}

# --- HELM VM INITIALIZATION FUNCTION (Registration Only) ---
initialize_vm_helm() {
    local FULL_FQDN=$1
    local VM_NAME_BASE=$2
    local USER="$SSH_USER"
    local FQDN="$FULL_FQDN"

    echo "🛠️  Starting Helm VM initialization (registration only): $VM_NAME_BASE (Log: $LOGS_DIR/${VM_NAME_BASE}.log)"

    # Wait for SSH port availability
    echo "⏳ Waiting for SSH port (22) to be available on $FQDN..."
    local max_attempts=20
    local attempt=1
    while ! nc -z -w 5 "$FQDN" 22; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "❌ SSH port not reachable after $attempt attempts on $FQDN"
            return 1
        fi
        echo "   Attempt $attempt: Port 22 still closed, waiting 10s..."
        attempt=$((attempt+1))
        sleep 10
    done
    echo "✅ SSH port is available on $FQDN"

    # Wait for remote login readiness
    echo "⏳ Waiting for remote login to be permitted..."
    local login_max_attempts=15
    local login_attempt=1

    while ! ssh -o StrictHostKeyChecking=accept-new -i "$SSH_PRIVATE_KEY_PATH" "$USER@$FQDN" true 2>/dev/null; do
        if [ "$login_attempt" -ge "$login_max_attempts" ]; then
            echo "❌ Remote login not permitted after $login_attempt attempts"
            return 1
        fi
        echo "   Login attempt $login_attempt: Still booting, waiting 15s..."
        login_attempt=$((login_attempt+1))
        sleep 15
    done
    echo "✅ SSH login is now permitted on $FQDN"

    # Execute Helm-specific remote commands (registration only)
    if ssh -o StrictHostKeyChecking=accept-new -i "$SSH_PRIVATE_KEY_PATH" "$USER@$FQDN" bash <<EOF_REMOTE; then

# Register system with SUSEConnect
echo "🔑 Registering system with SUSEConnect..."
sudo SUSEConnect -r "$SUSE_REGISTRATION_CODE" -e "$SUSE_REGISTRATION_EMAIL" || echo "⚠️  Registration failed or already completed."

echo "ℹ️  Helm VM setup complete. Manual Trento Helm installation required."

EOF_REMOTE

        echo "✅ Helm VM initialization completed for $VM_NAME_BASE"
        return 0
    else
        echo "❌ SSH remote execution failed for $VM_NAME_BASE"
        return 1
    fi
}

# --- MAIN EXECUTION: PARALLEL VM INITIALIZATION ---
echo "🚀 Setting up SUSE VMs..." >&2

while IFS=, read -r prefix slesVersion spVersion suffix; do
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

    # Validate suffix - only "rpm" and "helm" are supported
    if [[ "$suffix" != "rpm" && "$suffix" != "helm" ]]; then
        echo "❌ Error: Invalid suffix '$suffix' in CSV. Only 'rpm' and 'helm' are supported." >&2
        exit 1
    fi

    # Construct FQDN
    VM_NAME_BASE="${prefix}${slesVersion}sp${spVersion}${suffix}"
    FULL_FQDN="${VM_NAME_BASE}.${DOMAIN_SUFFIX}"

    # Launch initialization in background based on SLES version and suffix
    if [ "$slesVersion" -ge 16 ]; then
        # SLES 16+ uses registration-only initialization
        initialize_vm_sles16 "$FULL_FQDN" "$VM_NAME_BASE" > "$LOGS_DIR/${VM_NAME_BASE}.log" 2>&1 &
    elif [[ "$suffix" == "helm" ]]; then
        # Helm suffix uses registration-only initialization
        initialize_vm_helm "$FULL_FQDN" "$VM_NAME_BASE" > "$LOGS_DIR/${VM_NAME_BASE}.log" 2>&1 &
    else
        # RPM suffix uses full initialization
        initialize_vm "$FULL_FQDN" "$VM_NAME_BASE" > "$LOGS_DIR/${VM_NAME_BASE}.log" 2>&1 &
    fi

    # Track process
    current_pid=$!
    PIDS+=("$current_pid")
    PID_TO_VM_NAME["$current_pid"]="$FULL_FQDN"

    echo "  > Launched $FULL_FQDN (Log: $LOGS_DIR/${VM_NAME_BASE}.log)" >&2
done < "$TEMP_MACHINES_FILE"

# --- WAIT FOR COMPLETION AND COLLECT RESULTS ---
for pid in "${PIDS[@]}"; do
    vm_fqdn="${PID_TO_VM_NAME[$pid]}"

    if wait "$pid"; then
        echo "✅ $vm_fqdn" >&2
    else
        echo "❌ $vm_fqdn failed. Check log: $LOGS_DIR/${vm_fqdn%%.*}.log" >&2
        ERROR_COUNT=$((ERROR_COUNT+1))
    fi
done

# --- FINAL STATUS ---
if [ "$ERROR_COUNT" -ne 0 ]; then
    echo "" >&2
    echo "🚨 $ERROR_COUNT VM(s) failed during initialization. Check logs in $LOGS_DIR/" >&2
    exit 1
fi
