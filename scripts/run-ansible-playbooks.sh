#!/usr/bin/env bash

# ==============================================================================
# Run Ansible Playbooks
# ==============================================================================
# Executes Ansible playbooks from an external project using a dedicated Python
# virtual environment. Creates/reuses a venv, installs Ansible and required
# collections, then runs the playbook against the generated inventory.
#
# Inputs:
#   - .env: Environment configuration file
#   - {ANSIBLE_INVENTORIES_PATH}/inventory.yml: Generated inventory
#   - {ANSIBLE_PROJECT_PATH}/playbook.yml: Main playbook to execute
#   - {ANSIBLE_REQUIREMENTS_PATH}/requirements.yml: Ansible collections
# Outputs:
#   - logs/ansible-run.log: Full Ansible execution log
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
LOGS_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOGS_DIR/ansible-run.log"

# --- VALIDATE ENVIRONMENT FILE ---
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# --- SETUP LOGGING ---
mkdir -p "$LOGS_DIR"
: > "$LOG_FILE"

# --- LOAD ENVIRONMENT VARIABLES ---
echo "✅ Loading environment variables from $ENV_FILE" >&2
set -o allexport
eval "$(grep -v -e '^#' -e '^$' "$ENV_FILE")"
set +o allexport

# --- VALIDATE REQUIRED VARIABLES ---
if [ -z "${ANSIBLE_INVENTORIES_PATH:-}" ]; then
    echo "❌ Error: ANSIBLE_INVENTORIES_PATH is not set in .env" >&2
    exit 1
fi

if [ -z "${ANSIBLE_PROJECT_PATH:-}" ]; then
    echo "❌ Error: ANSIBLE_PROJECT_PATH is not set in .env" >&2
    exit 1
fi

# --- CONFIGURATION ---
ANSIBLE_REQUIREMENTS_PATH="${ANSIBLE_REQUIREMENTS_PATH:-$ANSIBLE_PROJECT_PATH}"
REQUIREMENTS_FILE="$ANSIBLE_REQUIREMENTS_PATH/requirements.yml"
ANSIBLE_PYTHON_EXEC="${ANSIBLE_PYTHON_EXEC:-python3}"
INVENTORY_FILE="$ANSIBLE_INVENTORIES_PATH/inventory.yml"
VENV_NAME=".venv-ansible"
ANSIBLE_CORE_VERSION="2.16.*"
ANSIBLE_VENV_PATH="$PROJECT_ROOT/$VENV_NAME"
ANSIBLE_EXEC="$ANSIBLE_VENV_PATH/bin/ansible-playbook"
ANSIBLE_GALAXY_EXEC="$ANSIBLE_VENV_PATH/bin/ansible-galaxy"
ANSIBLE_VENV_COLLECTIONS="$ANSIBLE_VENV_PATH/lib/python*/site-packages/ansible/collections"

# --- VALIDATE INVENTORY FILE ---
if [ ! -f "$INVENTORY_FILE" ]; then
    echo "❌ Error: Inventory file not found at $INVENTORY_FILE" >&2
    exit 1
fi

# --- SETUP ANSIBLE VIRTUAL ENVIRONMENT FUNCTION ---
setup_ansible_venv() {
    local venv_path="$1"
    local version="$2"

    if [ ! -f "$venv_path/bin/ansible-playbook" ]; then
        echo "🐍 Creating Python virtual environment for Ansible using $ANSIBLE_PYTHON_EXEC..." >&2
        "$ANSIBLE_PYTHON_EXEC" -m venv "$venv_path"
        (
            source "$venv_path/bin/activate"
            pip install --upgrade pip >> "$LOG_FILE" 2>&1
            pip install "ansible-core==$version" >> "$LOG_FILE" 2>&1
        )
        echo "✅ Ansible virtual environment created" >&2
    else
        echo "🐍 Using existing Ansible virtual environment" >&2
    fi
}

# --- SETUP VIRTUAL ENVIRONMENT ---
setup_ansible_venv "$ANSIBLE_VENV_PATH" "$ANSIBLE_CORE_VERSION"

# --- INSTALL ANSIBLE COLLECTIONS ---
if [ -f "$REQUIREMENTS_FILE" ]; then
    echo "📦 Installing Ansible collections from $REQUIREMENTS_FILE..." >&2
    (
        source "$ANSIBLE_VENV_PATH/bin/activate"
        if ANSIBLE_COLLECTIONS_PATHS="$ANSIBLE_VENV_COLLECTIONS" "$ANSIBLE_GALAXY_EXEC" collection install -r "$REQUIREMENTS_FILE" >> "$LOG_FILE" 2>&1; then
            echo "✅ Collections installed successfully" >&2
        else
            echo "❌ Error installing collections. Check $LOG_FILE for details." >&2
            exit 1
        fi
    )
else
    echo "ℹ️  No requirements.yml found at $REQUIREMENTS_FILE. Skipping collection installation." >&2
fi

# --- VALIDATE PLAYBOOK FILE ---
PLAYBOOK_FILE="$ANSIBLE_PROJECT_PATH/playbook.yml"

if [ ! -f "$PLAYBOOK_FILE" ]; then
    echo "❌ Error: Playbook file not found at $PLAYBOOK_FILE" >&2
    exit 1
fi

# --- EXECUTE ANSIBLE PLAYBOOK ---
echo "" >&2
echo "🚀 Starting Ansible playbook execution..." >&2
echo "   Inventory: $INVENTORY_FILE" >&2
echo "   Playbook:  $PLAYBOOK_FILE" >&2
echo "   Logs:      $LOG_FILE" >&2
echo "" >&2

{
    echo "========== [$(date)] STARTING ANSIBLE PLAYBOOK =========="
    echo "Inventory: $INVENTORY_FILE"
    echo "Playbook:  $PLAYBOOK_FILE"
    echo "========================================================="
} >> "$LOG_FILE"

if "$ANSIBLE_EXEC" -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" >> "$LOG_FILE" 2>&1; then
    echo "" >&2
    echo "✅ Ansible playbook completed successfully" >&2
    echo "[SUCCESS $(date)] Playbook finished successfully" >> "$LOG_FILE"
else
    echo "" >&2
    echo "❌ Ansible playbook failed. Check $LOG_FILE for details." >&2
    echo "[FAILURE $(date)] Playbook failed" >> "$LOG_FILE"
    exit 1
fi
