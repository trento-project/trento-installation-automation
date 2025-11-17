#!/bin/bash

# ==============================================================================
# Bash Version Check
# ==============================================================================
# This script requires Bash 4.0+ for associative arrays used in subscripts.
# ==============================================================================

BASH_VERSION_MAJOR="${BASH_VERSINFO[0]}"

if [ "$BASH_VERSION_MAJOR" -lt 4 ]; then
    echo "❌ Error: This script requires Bash 4.0+, but found version $BASH_VERSION_MAJOR"
    echo "Please upgrade Bash on your system"
    exit 1
fi

# Clean up previous runs
rm -rf certs
rm -rf .venv-ansible
rm -rf inventories
rm -rf logs

# Terminal formatting - using ANSI escape codes
BOLD_GREEN="\033[1;32m"
RESET="\033[0m"

echo -e "${BOLD_GREEN}### Provision Azure Infrastructure with Terraform ###${RESET}"
./scripts/run-terraform.sh
echo

echo -e "${BOLD_GREEN}### Clear SSH Known Hosts ###${RESET}"
./scripts/clear-known-hosts.sh
echo

echo -e "${BOLD_GREEN}### Setting up Machines, SUSE Registration, custom rpm repo... ###${RESET}"
./scripts/setup-machines.sh
echo

echo -e "${BOLD_GREEN}### Generate SSL Certificates ###${RESET}"
./scripts/generate-certs.sh
echo

echo -e "${BOLD_GREEN}### Generate Ansible Inventories ###${RESET}"
./scripts/generate-ansible-inventories.sh
echo

echo -e "${BOLD_GREEN}### Run Ansible Playbooks ###${RESET}"
./scripts/run-ansible-playbooks.sh
echo

echo -e "${BOLD_GREEN}✅ Pipeline completed successfully!${RESET}"
