#!/usr/bin/env bash

# ==============================================================================
# Verify Hosts Readiness
# ==============================================================================
# Checks the readiness endpoints for Trento web and wanda services
# on all hosts defined in .machines.conf.csv.
#
# For each host, checks:
#   - https://<host>/api/readyz (Trento web ready)
#   - https://<host>/api/healthz (Trento web health)
#   - https://<host>/wanda/api/readyz (Trento wanda ready)
#   - https://<host>/wanda/api/healthz (Trento wanda health)
#
# Inputs:
#   - .env: Environment configuration file
#   - .machines.conf.csv: VM definitions
# Outputs:
#   - Readiness check results for each host
# ==============================================================================

# --- BASH CONFIGURATION ---
set -e

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

# --- DEFAULT CONFIGURATION ---
# Default to westeurope if not set
AZURE_VMS_LOCATION="${AZURE_VMS_LOCATION:-westeurope}"

# --- VALIDATE MACHINES FILE ---
if [ ! -f "$MACHINES_FILE" ]; then
    echo "❌ Error: Machines configuration file not found at $MACHINES_FILE" >&2
    exit 1
fi

# --- PARSE MACHINES FILE ---
declare -a VMS_ALL=()

echo "⏳ Reading VM definitions from CSV..." >&2

while IFS=',' read -r prefix slesVersion spVersion suffix || [ -n "$prefix" ]; do
    # Skip header line
    if [[ "$prefix" == "prefix" ]]; then
        continue
    fi

    vm_name="${prefix}${slesVersion}sp${spVersion}${suffix}"

    # Only include VMs with "rpm" suffix (skip helm and other suffixes)
    if [[ "$suffix" != "rpm" ]]; then
        continue
    fi

    # Skip SLES 16+ (manual installation)
    if [[ "$slesVersion" -ge 16 ]]; then
        continue
    fi

    VMS_ALL+=("$vm_name")
done < "$MACHINES_FILE"

# --- CHECK IF VMS FOUND ---
if [ ${#VMS_ALL[@]} -eq 0 ]; then
    echo "⚠️  No valid VMs found in ${MACHINES_FILE}" >&2
    exit 1
fi

# --- CONFIGURATION ---
MAX_RETRIES=5
INITIAL_WAIT=10

# --- READINESS CHECK FUNCTION WITH RETRY ---
check_endpoint() {
    local host="$1"
    local path="$2"
    local service_name="$3"

    local url="https://${host}${path}"
    echo "  🔍 Checking $service_name: $url"

    local retry=0
    local wait_time=$INITIAL_WAIT

    while [ $retry -lt $MAX_RETRIES ]; do
        # Get both the response body and HTTP status code
        local response
        local http_code
        local body

        response=$(curl -k -s -S -w '\n%{http_code}' --max-time 10 --connect-timeout 5 "$url" 2>/dev/null || printf "\n000")

        # Extract the last line as HTTP code and everything before as body
        http_code=$(echo "$response" | tail -n 1)
        body=$(echo "$response" | head -n -1)

        # Check if http_code is actually a number
        if ! [[ "$http_code" =~ ^[0-9]+$ ]]; then
            retry=$((retry + 1))
            if [ $retry -lt $MAX_RETRIES ]; then
                echo "    ⏳ $service_name - Invalid response (attempt $retry/$MAX_RETRIES), retrying in ${wait_time}s..."
                sleep $wait_time
                wait_time=$((wait_time * 2))
                continue
            else
                echo "    ❌ $service_name - Connection failed after $MAX_RETRIES attempts"
                return 1
            fi
        fi

        # Check for connection failure
        if [[ "$http_code" == "000" ]]; then
            retry=$((retry + 1))
            if [ $retry -lt $MAX_RETRIES ]; then
                echo "    ⏳ $service_name - Connection failed (attempt $retry/$MAX_RETRIES), retrying in ${wait_time}s..."
                sleep $wait_time
                wait_time=$((wait_time * 2))
                continue
            else
                echo "    ❌ $service_name - Connection failed after $MAX_RETRIES attempts"
                return 1
            fi
        fi

        # Check if the HTTP code is 2xx (successful)
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            if [ $retry -gt 0 ]; then
                echo "    ✅ $service_name [HTTP $http_code]: $body (succeeded after $((retry + 1)) attempts)"
            else
                echo "    ✅ $service_name [HTTP $http_code]: $body"
            fi
            return 0
        else
            retry=$((retry + 1))
            if [ $retry -lt $MAX_RETRIES ]; then
                echo "    ⏳ $service_name [HTTP $http_code] - Service not ready (attempt $retry/$MAX_RETRIES), retrying in ${wait_time}s..."
                sleep $wait_time
                wait_time=$((wait_time * 2))
                continue
            else
                echo "    ❌ $service_name [HTTP $http_code]: $body (failed after $MAX_RETRIES attempts)"
                return 1
            fi
        fi
    done

    return 1
}


# --- VERIFY ALL HOSTS ---
echo ""
echo "🔍 Starting readiness checks for ${#VMS_ALL[@]} host(s)..."
echo ""

declare -a FAILED_HOSTS=()
declare -i TOTAL_CHECKS=0
declare -i FAILED_CHECKS=0

for vm_name in "${VMS_ALL[@]}"; do
    fqdn="${vm_name}.${AZURE_VMS_LOCATION}.cloudapp.azure.com"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🖥️  Host: $fqdn"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    HOST_FAILED=false

    # Check Trento Web readyz
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if ! check_endpoint "$fqdn" "/api/readyz" "Trento Web /readyz"; then
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        HOST_FAILED=true
    fi

    # Check Trento Web healthz
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if ! check_endpoint "$fqdn" "/api/healthz" "Trento Web /healthz"; then
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        HOST_FAILED=true
    fi

    # Check Trento Wanda readyz
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if ! check_endpoint "$fqdn" "/wanda/api/readyz" "Trento Wanda /readyz"; then
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        HOST_FAILED=true
    fi

    # Check Trento Wanda healthz
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if ! check_endpoint "$fqdn" "/wanda/api/healthz" "Trento Wanda /healthz"; then
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        HOST_FAILED=true
    fi

    if [ "$HOST_FAILED" = true ]; then
        FAILED_HOSTS+=("$fqdn")
    fi

    echo ""
done

# --- SUMMARY ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Readiness Check Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total hosts checked: ${#VMS_ALL[@]}"
echo "Total checks performed: $TOTAL_CHECKS"
echo "Passed checks: $((TOTAL_CHECKS - FAILED_CHECKS))"
echo "Failed checks: $FAILED_CHECKS"
echo ""

if [ ${#FAILED_HOSTS[@]} -eq 0 ]; then
    echo "✅ All hosts are ready!"
    exit 0
else
    echo "❌ The following hosts have readiness check failures:"
    for host in "${FAILED_HOSTS[@]}"; do
        echo "  - $host"
    done
    exit 1
fi
