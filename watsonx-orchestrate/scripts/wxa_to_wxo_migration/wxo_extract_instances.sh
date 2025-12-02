#!/bin/bash
# Extract wxO instance list and IDs for mapping generation
# This script queries the wxO PostgreSQL database to get instance IDs
set -euo pipefail

print_help() {
  cat <<'EOF'
Usage:
  wxo_extract_instances.sh <NAMESPACE> [OUTPUT_FILE]

Description:
  Extracts Watson Orchestrate instance metadata from wxO PostgreSQL database.
  Generates JSON file with instance names and their tenant_ids for mapping.

Arguments:
  NAMESPACE     Namespace where Watson Orchestrate is installed
  OUTPUT_FILE   Output JSON filename (default: wxo_instances.json)

Output:
  JSON file with instance names and tenant_ids

Examples:
  # Extract from cpd namespace
  wxo_extract_instances.sh cpd

  # Extract with custom output filename
  wxo_extract_instances.sh cpd my_wxo_instances.json

Notes:
  - Requires oc CLI to be logged in to the wxO cluster
  - Only extracts non-deleted instances
  - Output is used by wxa_generate_mapping.sh
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
OUTPUT_FILE="${2:-wxo_instances.json}"

echo "=== Extracting wxO Instance List ==="
echo "Namespace: ${NAMESPACE}"
echo "Output file: ${OUTPUT_FILE}"
echo ""

# Find the postgres pod - try multiple label patterns
POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l k8s.enterprisedb.io/cluster=wo-wa-postgres-16 --no-headers 2>/dev/null | grep -E 'wo-wa-postgres-16-[0-9]+' | head -n1 | awk '{print $1}')

if [[ -z "$POSTGRES_POD" ]]; then
  # Try CrunchyData operator label
  POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l postgres-operator.crunchydata.com/cluster=wo-wa-postgres-16 --no-headers 2>/dev/null | grep -E 'wo-wa-postgres-16-[0-9]+' | head -n1 | awk '{print $1}')
fi

if [[ -z "$POSTGRES_POD" ]]; then
  # Try older naming convention with EnterpriseDB
  POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l k8s.enterprisedb.io/cluster=wo-wa-postgres --no-headers 2>/dev/null | grep -E 'wo-wa-postgres-[0-9]+' | head -n1 | awk '{print $1}')
fi

if [[ -z "$POSTGRES_POD" ]]; then
  # Try older naming convention with CrunchyData
  POSTGRES_POD=$(oc get pods -n "${NAMESPACE}" -l postgres-operator.crunchydata.com/cluster=wo-wa-postgres --no-headers 2>/dev/null | grep -E 'wo-wa-postgres-[0-9]+' | head -n1 | awk '{print $1}')
fi

if [[ -z "$POSTGRES_POD" ]]; then
  echo "❌ Error: Could not find wo-wa-postgres pod in namespace ${NAMESPACE}"
  exit 2
fi

echo "✅ Found PostgreSQL pod: ${POSTGRES_POD}"
echo ""

# Extract instance data
echo "Extracting instance metadata..."
INSTANCE_DATA=$(oc exec -n "${NAMESPACE}" "${POSTGRES_POD}" -- psql -U postgres -d conversation_pprd_wo-wa -t -A -F'|' -c \
  "SELECT tenant_id, instance_id, name, region FROM tenant WHERE deleted IS NOT TRUE ORDER BY name;")

if [[ -z "$INSTANCE_DATA" ]]; then
  echo "❌ Error: No instances found or query failed"
  exit 3
fi

# Create JSON array
echo "[" > "${OUTPUT_FILE}"
FIRST_ENTRY=true

# Process each instance
while IFS='|' read -r TENANT_ID INSTANCE_ID NAME REGION; do
  # Skip empty lines
  [[ -z "$TENANT_ID" ]] && continue
  
  # Determine display name
  if [[ "$REGION" == "monitoring" ]]; then
    DISPLAY_NAME="monitoring"
  elif [[ -z "$NAME" || "$NAME" == "null" ]]; then
    DISPLAY_NAME="bdd-test"
  else
    DISPLAY_NAME="$NAME"
  fi
  
  # Add to JSON
  if [[ "$FIRST_ENTRY" == "true" ]]; then
    FIRST_ENTRY=false
  else
    echo "," >> "${OUTPUT_FILE}"
  fi
  
  cat >> "${OUTPUT_FILE}" <<EOF
  {
    "name": "${DISPLAY_NAME}",
    "tenant_id": "${TENANT_ID}",
    "instance_id": "${INSTANCE_ID}",
    "region": "${REGION}"
  }
EOF

done <<< "$INSTANCE_DATA"

# Close JSON array
echo "" >> "${OUTPUT_FILE}"
echo "]" >> "${OUTPUT_FILE}"

# Count instances
INSTANCE_COUNT=$(grep -c '"name"' "${OUTPUT_FILE}" || true)

echo ""
echo "=== Extraction Complete ==="
echo "✅ Extracted ${INSTANCE_COUNT} instances"
echo "📄 Output file: ${OUTPUT_FILE}"
echo ""
echo "Next step:"
echo "Use this file with wxa_generate_mapping.sh to create the pgmig mapping file"


