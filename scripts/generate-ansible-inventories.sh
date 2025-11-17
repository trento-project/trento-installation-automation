#!/usr/bin/env bash

# ==============================================================================
# Generate Ansible Inventories
# ==============================================================================
# Creates a single Ansible inventory file (inventory.yml) containing all VMs
# with "rpm" suffix from .machines.conf.csv. The inventory includes host
# definitions, SSL certificate references, and Trento-specific configuration.
#
# Inputs:
#   - .env: Environment configuration file
#   - .machines.conf.csv: VM definitions
# Outputs:
#   - {ANSIBLE_INVENTORIES_PATH}/inventory.yml: Ansible inventory file
# ==============================================================================

# --- BASH CONFIGURATION ---
set -euo pipefail

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MACHINES_FILE="$PROJECT_ROOT/.machines.conf.csv"

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
REQUIRED_VARS=(ANSIBLE_VM_CERTS_PATH SSH_USER AZURE_VMS_LOCATION ANSIBLE_INVENTORIES_PATH)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var is not set in .env" >&2
        exit 1
    fi
done

INVENTORIES_PATH="$ANSIBLE_INVENTORIES_PATH"

# --- VALIDATE MACHINES FILE ---
if [ ! -f "$MACHINES_FILE" ]; then
    echo "❌ Error: Machines configuration file not found at $MACHINES_FILE" >&2
    exit 1
fi

# --- PARSE MACHINES FILE ---
declare -a VMS_ALL=()

echo "⏳ Reading VM definitions from CSV..." >&2

while IFS=',' read -r prefix slesVersion spVersion suffix; do
    # Skip header line
    if [[ "$prefix" == "prefix" ]]; then
        continue
    fi

    vm_name="${prefix}${slesVersion}sp${spVersion}${suffix}"

    # Only include VMs with "rpm" suffix (skip helm and other suffixes)
    if [[ "$suffix" != "rpm" ]]; then
        echo "  ⏭️  Skipping $vm_name (suffix '$suffix' - manual installation)" >&2
        continue
    fi

    # Skip SLES 16+ (manual installation)
    if [[ "$slesVersion" -ge 16 ]]; then
        echo "  ⏭️  Skipping $vm_name (SLES $slesVersion - manual installation)" >&2
        continue
    fi

    VMS_ALL+=("$vm_name")
done < "$MACHINES_FILE"

# --- GENERATE INVENTORY FUNCTION ---
generate_inventory() {
    local filename="inventory.yml"
    local file_path="${INVENTORIES_PATH}/${filename}"

    mkdir -p "$INVENTORIES_PATH"

    cat > "$file_path" << EOF
all:
  children:
    trento_hosts:
      vars:
        ansible_python_interpreter: /usr/bin/python3
        provision_prometheus: false
        provision_proxy: true
        web_postgres_password: "postgres"
        wanda_postgres_password: "postgres"
        rabbitmq_password: "guest"
        web_admin_password: "adminpassword"
        trento_server_name: "{{ inventory_hostname }}"
        nginx_vhost_filename: "{{ inventory_hostname }}"
        nginx_ssl_cert: "{{ lookup('file', '${ANSIBLE_VM_CERTS_PATH}/' + inventory_hostname + '.crt') }}"
        nginx_ssl_key: "{{ lookup('file', '${ANSIBLE_VM_CERTS_PATH}/' + inventory_hostname + '.key') }}"
      hosts:
EOF

    for vm_name in "${VMS_ALL[@]}"; do
        fqdn="${vm_name}.${AZURE_VMS_LOCATION}.cloudapp.azure.com"
        {
            echo "        ${fqdn}:"
            echo "          ansible_user: ${SSH_USER}"
        } >> "$file_path"
    done

    cat >> "$file_path" << EOF
    trento_server:
      children:
        trento_hosts: {}
    postgres_hosts:
      children:
        trento_hosts: {}
    rabbitmq_hosts:
      children:
        trento_hosts: {}
EOF

    echo "✅ Successfully generated: ${file_path}" >&2
}

# --- GENERATE INVENTORY ---
if [ ${#VMS_ALL[@]} -gt 0 ]; then
    echo "📝 Generating inventory with ${#VMS_ALL[@]} VM(s)..." >&2
    generate_inventory
else
    echo "⚠️  No valid VMs found in ${MACHINES_FILE}" >&2
    exit 1
fi
