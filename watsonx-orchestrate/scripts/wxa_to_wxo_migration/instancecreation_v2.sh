#!/bin/bash
# CPD Service Instance Creation Script v2
# Compatible with both Linux and macOS
# https://www.ibm.com/docs/en/cloud-paks/cp-data/4.8.x?topic=apis-generating-api-auth-token
# https://www.ibm.com/docs/en/cloud-paks/cp-data/4.8.x?topic=token-generating-bearer
set -euo pipefail

print_help() {
  cat <<'EOF'
Usage:
  instancecreation_v2.sh <CSV_FILE> <NAMESPACE> <CPD_ROUTE> <AUTH> [USERNAME]

Description:
  Creates CPD service instances from a CSV using the /v3/service_instances API.
  If <AUTH> looks like a Bearer token, it is used as-is.
  Otherwise, <AUTH> is treated as a CPD API key and a Bearer token is fetched
  using /icp4d-api/v1/authorize with the provided [USERNAME] or $CPD_USERNAME.

Arguments:
  CSV_FILE    Path to CSV file with format: id,service,version (header required)
  NAMESPACE   Namespace where service instances will be created
  CPD_ROUTE   CPD base route, for example cpd.example.com or https://cpd.example.com
  AUTH        Either a Bearer token, or a CPD API key
  USERNAME    Required if AUTH is an API key (or set CPD_USERNAME env var)

Examples:
  # Using API key (username provided)
  instancecreation_v2.sh instances.csv cpd cpd.example.com <api_key> my.user

  # Using API key (username via env)
  CPD_USERNAME=my.user instancecreation_v2.sh instances.csv cpd cpd.example.com <api_key>

  # Using an existing Bearer token
  instancecreation_v2.sh instances.csv cpd https://cpd.example.com eyJhbGciOiJIUz...

CSV format:
  id,service,version
  wa-1,assistant,5.2.2
  wxo-1,orchestrate,5.2.2

Notes:
  - TLS verification is disabled with -k. Remove -k for production with valid certs.
  - Adjust create_arguments if your service requires extra parameters.
  - Instances are created sequentially with readiness checks between each creation.
EOF
}

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Args
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "Error: Invalid number of arguments."
  echo "Run with --help to see usage."
  exit 1
fi

CSV_FILE="$1"
NAMESPACE="$2"
CPD_ROUTE="$3"
AUTH_INPUT="$4"
USERNAME_ARG="${5:-${CPD_USERNAME:-}}"

