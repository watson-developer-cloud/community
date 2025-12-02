#!/bin/bash
# Generate pgmig mapping file for wxA to wxO migration
# Matches wxA instances to wxO instances by name
set -euo pipefail

print_help() {
  cat <<'EOF'
Usage:
  wxa_generate_mapping.sh <WXA_JSON> <WXO_JSON> [OUTPUT_FILE]

Description:
  Generates a pgmig-compatible mapping file by matching wxA and wxO instances by name.
  The mapping file is used with pgmig's -m flag during migration.

Arguments:
  WXA_JSON      JSON file from wxa_extract_instances.sh
  WXO_JSON      JSON file from wxo_extract_instances.sh
  OUTPUT_FILE   Output mapping filename (default: instance_mapping.yaml)

Output:
  YAML file in pgmig mapping format:
    instance-mappings:
      <wxa_tenant_id>: <wxo_tenant_id>

Examples:
  # Generate mapping from extracted instances
  wxa_generate_mapping.sh wxa_instances.json wxo_instances.json

  # Generate with custom output filename
  wxa_generate_mapping.sh wxa_instances.json wxo_instances.json my_mapping.yaml

Notes:
  - Requires jq to be installed
  - Matches instances by name (case-sensitive)
  - Unmapped instances will be reported as warnings
  - Special handling for monitoring and bdd-test instances
EOF
}

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Args
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Error: Invalid number of arguments."
  echo "Run with --help to see usage."
  exit 1
fi

WXA_JSON="$1"
WXO_JSON="$2"
OUTPUT_FILE="${3:-instance_mapping.yaml}"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "❌ Error: jq is required but not installed."
  echo "Install with: brew install jq (macOS) or dnf install jq (RHEL)"
  exit 2
fi

# Validate input files
if [[ ! -f "$WXA_JSON" ]]; then
  echo "❌ Error: wxA JSON file not found: $WXA_JSON"
  exit 3
fi

if [[ ! -f "$WXO_JSON" ]]; then
  echo "❌ Error: wxO JSON file not found: $WXO_JSON"
  exit 4
fi

echo "=== Generating pgmig Mapping File ==="
echo "wxA instances: ${WXA_JSON}"
echo "wxO instances: ${WXO_JSON}"
echo "Output file: ${OUTPUT_FILE}"
echo ""

# Create YAML header
cat > "${OUTPUT_FILE}" <<EOF
# pgmig instance mapping file
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Format: wxa_instance_id: wxo_instance_id
instance-mappings:
EOF

# Track statistics
MAPPED_COUNT=0
UNMAPPED_COUNT=0
UNMAPPED_INSTANCES=()

# Read wxA instances and find matching wxO instances
while read -r wxa_entry; do
  WXA_INSTANCE_ID=$(echo "$wxa_entry" | jq -r '.wxa_instance_id')
  WXA_NAME=$(echo "$wxa_entry" | jq -r '.wxo_name')
  
  # Find matching wxO instance by name
  WXO_INSTANCE_ID=$(jq -r --arg name "$WXA_NAME" '.[] | select(.name == $name) | .instance_id' "$WXO_JSON" | head -n1)
  
  if [[ -n "$WXO_INSTANCE_ID" && "$WXO_INSTANCE_ID" != "null" ]]; then
    # Add mapping
    echo "  ${WXA_INSTANCE_ID}: ${WXO_INSTANCE_ID}" >> "${OUTPUT_FILE}"
    echo "✅ Mapped: ${WXA_NAME} (${WXA_INSTANCE_ID} -> ${WXO_INSTANCE_ID})"
    ((MAPPED_COUNT++))
  else
    echo "⚠️  Unmapped: ${WXA_NAME} (${WXA_INSTANCE_ID}) - no matching wxO instance found"
    UNMAPPED_INSTANCES+=("${WXA_NAME}")
    ((UNMAPPED_COUNT++))
  fi
done < <(jq -c '.[]' "$WXA_JSON")

echo ""
echo "=== Mapping Generation Complete ==="
echo "✅ Successfully mapped: ${MAPPED_COUNT} instances"
if [[ $UNMAPPED_COUNT -gt 0 ]]; then
  echo "⚠️  Unmapped instances: ${UNMAPPED_COUNT}"
  echo ""
  echo "Unmapped instances:"
  for instance in "${UNMAPPED_INSTANCES[@]}"; do
    echo "  - ${instance}"
  done
  echo ""
  echo "⚠️  WARNING: Unmapped instances will need manual mapping during pgmig execution"
fi
echo ""
echo "📄 Mapping file: ${OUTPUT_FILE}"
echo ""
echo "Next step:"
echo "Use this mapping file with pgmig:"
echo "  ./pgmig --resourceController resourceController.yaml \\"
echo "          --target postgres.yaml \\"
echo "          --source store.dump_YYYYMMDD-HHMMSS \\"
echo "          --wxo --force -m ${OUTPUT_FILE}"


