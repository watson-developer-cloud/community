#!/bin/bash
# Extract wxA instance list for migration to wxO
# This script connects to wxA PostgreSQL and extracts instance metadata
set -euo pipefail

print_help() {
  cat <<'EOF'
Usage:
  wxa_extract_instances.sh <NAMESPACE> [OUTPUT_FILE]

Description:
  Extracts Watson Assistant instance metadata from wxA PostgreSQL database.
  Generates two files:
  1. CSV file for creating wxO instances (compatible with instancecreation_v2.sh)
  2. JSON file with full metadata for mapping generation

Arguments:
  NAMESPACE     Namespace where Watson Assistant is installed
  OUTPUT_FILE   Base name for output files (default: wxa_instances)

Output Files:
  <OUTPUT_FILE>.csv       - CSV format for instance creation
  <OUTPUT_FILE>.json      - JSON format with full metadata including tenant_id

Examples:
  # Extract from cpd namespace
  wxa_extract_instances.sh cpd

  # Extract with custom output filename
  wxa_extract_instances.sh cpd my_migration

Notes:
  - Requires oc CLI to be logged in to the wxA cluster
  - Only extracts non-deleted instances
  - Automatically handles monitoring and regular instances
  - Includes special handling for bdd-test instance
EOF
}

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Args
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Error: Invalid number of arguments."
  echo "Run with --help to see usage."
  exit 1
fi

NAMESPACE="$1"
OUTPUT_BASE="${2:-wxa_instances}"
CSV_FILE="${OUTPUT_BASE}.csv"
JSON_FILE="${OUTPUT_BASE}.json"

echo "=== Extracting wxA Instance List ==="
echo "Namespace: ${NAMESPACE}"
echo "Output files: ${CSV_FILE}, ${JSON_FILE}"
echo ""

# Find the postgres pod - try multiple label patterns
POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l k8s.enterprisedb.io/cluster=wa-postgres-16 --no-headers 2>/dev/null | grep -E 'wa-postgres-16-[0-9]+' | head -n1 | awk '{print $1}')

if [[ -z "$POSTGRES_POD" ]]; then
  # Try CrunchyData operator label
  POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l postgres-operator.crunchydata.com/cluster=wa-postgres-16 --no-headers 2>/dev/null | grep -E 'wa-postgres-16-[0-9]+' | head -n1 | awk '{print $1}')
fi

if [[ -z "$POSTGRES_POD" ]]; then
  # Try older naming convention with EnterpriseDB
  POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l k8s.enterprisedb.io/cluster=wa-postgres --no-headers 2>/dev/null | grep -E 'wa-postgres-[0-9]+' | head -n1 | awk '{print $1}')
fi

if [[ -z "$POSTGRES_POD" ]]; then
  # Try older naming convention with CrunchyData
  POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l postgres-operator.crunchydata.com/cluster=wa-postgres --no-headers 2>/dev/null | grep -E 'wa-postgres-[0-9]+' | head -n1 | awk '{print $1}')
fi

if [[ -z "$POSTGRES_POD" ]]; then
  echo "❌ Error: Could not find wa-postgres pod in namespace ${NAMESPACE}"
  exit 2
fi

echo "✅ Found PostgreSQL pod: ${POSTGRES_POD}"
echo ""

# Extract instance data as JSON
echo "Extracting instance metadata..."
INSTANCE_DATA=$(oc exec -n "${NAMESPACE}" "${POSTGRES_POD}" -- psql -U postgres -d conversation_pprd_wa -t -A -F'|' -c \
  "SELECT tenant_id, instance_id, name, region FROM tenant WHERE deleted IS NOT TRUE ORDER BY CASE WHEN region = 'monitoring' THEN 0 ELSE 1 END, name;")

if [[ -z "$INSTANCE_DATA" ]]; then
  echo "❌ Error: No instances found or query failed"
  exit 3
fi

# Create CSV header
echo "id,service,version" > "${CSV_FILE}"

# Create JSON array
echo "[" > "${JSON_FILE}"
FIRST_ENTRY=true

# Process each instance
while IFS='|' read -r TENANT_ID INSTANCE_ID NAME REGION; do
  # Skip empty lines
  [[ -z "$TENANT_ID" ]] && continue
  
  # Skip System region instances (as per migration guide step 13)
  if [[ "$REGION" == "System" || "$REGION" == "system" ]]; then
    continue
  fi
  
  # Determine instance name for wxO
  if [[ "$REGION" == "monitoring" ]]; then
    WXO_NAME="monitoring"
  elif [[ -z "$NAME" || "$NAME" == "null" ]]; then
    # Handle unnamed instances - could be bdd-test
    WXO_NAME="bdd-test"
  else
    WXO_NAME="$NAME"
  fi
  
  # Determine service type based on instance name
  if [[ "$WXO_NAME" == "wxo-assistant-de" ]]; then
    SERVICE_TYPE="assistant"
  else
    SERVICE_TYPE="orchestrate"
  fi
  
  # Add to CSV
  echo "${WXO_NAME},${SERVICE_TYPE},5.2.2" >> "${CSV_FILE}"
  
  # Add to JSON with metadata
  if [[ "$FIRST_ENTRY" == "true" ]]; then
    FIRST_ENTRY=false
  else
    echo "," >> "${JSON_FILE}"
  fi
  
  cat >> "${JSON_FILE}" <<EOF
  {
    "wxa_tenant_id": "${TENANT_ID}",
    "wxa_instance_id": "${INSTANCE_ID}",
    "wxa_name": "${NAME}",
    "wxa_region": "${REGION}",
    "wxo_name": "${WXO_NAME}"
  }
EOF

done <<< "$INSTANCE_DATA"

# Close JSON array
echo "" >> "${JSON_FILE}"
echo "]" >> "${JSON_FILE}"

# Count instances
INSTANCE_COUNT=$(grep -c "^[^id]" "${CSV_FILE}" || true)

echo ""
echo "=== Extraction Complete ==="
echo "✅ Extracted ${INSTANCE_COUNT} instances"
echo "📄 CSV file: ${CSV_FILE}"
echo "📄 JSON file: ${JSON_FILE}"
echo ""
echo "Next steps:"
echo "1. Review the generated files"
echo "2. Use ${CSV_FILE} with instancecreation_v2.sh to create wxO instances"
echo "3. Use ${JSON_FILE} with wxa_generate_mapping.sh to create pgmig mapping file"


