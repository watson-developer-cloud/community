#!/bin/bash
# CPD Service Instance Deletion Script v2
# Compatible with both Linux and macOS
# Companion script to instancecreation_v2.sh
set -euo pipefail

print_help() {
  cat <<'EOF'
Usage:
  instancedeletion_v2.sh <MODE> <CPD_ROUTE> <AUTH> [USERNAME] [OPTIONS]

Description:
  Deletes CPD service instances using the /v3/service_instances API.
  If <AUTH> looks like a Bearer token, it is used as-is.
  Otherwise, <AUTH> is treated as a CPD API key or password and a Bearer token is fetched.

Modes:
  csv <CSV_FILE>           Delete instances listed in CSV file (id,service,version)
  all <SERVICE_TYPE>       Delete ALL instances of a specific service type
  single <INSTANCE_NAME>   Delete a single instance by display name

Arguments:
  MODE        Operation mode: csv, all, or single
  CPD_ROUTE   CPD base route, e.g., cpd.example.com or https://cpd.example.com
  AUTH        Either a Bearer token or a CPD API key
  USERNAME    Required if AUTH is an API key (or set CPD_USERNAME env var)

Examples:
  # Delete instances from CSV using API key
  instancedeletion_v2.sh csv instances.csv cpd.example.com <api_key> my.user

  # Delete all Watson Assistant instances
  instancedeletion_v2.sh all watson-assistant cpd.example.com <api_key> my.user

  # Delete a single instance by name
  instancedeletion_v2.sh single wa-1 cpd.example.com <api_key> my.user

  # Using an existing Bearer token
  instancedeletion_v2.sh csv instances.csv https://cpd.example.com eyJhbGciOiJIUz...

CSV format (same as creation script):
  id,service,version
  wa-1,watson-assistant,5.2.1
  wxo-1,watson-orchestrate,5.2.1

Notes:
  - TLS verification is disabled with -k. Remove -k for production with valid certs.
  - Deletion is sequential with confirmation checks.
  - Use with caution - deletions cannot be undone!
EOF
}

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Args validation
if [[ $# -lt 3 ]]; then
  echo "Error: Invalid number of arguments."
  echo "Run with --help to see usage."
  exit 1
fi

MODE="$1"
shift

# Mode-specific argument handling
case "$MODE" in
  csv)
    if [[ $# -lt 3 ]]; then
      echo "Error: csv mode requires: <CSV_FILE> <CPD_ROUTE> <AUTH> [USERNAME]"
      exit 1
    fi
    CSV_FILE="$1"
    CPD_ROUTE="$2"
    AUTH_INPUT="$3"
    USERNAME_ARG="${4:-${CPD_USERNAME:-}}"
    
    if [[ ! -f "$CSV_FILE" ]]; then
      echo "Error: CSV file not found: $CSV_FILE"
      exit 2
    fi
    ;;
  all)
    if [[ $# -lt 3 ]]; then
      echo "Error: all mode requires: <SERVICE_TYPE> <CPD_ROUTE> <AUTH> [USERNAME]"
      exit 1
    fi
    SERVICE_TYPE="$1"
    CPD_ROUTE="$2"
    AUTH_INPUT="$3"
    USERNAME_ARG="${4:-${CPD_USERNAME:-}}"
    ;;
  single)
    if [[ $# -lt 3 ]]; then
      echo "Error: single mode requires: <INSTANCE_NAME> <CPD_ROUTE> <AUTH> [USERNAME]"
      exit 1
    fi
    INSTANCE_NAME="$1"
    CPD_ROUTE="$2"
    AUTH_INPUT="$3"
    USERNAME_ARG="${4:-${CPD_USERNAME:-}}"
    ;;
  *)
    echo "Error: Invalid mode '$MODE'. Must be: csv, all, or single"
    echo "Run with --help to see usage."
    exit 1
    ;;
esac

# Normalize CPD base URL
if [[ "$CPD_ROUTE" =~ ^https?:// ]]; then
  BASE_URL="$CPD_ROUTE"
else
  BASE_URL="https://${CPD_ROUTE}"
fi

# Utility: extract JSON "token" without jq
extract_token() {
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
    echo "${auth#Bearer }"
    return 0
  fi

  if [[ -z "$user" ]]; then
    echo "Error: USERNAME is required to mint a token from API key or password."
    exit 3
  fi

  # Try API key first
  AUTH_RESP="$(curl -sk -X POST "${BASE_URL}/icp4d-api/v1/authorize" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"api_key\":\"${auth}\"}")"

  TOKEN="$(printf '%s' "$AUTH_RESP" | extract_token)"
  
  # If API key failed, try password
  if [[ -z "$TOKEN" ]]; then
    AUTH_RESP="$(curl -sk -X POST "${BASE_URL}/icp4d-api/v1/authorize" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${user}\",\"password\":\"${auth}\"}")"
    
    TOKEN="$(printf '%s' "$AUTH_RESP" | extract_token)"
  fi
  
  if [[ -z "$TOKEN" ]]; then
    echo "Error: Failed to obtain Bearer token from API key or password. Response was:"
    echo "$AUTH_RESP"
    exit 4
  fi

  echo "$TOKEN"
}

# Delete a single instance by ID
delete_instance_by_id() {
  local instance_id="$1"
  local instance_name="$2"
  
  echo "  Deleting ${instance_name} (ID: ${instance_id})..."
  echo "  URL: ${BASE_URL}/zen-data/v3/service_instances/${instance_id}"
  
  RESPONSE="$(curl -sk -w "\n%{http_code}" -X DELETE "${BASE_URL}/zen-data/v3/service_instances/${instance_id}" \
    -H "Authorization: Bearer ${BEARER_TOKEN}" 2>&1)"
  
  STATUS_CODE="$(printf '%s' "$RESPONSE" | tail -n1)"
  BODY="$(printf '%s' "$RESPONSE" | sed '$d')"
  
  echo "  HTTP Status: ${STATUS_CODE}"
  echo "  Response Body: ${BODY}"
  
  if [[ "$STATUS_CODE" == "204" || "$STATUS_CODE" == "200" ]]; then
    echo "  ✅ Deleted ${instance_name}"
    return 0
  else
    echo "  ❌ Failed to delete ${instance_name} (HTTP ${STATUS_CODE})"
    return 1
  fi
}

# Get instance ID by display name
get_instance_id_by_name() {
  local name="$1"
  
  INSTANCES="$(curl -sk -X GET "${BASE_URL}/zen-data/v3/service_instances?fetch_all_instances=true" \
    -H "Authorization: Bearer ${BEARER_TOKEN}")"
  
  # Extract ID for matching display_name (without python/jq)
  INSTANCE_ID="$(echo "$INSTANCES" | grep -o '"id":"[^"]*","display_name":"'"${name}"'"' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)"
  
  echo "$INSTANCE_ID"
}

# Get all instances of a service type
get_instances_by_service() {
  local service="$1"
  
  INSTANCES="$(curl -sk -X GET "${BASE_URL}/zen-data/v3/service_instances?addon_type=${service}&fetch_all_instances=true" \
    -H "Authorization: Bearer ${BEARER_TOKEN}")"
  
  # Try jq first, fall back to grep/sed
  if command -v jq &> /dev/null; then
    echo "$INSTANCES" | jq -r '.service_instances[]? | "\(.id):\(.display_name)"' 2>/dev/null
  else
    # Extract each service_instance object and parse id and display_name
    echo "$INSTANCES" | grep -o '{[^}]*"id":"[^"]*"[^}]*"display_name":"[^"]*"[^}]*}' | \
      sed -n 's/.*"id":"\([^"]*\)".*"display_name":"\([^"]*\)".*/\1:\2/p'
  fi
}

BEARER_TOKEN="$(get_bearer_token "$AUTH_INPUT" "$USERNAME_ARG")"
echo "✅ Authentication successful"
echo ""

TOTAL_DELETED=0
TOTAL_FAILED=0

case "$MODE" in
  csv)
    echo "=== Deleting instances from CSV: $CSV_FILE ==="
    
    # Skip header with tail -n +2
    tail -n +2 "$CSV_FILE" | while IFS=, read -r INSTANCE_ID SERVICE VERSION; do
      # Trim whitespace
      INSTANCE_ID="${INSTANCE_ID//[$'\t\r\n ']/}"
      SERVICE="${SERVICE//[$'\t\r\n ']/}"
      
      # Skip empty or comment lines
      [[ -z "${INSTANCE_ID}" ]] && continue
      [[ "${INSTANCE_ID}" =~ ^# ]] && continue
      
      echo "Looking up instance: ${INSTANCE_ID}"
      REAL_ID="$(get_instance_id_by_name "${INSTANCE_ID}")"
      
      if [[ -z "$REAL_ID" ]]; then
        echo "  ⚠️  Instance ${INSTANCE_ID} not found, skipping"
        ((TOTAL_FAILED++))
        continue
      fi
      
      if delete_instance_by_id "$REAL_ID" "$INSTANCE_ID"; then
        ((TOTAL_DELETED++))
      else
        ((TOTAL_FAILED++))
      fi
      
      # Small delay between deletions
      sleep 1
    done
    ;;
    
  all)
    echo "=== Deleting ALL instances of service type: $SERVICE_TYPE ==="
    
    # Skip warning if SKIP_WARNING env var is set
    if [[ "${SKIP_WARNING:-}" != "true" ]]; then
      echo "⚠️  WARNING: This will delete ALL instances of type ${SERVICE_TYPE}!"
      echo "Press Ctrl+C within 5 seconds to cancel..."
      sleep 5
    else
      echo "⚠️  WARNING: Proceeding with deletion (SKIP_WARNING=true)"
    fi
    
    while true; do
      INSTANCE_LIST="$(get_instances_by_service "$SERVICE_TYPE")"
      
      if [[ -z "$INSTANCE_LIST" ]]; then
        echo "✅ All instances deleted"
        break
      fi
      
      COUNT=$(echo "$INSTANCE_LIST" | wc -l | tr -d ' ')
      echo "Found ${COUNT} instances remaining..."
      
      while IFS=: read -r INSTANCE_ID INSTANCE_NAME; do
        if delete_instance_by_id "$INSTANCE_ID" "$INSTANCE_NAME"; then
          ((TOTAL_DELETED++))
        else
          ((TOTAL_FAILED++))
        fi
        sleep 1
      done <<< "$INSTANCE_LIST"
      
      echo "  Waiting 2 seconds before checking for more instances..."
      sleep 2
    done
    ;;
    
  single)
    echo "=== Deleting single instance: $INSTANCE_NAME ==="
    
    REAL_ID="$(get_instance_id_by_name "$INSTANCE_NAME")"
    
    if [[ -z "$REAL_ID" ]]; then
      echo "❌ Instance ${INSTANCE_NAME} not found"
      exit 5
    fi
    
    if delete_instance_by_id "$REAL_ID" "$INSTANCE_NAME"; then
      ((TOTAL_DELETED++))
    else
      ((TOTAL_FAILED++))
      exit 6
    fi
    ;;
esac

echo ""
echo "=== Deletion Summary ==="
echo "✅ Successfully deleted: ${TOTAL_DELETED}"
echo "❌ Failed: ${TOTAL_FAILED}"