# Normalize CPD base URL
if [[ "$CPD_ROUTE" =~ ^https?:// ]]; then
  BASE_URL="$CPD_ROUTE"
else
  BASE_URL="https://${CPD_ROUTE}"
fi

# Validate CSV
if [[ ! -f "$CSV_FILE" ]]; then
  echo "Error: CSV file not found: $CSV_FILE"
  exit 2
fi

# Utility: extract JSON "token" without jq
extract_token() {
  # Reads JSON on stdin and prints the value of "token"
  sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Heuristic to check if AUTH_INPUT is already a token
looks_like_token() {
  local s="$1"
  if [[ "$s" == Bearer\ * ]]; then
    return 0
  elif [[ "$s" == *.*.* ]]; then
    return 0
  elif [[ ${#s} -ge 80 ]]; then
    return 0
  fi
  return 1
}

# Get or normalize Bearer token
get_bearer_token() {
  local auth="$1"
  local user="$2"

  if looks_like_token "$auth"; then
    # Strip optional leading "Bearer "
    echo "${auth#Bearer }"
    return 0
  fi

  # Treat as API key; need username
  if [[ -z "$user" ]]; then
    echo "Error: USERNAME is required to mint a token from API key. Provide [USERNAME] arg or set CPD_USERNAME."
    exit 3
  fi

  # Obtain token using API key and username
  AUTH_RESP="$(curl -sk -X POST "${BASE_URL}/icp4d-api/v1/authorize" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"api_key\":\"${auth}\"}")"

  TOKEN="$(printf '%s' "$AUTH_RESP" | extract_token)"
  if [[ -z "$TOKEN" ]]; then
    echo "Error: Failed to obtain Bearer token from API key. Response was:"
    echo "$AUTH_RESP"
    exit 4
  fi

  echo "$TOKEN"
}

# Wait for instance to be ready
wait_for_instance() {
  local instance_name="$1"
  local max_wait=1800  # 30 minutes
  local interval=30    # Check every 30 seconds
  local elapsed=0
  
  echo "  Waiting for instance ${instance_name} to be ready..."
  
  while [ $elapsed -lt $max_wait ]; do
    # Get instance status
    INSTANCE_STATUS=$(curl -sk -X GET "${BASE_URL}/zen-data/v3/service_instances?addon_type=${SERVICE}&display_name=${instance_name}" \
      -H "Authorization: Bearer ${BEARER_TOKEN}" 2>/dev/null | \
      sed -n 's/.*"provision_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    
    if [[ "$INSTANCE_STATUS" == "Completed" || "$INSTANCE_STATUS" == "Ready" || "$INSTANCE_STATUS" == "PROVISIONED" ]]; then
      echo "  ✅ Instance ${instance_name} is ready (Status: ${INSTANCE_STATUS})"
      return 0
    elif [[ "$INSTANCE_STATUS" == "Failed" || "$INSTANCE_STATUS" == "FAILED" ]]; then
      echo "  ❌ Instance ${instance_name} failed to provision"
      return 1
    fi
    
    echo "  ⏳ Instance ${instance_name} status: ${INSTANCE_STATUS:-Provisioning} (${elapsed}s elapsed)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  echo "  ⚠️  Timeout waiting for instance ${instance_name} (${max_wait}s)"
  return 1
}

BEARER_TOKEN="$(get_bearer_token "$AUTH_INPUT" "$USERNAME_ARG")"

# Main loop: create instances from CSV
# Skip header with tail -n +2
tail -n +2 "$CSV_FILE" | while IFS=, read -r INSTANCE_ID SERVICE VERSION; do
  # Trim whitespace
  INSTANCE_ID="${INSTANCE_ID//[$'\t\r\n ']/}"
  SERVICE="${SERVICE//[$'\t\r\n ']/}"
  VERSION="${VERSION//[$'\t\r\n ']/}"

  # Skip empty or comment lines
  [[ -z "${INSTANCE_ID}" ]] && continue
  [[ "${INSTANCE_ID}" =~ ^# ]] && continue

  echo "Creating instance: ${INSTANCE_ID} (Service: ${SERVICE}, Version: ${VERSION})"

  PAYLOAD_FILE="payload-${INSTANCE_ID}.json"
  
  # Build payload based on service type
  if [[ "$SERVICE" == "orchestrate" ]]; then
    # For orchestrate, include create_arguments with only parameters
    cat > "$PAYLOAD_FILE" <<EOF
{
  "addon_type": "$SERVICE",
  "display_name": "$INSTANCE_ID",
  "description": "",
  "addon_version": "$VERSION",
  "namespace": "$NAMESPACE",
  "create_arguments": {
    "parameters": {}
  }
}
EOF
  else
    # For assistant and other services, include create_arguments with namespace-wa deployment_id
    cat > "$PAYLOAD_FILE" <<EOF
{
  "addon_type": "$SERVICE",
  "display_name": "$INSTANCE_ID",
  "description": "",
  "addon_version": "$VERSION",
  "namespace": "$NAMESPACE",
  "create_arguments": {
    "deployment_id": "${NAMESPACE}-wa",
    "parameters": {}
  }
}
EOF
  fi

  RESPONSE="$(curl -sk -w "\n%{http_code}" -X POST "${BASE_URL}/zen-data/v3/service_instances" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")"

  BODY="$(printf '%s' "$RESPONSE" | sed '$d')"
  STATUS_CODE="$(printf '%s' "$RESPONSE" | tail -n1)"

  if [[ "$STATUS_CODE" == "201" || "$STATUS_CODE" == "200" ]]; then
    echo "✅ Created instance ${INSTANCE_ID} (HTTP ${STATUS_CODE})"
    
    # Wait for instance to be ready before proceeding
    if ! wait_for_instance "${INSTANCE_ID}"; then
      echo "⚠️  Warning: Instance ${INSTANCE_ID} may not be fully ready, but continuing..."
    fi
  else
    echo "❌  Failed to create ${INSTANCE_ID} (HTTP ${STATUS_CODE})"
    echo "$BODY"
  fi
done
