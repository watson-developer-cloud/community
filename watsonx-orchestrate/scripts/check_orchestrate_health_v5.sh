#!/bin/sh
#
# watsonx Orchestrate Health Check Script with Troubleshoot Mode
#
# Copyright 2026 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: Manu Thapar
#
# SUMMARY:
# Comprehensive health check and troubleshooting tool for watsonx Orchestrate on OpenShift.
# Supports standard health checks and an interactive troubleshoot mode for detailed diagnostics.
#
# FEATURES:
#  - Troubleshoot Mode (--troubleshoot flag):
#    * Interactive pod remediation with 7 options
#    * List errors in failing pods or ALL Orchestrate pods
#    * Delete pods with optional log backup
#    * Customizable time period for error analysis (1m-24h)
#    * 30-second auto-skip timeout
#    * Shows termination reasons for restarting pods
#    * Excludes INFO-level logs from error output
#
#  - Edition Detection:
#    * Supports agentic, agentic_assistant, agentic_skills_assistant
#    * Detects via wo.spec.wxolite.enabled, spec hints, and heuristics
#    * Knative Brokers and Triggers health checks for agentic editions
#
#  - Health Checks:
#    * Autodetect namespaces (OPERATORS and OPERANDS)
#    * Verify all wo-* pods are Completed or fully Running
#    * Check Custom Resources (individually toggleable)
#    * Check datastores: EDB Postgres, Kafka, Redis, WXD engines, OBC
#    * Check Orchestrate and Assistant jobs
#
#  - Behavior:
#    * Runs troubleshoot mode first (if enabled), then continues with health checks
#    * Retries up to MAX_TRIES (default: 40) with SLEEP_SECS (default: 15) between attempts
#    * Exits 0 on first successful pass where all enabled checks are healthy
#    * Exits 1 if max tries exhausted without passing all checks
#
# USAGE:
#  ./check_orchestrate_health_v4.sh [OPTIONS]
#
#  Options:
#    --troubleshoot              Enable troubleshoot mode with interactive remediation
#    -c, --config                Enable configuration mode to modify WO CR settings
#    -n, --namespace NAMESPACE   Override operands namespace
#    --assume-agentic            Assume agentic edition
#    --assume-agentic-skills     Assume agentic_skills_assistant edition
#    -y, --yes                   Bypass troubleshoot mode warning prompt
#    -h, --help                  Show help message

set -eu

# ------------------------- Tunables -------------------------
: "${MAX_TRIES:=40}"
: "${SLEEP_SECS:=15}"
OVERRIDE_NS="${OVERRIDE_NS:-}"

# Edition detection controls
: "${DETECT_EDITION:=1}"
ASSUME_EDITION=""

# Enable or disable individual checks 1 enable, 0 disable
: "${CHECK_WO_PODS:=1}"
: "${CHECK_WO_CR:=1}"
: "${CHECK_WOCS:=1}"
: "${CHECK_WA_CR:=1}"
: "${CHECK_IFM_CR:=1}"
: "${CHECK_DOCPROC:=1}"
: "${CHECK_DE:=1}"
: "${CHECK_UAB_ADS:=1}"
: "${CHECK_EDB:=1}"
: "${CHECK_KAFKA:=1}"
: "${CHECK_REDIS:=1}"
: "${CHECK_WXD:=1}"
: "${CHECK_OBC:=1}"
: "${CHECK_JOBS:=1}"
: "${CHECK_KNATIVE_EVENTING:=1}"

# Troubleshoot mode - disabled by default
: "${TROUBLESHOOT_MODE:=0}"
# Configuration mode - disabled by default
: "${CONFIG_MODE:=0}"
# Skip troubleshoot warning prompt - disabled by default
: "${SKIP_WARNING:=0}"
# Debug mode - disabled by default
: "${DEBUG_MODE:=0}"
: "${USER_INPUT_TIMEOUT:=20}"  # Timeout in seconds for user input prompts

# Log noise patterns to exclude from error output (one grep -v per pattern)
# These are known harmless messages that match error keywords but are not actionable
LOG_NOISE_PATTERNS='
Background saving terminated with success
WXO Session cookie missing
Bearer token not found in the request header
import job stats
import task stats
try remove empty sealed segment
mkdir -p failed.*matplotlib
Fontconfig error.*writable cache
Timeout on acquiring lock.*leader.lock
sasl\.login\.read\.timeout\.ms
sasl\.login\.connect\.timeout\.ms
socket\.connection\.setup\.timeout
default\.api\.timeout\.ms
request\.timeout\.ms
instana-agent.*Metadata update failed
Timed out waiting for a node assignment.*fetchMetadata
No pods or no unique pods available to load
client_idle_timeout
'

# ---------------------- Arg parsing -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) OVERRIDE_NS="$2"; shift 2 ;;
    --assume-agentic)  ASSUME_EDITION="agentic"; shift 1 ;;
    --assume-agentic-skills)  ASSUME_EDITION="agentic_skills_assistant"; shift 1 ;;
    -t|--troubleshoot) TROUBLESHOOT_MODE=1; shift 1 ;;
    -c|--config) CONFIG_MODE=1; shift 1 ;;
    -y|--yes) SKIP_WARNING=1; shift 1 ;;
    -d|--debug) DEBUG_MODE=1; shift 1 ;;
    -h|--help) sed -n '1,220p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ------------------------ Utilities -------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
OC="oc"

print_rule() { echo "------------------------------------------------------------"; }

# Build a combined regex from LOG_NOISE_PATTERNS for grep -vE filtering
build_noise_regex() {
  echo "$LOG_NOISE_PATTERNS" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | paste -sd'|' -
}
LOG_NOISE_REGEX=$(build_noise_regex)

get_wo_models_info() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  
  if [ -z "$wo_name" ]; then
    echo "    Size: N/A (WO CR not found)"
    echo "    HPA Enabled: N/A"
    echo "    IFM Enabled: N/A"
    return
  fi
  
  # Get overall size - default to "medium" if not set
  wo_size=`$OCN get wo "$wo_name" -o jsonpath='{.spec.size}' 2>/dev/null || :`
  if [ -n "$wo_size" ]; then
    echo "    Size: $wo_size"
  else
    echo "    Size: medium"
  fi
  
  # Get HPA configuration - default to false (disabled) if not set
  hpa_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.autoScaleConfig}' 2>/dev/null || :`
  case "$(echo "${hpa_enabled:-}" | tr '[:upper:]' '[:lower:]')" in
    true) echo "    HPA Enabled: true" ;;
    *) echo "    HPA Enabled: false" ;;
  esac
  
  # Check if IFM is enabled
  ifm_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.enable_ifm}' 2>/dev/null || :`
  case "$(echo "${ifm_enabled:-}" | tr '[:upper:]' '[:lower:]')" in
    true)
      echo "    IFM Enabled: true"
      ;;
    false)
      echo "    IFM Enabled: false"
      return
      ;;
    *)
      echo "    IFM Enabled: false"
      return
      ;;
  esac
  
  # Only list models if IFM is enabled
  # Get models from wxolite.ifm.model_config
  models_json=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.ifm.model_config}' 2>/dev/null || :`
  
  if [ -z "$models_json" ] || [ "$models_json" = "{}" ] || [ "$models_json" = "null" ]; then
    echo "    Models: None configured"
    return
  fi
  
  echo "    Models configured:"
  
  # Parse the nested model_config structure
  # Structure is: model_config -> model_type -> model_name -> {replicas, shards}
  tmp_models=`mktemp 2>/dev/null || echo "/tmp/wo_models.$$"`
  
  # Get all model types and models
  $OCN get wo "$wo_name" -o json 2>/dev/null | \
    awk '
      BEGIN { in_model_config=0; model_type=""; model_name=""; indent=0 }
      /"model_config"[[:space:]]*:/ { in_model_config=1; next }
      in_model_config {
        # Track nesting level by counting braces
        if ($0 ~ /{/) indent++
        if ($0 ~ /}/) {
          indent--
          if (indent <= 1) { in_model_config=0; next }
        }
        
        # Match model type (first level under model_config)
        if (indent == 2 && $0 ~ /"[^"]+"\s*:\s*{/) {
          match($0, /"([^"]+)"/, arr)
          model_type = arr[1]
        }
        
        # Match model name (second level)
        if (indent == 3 && $0 ~ /"[^"]+"\s*:\s*{/) {
          match($0, /"([^"]+)"/, arr)
          model_name = arr[1]
        }
        
        # Match replicas
        if (model_name != "" && $0 ~ /"replicas"/) {
          match($0, /:\s*([0-9]+)/, arr)
          replicas = arr[1]
        }
        
        # Match shards
        if (model_name != "" && $0 ~ /"shards"/) {
          match($0, /:\s*([0-9]+)/, arr)
          shards = arr[1]
          # Print when we have all info
          if (model_type != "" && model_name != "") {
            print model_type "|" model_name "|" replicas "|" shards
            model_name = ""
            replicas = ""
            shards = ""
          }
        }
      }
    ' > "$tmp_models" 2>/dev/null || :
  
  if [ -s "$tmp_models" ]; then
    while IFS='|' read -r mtype mname replicas shards; do
      [ -z "$mname" ] && continue
      replica_info="${replicas:-default}"
      shard_info="${shards:-default}"
      echo "      - ${mtype}/${mname}: replicas=${replica_info}, shards=${shard_info}"
    done < "$tmp_models"
  else
    echo "      (Unable to parse model configuration)"
  fi
  
  rm -f "$tmp_models"
}

# ==================== Configuration Mode Functions ====================

# Function to display current WO CR configuration
show_current_config() {
  local wo_name="$1"
  local ns="$2"
  
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    Current WO CR Configuration                               ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Get size
  local size=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.size}' 2>/dev/null || echo "medium")
  echo "  1. Size: ${size:-medium}"
  
  # Get HPA status
  local hpa=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.autoScaleConfig}' 2>/dev/null || echo "false")
  echo "  2. HPA (autoScaleConfig): $hpa"
  
  # Get DocProc status
  local docproc=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.docproc.enabled}' 2>/dev/null || echo "not set")
  echo "  3. DocProc Enabled: $docproc"
  
  # Get image digest overrides
  echo "  4. Image Digest Overrides:"
  local digests=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.image.digestOverrides}' 2>/dev/null)
  if [ -z "$digests" ] || [ "$digests" = "{}" ] || [ "$digests" = "null" ]; then
    echo "     None configured"
  else
    $OC -n "$ns" get wo "$wo_name" -o json 2>/dev/null | \
      jq -r '.spec.image.digestOverrides // {} | to_entries[] | "     - \(.key): \(.value)"' 2>/dev/null || echo "     (Unable to parse)"
  fi
  
  # Get sizeMapping (component-specific replicas and resources)
  echo "  5. Component Size Mappings (sizeMapping):"
  local sizemapping=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.sizeMapping}' 2>/dev/null)
  if [ -z "$sizemapping" ] || [ "$sizemapping" = "{}" ] || [ "$sizemapping" = "null" ]; then
    echo "     None configured (using defaults from size)"
  else
    $OC -n "$ns" get wo "$wo_name" -o json 2>/dev/null | \
      jq -r '.spec.sizeMapping // {} | to_entries[] | "     - \(.key):\n       replicas: \(.value.replicas // "not set")\n       resources: \(if .value.resources then "configured" else "not set" end)"' 2>/dev/null || echo "     (Unable to parse)"
  fi
  
  echo ""
}

# Function to modify size
modify_size() {
  local wo_name="$1"
  local ns="$2"
  
  # Get current size (empty if not set, which means default "medium")
  local current_size=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.size}' 2>/dev/null || echo "")
  
  echo ""
  echo "Available sizes: starter, small_mincpureq, small, medium, large"
  if [ -z "$current_size" ]; then
    echo "Current size: medium (default - not explicitly set)"
  else
    echo "Current size: $current_size"
  fi
  echo -n "Enter new size (or 'cancel' to skip): "
  read -r new_size
  
  if [ "$new_size" = "cancel" ] || [ -z "$new_size" ]; then
    echo "Skipped."
    return
  fi
  
  case "$new_size" in
    starter|small_mincpureq|small|medium|large)
      # Check if already set to the desired value
      if [ "$new_size" = "$current_size" ]; then
        echo "ℹ️  Size is already set to: $new_size. No changes needed."
      elif [ -z "$current_size" ] && [ "$new_size" = "medium" ]; then
        echo "ℹ️  Size is already medium (default). No changes needed."
      else
        echo "Updating size to: $new_size"
        $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"size\":\"$new_size\"}}"
        echo "✓ Size updated successfully"
      fi
      ;;
    *)
      echo "❌ Invalid size. Must be one of: starter, small_mincpureq, small, medium, large"
      ;;
  esac
}

# Function to toggle HPA
modify_hpa() {
  local wo_name="$1"
  local ns="$2"
  
  # Get current HPA setting (empty if not set, which means HPA is disabled/false by default)
  local current=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.autoScaleConfig}' 2>/dev/null || echo "")
  
  echo ""
  if [ -z "$current" ]; then
    echo "Current HPA (autoScaleConfig): false (default - not explicitly set)"
  else
    echo "Current HPA (autoScaleConfig): $current"
  fi
  echo -n "Enable HPA? (true/false or 'cancel' to skip): "
  read -r new_hpa
  
  if [ "$new_hpa" = "cancel" ] || [ -z "$new_hpa" ]; then
    echo "Skipped."
    return
  fi
  
  case "$new_hpa" in
    true|false)
      # Check if already set to the desired value
      if [ "$new_hpa" = "$current" ]; then
        echo "ℹ️  HPA is already set to: $new_hpa. No changes needed."
      elif [ -z "$current" ] && [ "$new_hpa" = "false" ]; then
        echo "ℹ️  HPA is already disabled (default). No changes needed."
      else
        echo "Updating HPA to: $new_hpa"
        $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"autoScaleConfig\":$new_hpa}}"
        echo "✓ HPA updated successfully"
      fi
      ;;
    *)
      echo "❌ Invalid value. Must be 'true' or 'false'"
      ;;
  esac
}

# Function to toggle DocProc
modify_docproc() {
  local wo_name="$1"
  local ns="$2"
  
  local current=$($OC -n "$ns" get wo "$wo_name" -o jsonpath='{.spec.docproc.enabled}' 2>/dev/null || echo "not set")
  
  echo ""
  echo "Current DocProc enabled: $current"
  echo -n "Enable DocProc? (true/false or 'cancel' to skip): "
  read -r new_docproc
  
  if [ "$new_docproc" = "cancel" ] || [ -z "$new_docproc" ]; then
    echo "Skipped."
    return
  fi
  
  case "$new_docproc" in
    true|false)
      echo "Updating DocProc to: $new_docproc"
      $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"docproc\":{\"enabled\":$new_docproc}}}"
      echo "✓ DocProc updated successfully"
      ;;
    *)
      echo "❌ Invalid value. Must be 'true' or 'false'"
      ;;
  esac
}

# Function to add/modify image digest
modify_image_digest() {
  local wo_name="$1"
  local ns="$2"
  
  echo ""
  echo "Image Digest Override Management"
  echo "--------------------------------"
  echo "1. Add/Update digest override"
  echo "2. Remove digest override"
  echo "3. Cancel"
  echo -n "Select option (1-3): "
  read -r digest_option
  
  case "$digest_option" in
    1)
      echo -n "Enter image name (e.g., wo-ui): "
      read -r image_name
      if [ -z "$image_name" ]; then
        echo "❌ Image name cannot be empty"
        return
      fi
      
      echo -n "Enter digest (e.g., sha256:abc123...): "
      read -r digest_value
      if [ -z "$digest_value" ]; then
        echo "❌ Digest cannot be empty"
        return
      fi
      
      echo "Adding/Updating digest override for $image_name"
      $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"image\":{\"digestOverrides\":{\"$image_name\":\"$digest_value\"}}}}"
      echo "✓ Digest override updated successfully"
      ;;
    2)
      echo -n "Enter image name to remove: "
      read -r image_name
      if [ -z "$image_name" ]; then
        echo "❌ Image name cannot be empty"
        return
      fi
      
      echo "Removing digest override for $image_name"
      $OC -n "$ns" patch wo "$wo_name" --type=json -p "[{\"op\":\"remove\",\"path\": \"/spec/image/digestOverrides/$image_name\"}]" 2>/dev/null
      echo "✓ Digest override removed (if it existed)"
      ;;
    3|*)
      echo "Cancelled."
      ;;
  esac
}

# Function to modify component replicas and resources
modify_component_sizing() {
  local wo_name="$1"
  local ns="$2"
  
  echo ""
  echo "Component Sizing (sizeMapping) Management"
  echo "----------------------------------------"
  echo "This allows you to override replicas and resources for specific components."
  echo ""
  echo -n "Enter component name (e.g., wo-ui, wo-api, or 'cancel' to skip): "
  read -r component_name
  
  if [ "$component_name" = "cancel" ] || [ -z "$component_name" ]; then
    echo "Skipped."
    return
  fi
  
  echo ""
  echo "What would you like to modify for $component_name?"
  echo "1. Replicas"
  echo "2. Resources (CPU/Memory)"
  echo "3. Both"
  echo "4. Remove component override"
  echo "5. Cancel"
  echo -n "Select option (1-5): "
  read -r sizing_option
  
  case "$sizing_option" in
    1)
      echo -n "Enter number of replicas: "
      read -r replicas
      if [ -z "$replicas" ] || ! [ "$replicas" -eq "$replicas" ] 2>/dev/null; then
        echo "❌ Invalid replicas value"
        return
      fi
      
      echo "Updating replicas for $component_name to $replicas"
      $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"sizeMapping\":{\"$component_name\":{\"replicas\":$replicas}}}}"
      echo "✓ Replicas updated successfully"
      ;;
    2)
      echo ""
      echo "Resource configuration (leave empty to skip):"
      echo -n "CPU request (e.g., 100m, 1): "
      read -r cpu_req
      echo -n "CPU limit (e.g., 500m, 2): "
      read -r cpu_lim
      echo -n "Memory request (e.g., 256Mi, 1Gi): "
      read -r mem_req
      echo -n "Memory limit (e.g., 512Mi, 2Gi): "
      read -r mem_lim
      
      # Build resources JSON
      local resources_json="{"
      local has_requests=false
      local has_limits=false
      
      if [ -n "$cpu_req" ] || [ -n "$mem_req" ]; then
        has_requests=true
        resources_json="$resources_json\"requests\":{"
        [ -n "$cpu_req" ] && resources_json="$resources_json\"cpu\":\"$cpu_req\","
        [ -n "$mem_req" ] && resources_json="$resources_json\"memory\":\"$mem_req\","
        resources_json="${resources_json%,}}"
      fi
      
      if [ -n "$cpu_lim" ] || [ -n "$mem_lim" ]; then
        has_limits=true
        [ "$has_requests" = true ] && resources_json="$resources_json,"
        resources_json="$resources_json\"limits\":{"
        [ -n "$cpu_lim" ] && resources_json="$resources_json\"cpu\":\"$cpu_lim\","
        [ -n "$mem_lim" ] && resources_json="$resources_json\"memory\":\"$mem_lim\","
        resources_json="${resources_json%,}}"
      fi
      
      resources_json="$resources_json}"
      
      if [ "$has_requests" = false ] && [ "$has_limits" = false ]; then
        echo "❌ No resources specified"
        return
      fi
      
      echo "Updating resources for $component_name"
      $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"sizeMapping\":{\"$component_name\":{\"resources\":$resources_json}}}}"
      echo "✓ Resources updated successfully"
      ;;
    3)
      echo -n "Enter number of replicas: "
      read -r replicas
      if [ -z "$replicas" ] || ! [ "$replicas" -eq "$replicas" ] 2>/dev/null; then
        echo "❌ Invalid replicas value"
        return
      fi
      
      echo ""
      echo "Resource configuration (leave empty to skip):"
      echo -n "CPU request (e.g., 100m, 1): "
      read -r cpu_req
      echo -n "CPU limit (e.g., 500m, 2): "
      read -r cpu_lim
      echo -n "Memory request (e.g., 256Mi, 1Gi): "
      read -r mem_req
      echo -n "Memory limit (e.g., 512Mi, 2Gi): "
      read -r mem_lim
      
      # Build resources JSON
      local resources_json="{"
      local has_requests=false
      local has_limits=false
      
      if [ -n "$cpu_req" ] || [ -n "$mem_req" ]; then
        has_requests=true
        resources_json="$resources_json\"requests\":{"
        [ -n "$cpu_req" ] && resources_json="$resources_json\"cpu\":\"$cpu_req\","
        [ -n "$mem_req" ] && resources_json="$resources_json\"memory\":\"$mem_req\","
        resources_json="${resources_json%,}}"
      fi
      
      if [ -n "$cpu_lim" ] || [ -n "$mem_lim" ]; then
        has_limits=true
        [ "$has_requests" = true ] && resources_json="$resources_json,"
        resources_json="$resources_json\"limits\":{"
        [ -n "$cpu_lim" ] && resources_json="$resources_json\"cpu\":\"$cpu_lim\","
        [ -n "$mem_lim" ] && resources_json="$resources_json\"memory\":\"$mem_lim\","
        resources_json="${resources_json%,}}"
      fi
      
      resources_json="$resources_json}"
      
      echo "Updating replicas and resources for $component_name"
      $OC -n "$ns" patch wo "$wo_name" --type=merge -p "{\"spec\":{\"sizeMapping\":{\"$component_name\":{\"replicas\":$replicas,\"resources\":$resources_json}}}}"
      echo "✓ Replicas and resources updated successfully"
      ;;
    4)
      echo "Removing size mapping override for $component_name"
      $OC -n "$ns" patch wo "$wo_name" --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/sizeMapping/$component_name\"}]" 2>/dev/null
      echo "✓ Component override removed (if it existed)"
      ;;
    5|*)
      echo "Cancelled."
      ;;
  esac
}

# Main configuration mode function
run_configuration_mode() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║                         CONFIGURATION MODE                                   ║"
  echo "╠══════════════════════════════════════════════════════════════════════════════╣"
  echo "║                                                                              ║"
  echo "║  This mode allows you to view and modify WatsonxOrchestrate CR settings.    ║"
  echo "║  Changes are applied immediately to the cluster.                             ║"
  echo "║                                                                              ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Get WO CR name
  local wo_name=$($OC -n "$PROJECT_CPD_INST_OPERANDS" get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}')
  
  if [ -z "$wo_name" ]; then
    echo "❌ Error: No WatsonxOrchestrate CR found in namespace $PROJECT_CPD_INST_OPERANDS"
    exit 1
  fi
  
  echo "Found WO CR: $wo_name in namespace: $PROJECT_CPD_INST_OPERANDS"
  
  while true; do
    show_current_config "$wo_name" "$PROJECT_CPD_INST_OPERANDS"
    
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                         Configuration Options                                ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  1. Modify Size (T-shirt sizing)"
    echo "  2. Toggle HPA (Horizontal Pod Autoscaling)"
    echo "  3. Toggle DocProc"
    echo "  4. Add/Modify/Remove Image Digest Override"
    echo "  5. Modify Component Replicas and Resources (sizeMapping)"
    echo "  6. Refresh current configuration"
    echo "  7. Exit configuration mode"
    echo ""
    echo -n "Select option (1-7): "
    read -r config_choice
    
    case "$config_choice" in
      1) modify_size "$wo_name" "$PROJECT_CPD_INST_OPERANDS" ;;
      2) modify_hpa "$wo_name" "$PROJECT_CPD_INST_OPERANDS" ;;
      3) modify_docproc "$wo_name" "$PROJECT_CPD_INST_OPERANDS" ;;
      4) modify_image_digest "$wo_name" "$PROJECT_CPD_INST_OPERANDS" ;;
      5) modify_component_sizing "$wo_name" "$PROJECT_CPD_INST_OPERANDS" ;;
      6) echo "Refreshing..." ;;
      7)
        echo ""
        echo "Exiting configuration mode..."
        exit 0
        ;;
      *)
        echo "❌ Invalid option. Please select 1-7."
        ;;
    esac
    
    echo ""
    echo "Press Enter to continue..."
    read -r
  done
}

# ==================== End Configuration Mode Functions ====================

print_header() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║                 watsonx Orchestrate Health Check Script                      ║"
  echo "║                         Author: Manu Thapar                                  ║"
  echo "╠══════════════════════════════════════════════════════════════════════════════╣"
  
  # Timestamp
  timestamp="$(ts)"
  printf "║ Timestamp: %-66s║\n" "$timestamp"
  echo "║                                                                              ║"
  
  # Namespaces
  printf "║ OPERANDS Namespace: %-57s║\n" "$PROJECT_CPD_INST_OPERANDS"
  printf "║ OPERATORS Namespace: %-56s║\n" "${PROJECT_CPD_INST_OPERATORS:-none}"
  echo "║                                                                              ║"
  
  # Edition
  printf "║ Edition: %-68s║\n" "${WXO_EDITION:-unknown}"
  
  # Detection method (show CR paths directly without label)
  if [ -n "${WXO_DETECT_NOTE:-}" ]; then
    echo "$WXO_DETECT_NOTE" | sed 's/ and /\n/g' | while IFS= read -r line; do
      [ -z "$line" ] && continue
      printf "║   • %-73s║\n" "$line"
    done
  fi
  echo "║                                                                              ║"
  
  # Get WO CR info
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  
  if [ -n "$wo_name" ]; then
    # Size (no emoji)
    wo_size=`$OCN get wo "$wo_name" -o jsonpath='{.spec.size}' 2>/dev/null || :`
    if [ -n "$wo_size" ]; then
      printf "║ Size: %-71s║\n" "$wo_size"
      printf "║   • wo.spec.size=%-60s║\n" "$wo_size"
    else
      printf "║ Size: %-71s║\n" "medium (default)"
      printf "║   • wo.spec.size=%-60s║\n" "Not Present"
    fi
    
    # HPA (no emoji)
    hpa_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.autoScaleConfig}' 2>/dev/null || :`
    if [ -n "$hpa_enabled" ]; then
      case "$(echo "$hpa_enabled" | tr '[:upper:]' '[:lower:]')" in
        true)
          printf "║ HPA: %-72s║\n" "Enabled"
          printf "║   • wo.spec.autoScaleConfig=%-49s║\n" "true" ;;
        false)
          printf "║ HPA: %-72s║\n" "Disabled"
          printf "║   • wo.spec.autoScaleConfig=%-49s║\n" "false" ;;
        *)
          printf "║ HPA: %-72s║\n" "Disabled (default)"
          printf "║   • wo.spec.autoScaleConfig=%-49s║\n" "Not Present" ;;
      esac
    else
      printf "║ HPA: %-72s║\n" "Disabled (default)"
      printf "║   • wo.spec.autoScaleConfig=%-49s║\n" "Not Present"
    fi
    
    # IFM (no emoji)
    ifm_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.enable_ifm}' 2>/dev/null || :`
    if [ -n "$ifm_enabled" ]; then
      case "$(echo "$ifm_enabled" | tr '[:upper:]' '[:lower:]')" in
        true)
          printf "║ IFM: %-72s║\n" "Enabled"
          printf "║   • wo.spec.wxolite.enable_ifm=%-46s║\n" "true"
          models_json=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.ifm.model_config}' 2>/dev/null || :`
          if [ -n "$models_json" ] && [ "$models_json" != "{}" ] && [ "$models_json" != "null" ]; then
            printf "║   %-75s║\n" "Models configured:"
            tmp_models=`mktemp 2>/dev/null || echo "/tmp/wo_models.$$"`
            $OCN get wo "$wo_name" -o json 2>/dev/null | \
              awk '
                BEGIN { in_model_config=0; model_type=""; model_name=""; indent=0 }
                /"model_config"[[:space:]]*:/ { in_model_config=1; next }
                in_model_config {
                  if ($0 ~ /{/) indent++
                  if ($0 ~ /}/) {
                    indent--
                    if (indent <= 1) { in_model_config=0; next }
                  }
                  if (indent == 2 && $0 ~ /"[^"]+"\s*:\s*{/) {
                    match($0, /"([^"]+)"/, arr)
                    model_type = arr[1]
                  }
                  if (indent == 3 && $0 ~ /"[^"]+"\s*:\s*{/) {
                    match($0, /"([^"]+)"/, arr)
                    model_name = arr[1]
                  }
                  if (model_name != "" && $0 ~ /"replicas"/) {
                    match($0, /:\s*([0-9]+)/, arr)
                    replicas = arr[1]
                  }
                  if (model_name != "" && $0 ~ /"shards"/) {
                    match($0, /:\s*([0-9]+)/, arr)
                    shards = arr[1]
                    if (model_type != "" && model_name != "") {
                      print model_type "|" model_name "|" replicas "|" shards
                      model_name = ""
                      replicas = ""
                      shards = ""
                    }
                  }
                }
              ' > "$tmp_models" 2>/dev/null || :
            
            if [ -s "$tmp_models" ]; then
              while IFS='|' read -r mtype mname replicas shards; do
                [ -z "$mname" ] && continue
                replica_info="${replicas:-default}"
                shard_info="${shards:-default}"
                model_line="• ${mtype}/${mname} (r=${replica_info}, s=${shard_info})"
                printf "║     %-73s║\n" "$model_line"
              done < "$tmp_models"
            fi
            rm -f "$tmp_models"
          fi
          ;;
        false)
          printf "║ IFM: %-72s║\n" "Disabled"
          printf "║   • wo.spec.wxolite.enable_ifm=%-46s║\n" "false" ;;
        *)
          printf "║ IFM: %-72s║\n" "Disabled (default)"
          printf "║   • wo.spec.wxolite.enable_ifm=%-46s║\n" "Not Present" ;;
      esac
    else
      printf "║ IFM: %-72s║\n" "Disabled (default)"
      printf "║   • wo.spec.wxolite.enable_ifm=%-46s║\n" "Not Present"
    fi
  else
    printf "║ ⚠️  %-74s║\n" "WO CR not found - cannot retrieve configuration details"
  fi
  
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo ""
}

section() { echo; echo "▶ $1"; }


detect_operators_namespace_from_deployments() {
  ns="$($OC get deploy -A --no-headers 2>/dev/null | awk '$2=="ibm-wxo-componentcontroller-manager" {print $1; exit}')"
  if [ -z "${ns:-}" ]; then
    ns="$($OC get deploy -A --no-headers 2>/dev/null | awk '$2=="wo-operator" {print $1; exit}')"
  fi
  if [ -n "${ns:-}" ]; then
    PROJECT_CPD_INST_OPERATORS="$ns"
    export PROJECT_CPD_INST_OPERATORS
    return 0
  fi
  return 1
}

# ---------------------- Namespace detect --------------------
resolve_namespaces() {
  autodetected_operands=""
  autodetected_operators=""

  if [ -z "${PROJECT_CPD_INST_OPERANDS:-}" ]; then
    autodetected_operands=$($OC get wo -A --no-headers 2>/dev/null | awk 'NR==1 {print $1}') || :
    if [ -z "$autodetected_operands" ]; then
      autodetected_operands=$($OC get pods -A --no-headers 2>/dev/null | awk '$2 ~ /^wo-/ {print $1; exit}') || :
    fi
  fi

  if [ -z "${PROJECT_CPD_INST_OPERATORS:-}" ]; then
    if detect_operators_namespace_from_deployments; then
      autodetected_operators="$PROJECT_CPD_INST_OPERATORS"
    else
      autodetected_operators=""
    fi
  fi

  if [ -z "${PROJECT_CPD_INST_OPERANDS:-}" ]; then PROJECT_CPD_INST_OPERANDS="$autodetected_operands"; fi
  if [ -z "${PROJECT_CPD_INST_OPERATORS:-}" ]; then PROJECT_CPD_INST_OPERATORS="$autodetected_operators"; fi
  if [ -n "$OVERRIDE_NS" ]; then PROJECT_CPD_INST_OPERANDS="$OVERRIDE_NS"; fi

  if [ -z "${PROJECT_CPD_INST_OPERANDS:-}" ]; then
    echo "[$(ts)] Could not autodetect operands namespace."
    echo "[$(ts)] Set it explicitly and re-run:"
    echo "  export PROJECT_CPD_INST_OPERANDS=<operands-namespace>"
    [ -z "${PROJECT_CPD_INST_OPERATORS:-}" ] && echo "  Optional export PROJECT_CPD_INST_OPERATORS=<operators-namespace>"
    exit 1
  fi

  if [ -z "${PROJECT_CPD_INST_OPERATORS:-}" ]; then
    echo "[$(ts)] Warning: could not autodetect operators namespace continuing."
  fi
}

# ---------------------- Edition detect ----------------------
# Sets:
#   WXO_EDITION = agentic | agentic_skills_assistant | agentic_assistant | unknown
#   WXO_DETECT_NOTE = explanation string
detect_wxo_edition() {
  WXO_EDITION="unknown"
  WXO_DETECT_NOTE=""

  if [ -n "$ASSUME_EDITION" ]; then
    WXO_EDITION="$ASSUME_EDITION"
    WXO_DETECT_NOTE="assumed via CLI"
    export WXO_EDITION WXO_DETECT_NOTE
    return 0
  fi

  [ "${DETECT_EDITION:-1}" -eq 1 ] || { WXO_DETECT_NOTE="detection disabled"; export WXO_EDITION WXO_DETECT_NOTE; return 0; }

  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :

  if [ -n "$wo_name" ]; then
    wxolite_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.enabled}' 2>/dev/null || :`
    case "$(echo "${wxolite_enabled:-}" | tr '[:upper:]' '[:lower:]')" in
      true)
      wxolite_asst_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.assistant.enabled}' 2>/dev/null || :`
      case "$(echo "${wxolite_asst_enabled:-}" | tr '[:upper:]' '[:lower:]')" in
        true) WXO_EDITION="agentic_assistant"; WXO_DETECT_NOTE="wo.spec.wxolite.enabled=true and wo.spec.wxolite.assistant.enabled=true"; if $OCN get wo "$wo_name" -o jsonpath=\'{.spec.docproc.enabled}\' 2>/dev/null | grep -qi true; then WXO_DETECT_NOTE="$WXO_DETECT_NOTE and wo.spec.docproc.enabled=true"; fi ;;
        *) WXO_EDITION="agentic"; WXO_DETECT_NOTE="wo.spec.wxolite.enabled=true"; if $OCN get wo "$wo_name" -o jsonpath=\'{.spec.docproc.enabled}\' 2>/dev/null | grep -qi true; then WXO_DETECT_NOTE="$WXO_DETECT_NOTE and wo.spec.docproc.enabled=true"; fi ;;
      esac
      ;;
    esac

    if [ "$WXO_EDITION" = "unknown" ]; then
      agentic_only=`$OCN get wo "$wo_name" -o jsonpath='{.spec.agenticOnly}' 2>/dev/null || :`
      profile_val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.profile}' 2>/dev/null || :`
      edition_val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.edition}' 2>/dev/null || :`
      mode_val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.mode}' 2>/dev/null || :`
      case "$(echo "${agentic_only:-}" | tr '[:upper:]' '[:lower:]')" in
        true) WXO_EDITION="agentic"; WXO_DETECT_NOTE="wo.spec.agenticOnly=true" ;;
      esac
      if [ "$WXO_EDITION" = "unknown" ]; then
        case "$(echo "${profile_val:-}" | tr '[:upper:]' '[:lower:]')" in
          lite|agentic) WXO_EDITION="agentic"; WXO_DETECT_NOTE="wo.spec.profile=$profile_val" ;;
        esac
      fi
      if [ "$WXO_EDITION" = "unknown" ]; then
        case "$(echo "${edition_val:-}" | tr '[:upper:]' '[:lower:]')" in
          lite|agentic) WXO_EDITION="agentic"; WXO_DETECT_NOTE="wo.spec.edition=$edition_val" ;;
        esac
      fi
      if [ "$WXO_EDITION" = "unknown" ]; then
        case "$(echo "${mode_val:-}" | tr '[:upper:]' '[:lower:]')" in
          agentic) WXO_EDITION="agentic"; WXO_DETECT_NOTE="wo.spec.mode=agentic" ;;
        esac
      fi
    fi

    if [ "$WXO_EDITION" = "unknown" ]; then
      wocs_name=`$OCN get wocomponentservices.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
      if [ -n "$wocs_name" ]; then
        cstat=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$wocs_name" -o jsonpath='{.status.componentStatus}' 2>/dev/null || :`
        [ "$cstat" = "ReconciledLite" ] && { WXO_EDITION="agentic"; WXO_DETECT_NOTE="WoComponentServices.status.componentStatus=ReconciledLite"; }
      fi
    fi
  fi

  if [ "$WXO_EDITION" = "unknown" ]; then
    have_wa=`$OCN get wa --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    have_doc=`$OCN get documentprocessings.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    have_de=`$OCN get digitalemployees.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    have_uab=`$OCN get uabautomationdecisionservices.uab.ba.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    if [ -z "$have_wa" ] && [ -z "$have_doc" ] && [ -z "$have_de" ] && [ -z "$have_uab" ]; then
      WXO_EDITION="agentic"
      WXO_DETECT_NOTE="heuristic no WA DocProc DE UAB CRs"
    else
      WXO_EDITION="agentic_skills_assistant"
      WXO_DETECT_NOTE="heuristic at least one non-agentic CR present"
    fi
  fi

  export WXO_EDITION WXO_DETECT_NOTE
}


is_ifm_enabled_in_wo() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  [ -z "${wo_name:-}" ] && return 1
  wo_json=`$OCN get wo "$wo_name" -o json 2>/dev/null || :`
  compact=`printf '%s' "$wo_json" | tr -d '\n\r\t '`
  printf '%s' "$compact" | grep -Eiq '"enable_ifm":true|"enable_ifm":"true"' && return 0
  return 1
}

is_docproc_enabled_in_wo() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  [ -z "${wo_name:-}" ] && return 1
  val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.docproc.enabled}' 2>/dev/null || :`
  val_lc="$(echo "${val:-}" | tr '[:upper:]' '[:lower:]')"
  [ "$val_lc" = "true" ] && return 0
  return 1
}

# ------------------------- Checks ---------------------------
check_wo_pods() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  bad_found=0
  total_wo=0
  echo "▶ Checking Orchestrate pods (including Milvus)"
  tmp_list=`mktemp 2>/dev/null || echo "/tmp/wo_pods.$$"`
  tmp_bad=`mktemp 2>/dev/null || echo "/tmp/wo_bad.$$"`
  $OCN get pods --no-headers 2>/dev/null > "$tmp_list" || :
  while IFS= read -r line; do
    name="$(printf '%s
' "$line" | awk '{print $1}')"
    ready="$(printf '%s
' "$line" | awk '{print $2}')"
    status="$(printf '%s
' "$line" | awk '{print $3}')"
    restarts="$(printf '%s
' "$line" | awk '{print $4}')"
    age="$(printf '%s
' "$line" | awk '{print $NF}')"
    [ -z "$name" ] && continue
    case "$name" in wo-*|*milvus*) : ;; *) continue ;; esac
    total_wo=`expr "${total_wo:-0}" + 1`
    if [ "$status" = "Completed" ]; then continue; fi
    current=`echo "$ready" | awk -F/ '{print $1}'`
    total=`echo "$ready" | awk -F/ '{print $2}'`
    if [ "$status" = "Running" ] && [ "$current" = "$total" ]; then :; else
      printf "%s	%s	%s	%s	%s
" "$name" "$ready" "$status" "${restarts:-?}" "${age:-?}" >> "$tmp_bad"
      bad_found=1
    fi
  done < "$tmp_list"

  if [ "${total_wo:-0}" -eq 0 ]; then
    echo "❌ No pods found with prefix 'wo-' in namespace $PROJECT_CPD_INST_OPERANDS."
    rm -f "$tmp_list" "$tmp_bad"
    return 1
  fi
  if [ "${bad_found:-0}" -eq 0 ]; then
    echo "✅ All Orchestrate pods are healthy"
    rm -f "$tmp_list" "$tmp_bad"
    return 0
  else
    echo "❌ Some pods are not healthy. Pods with issues:"
  printf "%-55s %-8s %-22s %-10s %-10s\n" "NAME" "READY" "STATUS" "RESTARTS" "AGE"
  printf "%-55s %-8s %-22s %-10s %-10s\n" "----" "-----" "------" "--------" "---"
  awk -F"\t" '{printf "%-55s %-8s %-22s %-10s %-10s\n",$1,$2,$3,$4,$5}' "$tmp_bad"
    rm -f "$tmp_list" "$tmp_bad"
    return 1
  fi
}

check_wo_cr() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  if [ -z "$wo_name" ]; then echo "❌ watsonx Orchestrate CR not found oc get wo"; return 1; fi
  wo_ready=`$OCN get wo "$wo_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
  wo_status=`$OCN get wo "$wo_name" -o jsonpath='{.status.watsonxOrchestrateStatus}' 2>/dev/null || :`
  wo_progress=`$OCN get wo "$wo_name" -o jsonpath='{.status.progress}' 2>/dev/null || :`
  if [ "$wo_ready" = "True" ] && [ "$wo_status" = "Completed" ] && [ "$wo_progress" = "100%" ]; then
    echo "✅ watsonx Orchestrate ($wo_name): Ready=True, Status=Completed, Progress=100%"
    return 0
  else
    echo "❌ watsonx Orchestrate ($wo_name): Ready=$wo_ready, Status=$wo_status, Progress=$wo_progress"
    return 1
  fi
}

check_wocomponentservices() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  name=`$OCN get wocomponentservices.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  if [ -z "$name" ]; then echo "❌ WoComponentServices CR not found oc get wocomponentservices.wo.watsonx.ibm.com"; return 1; fi
  comp_status=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.componentStatus}' 2>/dev/null || :`
  deployed=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.Deployed}' 2>/dev/null || :`
  upgrade=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.Upgrade}' 2>/dev/null || :`
  failure=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || :`
  running=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || :`
  successful=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || :`
  false_components=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$name" -o json 2>/dev/null | awk '
    BEGIN { inDS=0 }
    /"DeployedStatus"[[:space:]]*:/ { inDS=1; next }
    inDS { if ($0 ~ /}/) { inDS=0; exit }
      gsub(/[,"]/, ""); sub(/^[[:space:]]*/, "");
      if ($0 ~ /: *false$/ || $0 ~ /: *False$/) print $0 }'` || :
  if { [ "$comp_status" = "FullInstallComplete" ] || [ "$comp_status" = "Reconciled" ] || [ "$comp_status" = "ReconciledLite" ]; } && [ "$failure" != "True" ]; then
    echo "✅ WoComponentServices ($name): componentStatus=$comp_status, Deployed=${deployed:-?}, Upgrade=${upgrade:-?}, Successful=${successful:-?}, Running=${running:-?}"
    return 0
  else
    echo "❌ WoComponentServices ($name): componentStatus=$comp_status, Deployed=${deployed:-?}, Upgrade=${upgrade:-?}, Successful=${successful:-?}, Running=${running:-?}"
    if [ -n "${false_components:-}" ]; then
      echo "   Components with DeployedStatus=false:"
      echo "$false_components" | awk -F: '{gsub(/[[:space:]]*/,"",$1); gsub(/[[:space:]]*/,"",$2); print "     - " $1 " = " tolower($2)}'
    fi
    return 1
  fi
}

check_wa_cr() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wa_name=`$OCN get wa --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  if [ -z "$wa_name" ]; then echo "❌ watsonx Assistant CR not found oc get wa"; return 1; fi
  wa_ready=`$OCN get wa "$wa_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
  wa_status=`$OCN get wa "$wa_name" -o jsonpath='{.status.watsonAssistantStatus}' 2>/dev/null || :`
  wa_progress=`$OCN get wa "$wa_name" -o jsonpath='{.status.progress}' 2>/dev/null || :`
  if [ "$wa_ready" = "True" ] && [ "$wa_status" = "Completed" ] && [ "$wa_progress" = "100%" ]; then
    echo "✅ watsonx Assistant ($wa_name): Ready=True, Status=Completed, Progress=100%"
    return 0
  else
    echo "❌ watsonx Assistant ($wa_name): Ready=$wa_ready, Status=$wa_status, Progress=$wa_progress"
    
    # For agentic_assistant edition in health check mode, check waall resources
    if [ "${WXO_EDITION:-unknown}" = "agentic_assistant" ] && [ "${TROUBLESHOOT_MODE:-0}" -eq 0 ]; then
      check_waall_resources
    fi
    return 1
  fi
}

check_waall_resources() {
  echo "  📋 Checking WatsonAssistantAll (waall) resources..."
  waall_status=`$OC -n $PROJECT_CPD_INST_OPERANDS get waall --no-headers 2>/dev/null` || :
  if [ -n "$waall_status" ]; then
    echo "$waall_status" | while read -r line; do
      echo "     $line"
    done
  else
    echo "  ⚠️  No waall resources found"
  fi
}

check_wa_operator_verification() {
  echo ""
  echo "  🔍 Checking Watson Assistant operator verification status..."
  
  # Check waall resources first
  check_waall_resources
  
  # Check if assistant operator is running
  OC_OPS="$OC -n ${PROJECT_CPD_INST_OPERATORS:-cpd-operators}"
  
  # Try multiple label patterns to find the operator pod
  operator_pod=`$OC_OPS get pods -l app.kubernetes.io/name=ibm-watson-assistant-operator --no-headers 2>/dev/null | grep Running | awk '{print $1}' | head -1` || :
  
  if [ -z "$operator_pod" ]; then
    operator_pod=`$OC_OPS get pods -l name=ibm-watson-assistant-operator --no-headers 2>/dev/null | grep Running | awk '{print $1}' | head -1` || :
  fi
  
  if [ -z "$operator_pod" ]; then
    operator_pod=`$OC_OPS get pods --no-headers 2>/dev/null | grep -i 'watson-assistant.*operator' | grep Running | awk '{print $1}' | head -1` || :
  fi
  
  if [ -z "$operator_pod" ]; then
    echo "  ⚠️  Watson Assistant operator pod not found or not running in ${PROJECT_CPD_INST_OPERATORS:-cpd-operators}"
    echo "  💡 Tried searching for:"
    echo "     - Pods with label app.kubernetes.io/name=ibm-watson-assistant-operator"
    echo "     - Pods with label name=ibm-watson-assistant-operator"
    echo "     - Pods matching pattern 'watson-assistant.*operator'"
    return 1
  fi
  
  echo "  📦 Operator pod: $operator_pod"
  
  # Check operator logs for verification status
  echo ""
  echo "  📄 Checking operator logs for rollout verification status..."
  
  # List log files in the operator pod
  log_files=`$OC_OPS exec "$operator_pod" -- sh -c 'ls -1 *.1 *.log 2>/dev/null' 2>/dev/null` || :
  
  if [ -z "$log_files" ]; then
    echo "  ⚠️  No log files (*.1 or *.log) found in operator pod"
    return 1
  fi
  
  echo "  📁 Found log files:"
  echo "$log_files" | while read -r logfile; do
    echo "     - $logfile"
  done
  
  # Check log files for verification status
  unverified_found=false
  echo ""
  echo "  🔎 Analyzing rollout verification status..."
  
  # First check .log files, then .log.1 files
  for logfile in `echo "$log_files" | grep '\.log$' | grep -v '\.log\.1$'`; do
    [ -z "$logfile" ] && continue
    
    # Check if this log file has the Final rollout state
    rollout_info=`$OC_OPS exec "$operator_pod" -- sh -c "grep -A 4 'Final rollout state:' '$logfile' 2>/dev/null | tail -5" 2>/dev/null` || :
    
    if [ -n "$rollout_info" ]; then
      # Found in .log file, process it
      process_rollout_info "$logfile" "$rollout_info"
    else
      # Not found in .log, check corresponding .log.1 file
      log1_file="${logfile}.1"
      if echo "$log_files" | grep -q "^${log1_file}$"; then
        rollout_info=`$OC_OPS exec "$operator_pod" -- sh -c "grep -A 4 'Final rollout state:' '$log1_file' 2>/dev/null | tail -5" 2>/dev/null` || :
        if [ -n "$rollout_info" ]; then
          process_rollout_info "$log1_file" "$rollout_info"
        fi
      fi
    fi
  done
  
  if [ "$unverified_found" = "false" ]; then
    echo "  ✅ All nodes verified successfully"
  fi
}

process_rollout_info() {
  local logfile="$1"
  local rollout_info="$2"
  
  if [ -n "$rollout_info" ]; then
    # Check if there are any unverified, failed, or unstarted nodes
    unverified=`echo "$rollout_info" | grep "Unverified:" | sed 's/.*Unverified: //' | tr -d '[]'` || :
    failed=`echo "$rollout_info" | grep "Failed:" | sed 's/.*Failed: //' | tr -d '[]'` || :
    unstarted=`echo "$rollout_info" | grep "Unstarted:" | sed 's/.*Unstarted: //' | tr -d '[]'` || :
    
    if [ "$unverified" != "" ] || [ "$failed" != "" ] || [ "$unstarted" != "" ]; then
      echo ""
      echo "  ⚠️  Issues found in $logfile:"
      echo "$rollout_info" | sed 's/^/     /'
      unverified_found=true
      
      # Ask if user wants to see logs (redirect stdin from terminal)
      echo ""
      printf "  Would you like to see the full log for $logfile? (y/n) [auto-skip in ${USER_INPUT_TIMEOUT}s]: "
      
      if read -t $USER_INPUT_TIMEOUT show_logs </dev/tty 2>/dev/null; then
        : # User provided input
      else
        show_logs="n"
        echo
        echo "  ⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping log display..."
      fi
      
      if [ "$show_logs" = "y" ] || [ "$show_logs" = "Y" ]; then
        printf "  How many lines to display? [default: 50 in ${USER_INPUT_TIMEOUT}s]: "
        
        if read -t $USER_INPUT_TIMEOUT line_count </dev/tty 2>/dev/null; then
          : # User provided input
        else
          line_count="50"
          echo
          echo "  ⏱️  No input received, using default 50 lines..."
        fi
        
        # Validate line count
        if ! echo "$line_count" | grep -qE '^[0-9]+$'; then
          line_count="50"
        fi
        
        echo ""
        echo "  📄 Last $line_count lines of $logfile:"
        echo "  ----------------------------------------"
        $OC_OPS exec "$operator_pod" -- sh -c "tail -n $line_count '$logfile'" 2>/dev/null | sed 's/^/  /'
        echo "  ----------------------------------------"
      fi
    fi
  fi
}

check_ifm_cr() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  ifm_name=`$OCN get watsonxaiifm --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
  if [ -z "$ifm_name" ]; then echo "❌ watsonx AI IFM CR not found oc get watsonxaiifm"; return 1; fi
  cond_success=`$OCN get watsonxaiifm "$ifm_name" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || :`
  cond_failure=`$OCN get watsonxaiifm "$ifm_name" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || :`
  ifm_status=`$OCN get watsonxaiifm "$ifm_name" -o jsonpath='{.status.watsonxaiifmStatus}' 2>/dev/null || :`
  ifm_progress=`$OCN get watsonxaiifm "$ifm_name" -o jsonpath='{.status.progress}' 2>/dev/null || :`
  if [ "$cond_success" = "True" ] && { [ "$cond_failure" = "False" ] || [ -z "$cond_failure" ]; } && [ "$ifm_status" = "Completed" ] && [ "$ifm_progress" = "100%" ]; then
    echo "✅ IFM ($ifm_name): Successful=True, Failure=${cond_failure:-None}, Status=Completed, Progress=100%"
    return 0
  else
    echo "❌ IFM ($ifm_name): Successful=$cond_success, Failure=$cond_failure, Status=$ifm_status, Progress=$ifm_progress"
    return 1
  fi
}

check_docproc() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  rows=`$OCN get documentprocessings.watsonx.ibm.com --no-headers 2>/dev/null | awk '$1 ~ /^wo-/'` || :
  if [ -z "$rows" ]; then echo "❌ No DocumentProcessing CRs starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  echo "$rows" | while read name version status deployed verified age; do
    [ -z "$name" ] && continue
    if [ "$status" = "Completed" ]; then
      if [ -n "$deployed" ] && [ -n "$verified" ] && [ "$deployed" = "$verified" ]; then
        echo "✅ DocumentProcessing $name: Status=$status, Deployed=$deployed, Verified=$verified"
      else
        echo "✅ DocumentProcessing $name: Status=$status"
      fi
    else
      echo "❌ DocumentProcessing $name: Status=${status:-Unknown}"
      bad=1
    fi
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

check_digital_employees() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  rows=`$OCN get digitalemployees.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk '$1 ~ /^wo-/'` || :
  if [ -z "$rows" ]; then echo "❌ No DigitalEmployees CRs starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  echo "$rows" | while read name ready age; do
    [ -z "$name" ] && continue
    if [ "$ready" = "True" ]; then
      echo "✅ DigitalEmployees $name: Ready=True"
    else
      rdy=`$OCN get digitalemployees.wo.watsonx.ibm.com "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
      if [ "$rdy" = "True" ]; then
        echo "✅ DigitalEmployees $name: Ready=True"
      else
        echo "❌ DigitalEmployees $name: Ready=${rdy:-$ready}"
        bad=1
      fi
    fi
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

check_uab_ads() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  rows=`$OCN get uabautomationdecisionservices.uab.ba.ibm.com --no-headers 2>/dev/null` || :
  if [ -z "$rows" ]; then echo "❌ No UAB Automation Decision Services CRs found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  echo "$rows" | while read name designer runtime ready version; do
    [ -z "$name" ] && continue
    if [ "$ready" = "True" ]; then
      echo "✅ UAB ADS $name: Designer=$designer, Runtime=$runtime, Ready=True, Version=$version"
    else
      rdy=`$OCN get uabautomationdecisionservices.uab.ba.ibm.com "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
      if [ "$rdy" = "True" ]; then
        echo "✅ UAB ADS $name: Designer=$designer, Runtime=$runtime, Ready=True, Version=$version"
      else
        echo "❌ UAB ADS $name: Ready=${rdy:-$ready}, Designer=$designer, Runtime=$runtime, Version=$version"
        bad=1
      fi
    fi
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

check_edb_clusters() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  names=`$OCN get clusters.postgresql.k8s.enterprisedb.io --no-headers 2>/dev/null | awk '$1 ~ /^wo-/{print $1}'` || :
  if [ -z "$names" ]; then echo "❌ No EDB Postgres clusters starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  echo "$names" | while read n; do
    [ -z "$n" ] && continue
    instances=`$OCN get clusters.postgresql.k8s.enterprisedb.io "$n" -o jsonpath='{.status.instances}' 2>/dev/null || :`
    ready=`$OCN get clusters.postgresql.k8s.enterprisedb.io "$n" -o jsonpath='{.status.readyInstances}' 2>/dev/null || :`
    status_text=`$OCN get clusters.postgresql.k8s.enterprisedb.io "$n" -o jsonpath='{.status.phase}' 2>/dev/null || :`
    # Get the current primary pod
    primary_pod=`$OCN get clusters.postgresql.k8s.enterprisedb.io "$n" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || :`
    if [ -z "$instances" ] || [ -z "$ready" ]; then
      set -- `$OCN get clusters.postgresql.k8s.enterprisedb.io "$n" --no-headers 2>/dev/null | awk '{print $2, $3, $4, $5, $6}'`
      inst_col="${1:-}"; ready_col="${2:-}"; stat_col="${3:-}"
      [ -n "$inst_col" ] && instances="$inst_col"
      [ -n "$ready_col" ] && ready="$ready_col"
      [ -n "$stat_col" ] && status_text="$stat_col"
    fi
    echo "$status_text" | grep -qi "healthy" && healthy_phase=1 || healthy_phase=0
    if [ -z "$instances" ] || [ -z "$ready" ]; then
      echo "❌ EDB cluster $n: could not determine Instances or Ready counts"
      bad=1
    elif [ "$ready" = "$instances" ] && [ "$healthy_phase" -eq 1 ]; then
      if [ -n "$primary_pod" ]; then
        echo "✅ EDB cluster $n: Ready=$ready/$instances, Status=$status_text, Primary=$primary_pod"
      else
        echo "✅ EDB cluster $n: Ready=$ready/$instances, Status=$status_text"
      fi
    else
      if [ -n "$primary_pod" ]; then
        echo "❌ EDB cluster $n: Ready=$ready/$instances, Status=${status_text:-Unknown}, Primary=$primary_pod"
      else
        echo "❌ EDB cluster $n: Ready=$ready/$instances, Status=${status_text:-Unknown}"
      fi
      bad=1
    fi
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

check_kafka_readiness() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"

  tmp_kafka=`mktemp 2>/dev/null || echo "/tmp/wo_kafka.$$"`
  $OCN get kafka -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null | awk '$1 ~ /^wo-/' > "$tmp_kafka" || :

  if [ ! -s "$tmp_kafka" ]; then
    echo "❌ No Kafka resources starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"
    rm -f "$tmp_kafka"
    return 1
  fi

  bad=0
  while read -r name ready; do
    [ -z "${name:-}" ] && continue
    if [ "${ready:-}" = "True" ]; then
      echo "✅ Kafka $name: Ready=True"
    else
      val="${ready:-Unknown}"
      echo "❌ Kafka $name: Ready=$val"
      bad=1
    fi
  done < "$tmp_kafka"

  rm -f "$tmp_kafka"
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_redis_cp() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  rows=`$OCN get rediscps.redis.ibm.com --no-headers 2>/dev/null | awk '$1 ~ /^wo-/'` || :
  if [ -z "$rows" ]; then echo "❌ No Redis CPs starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  echo "$rows" | while read name version reconciled status age; do
    [ -z "$name" ] && continue
    ready=`$OCN get rediscps.redis.ibm.com "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
    if [ "$ready" = "True" ] || [ "$status" = "Completed" ]; then
      echo "✅ RedisCP $name: Status=${ready:+Ready=True}${ready:+"; "}$status Reconciled=${reconciled:-unknown}"
    else
      val="${ready:-$status}"; [ -z "$val" ] && val="Unknown"
      echo "❌ RedisCP $name: Status=$val Reconciled=${reconciled:-unknown}"
      bad=1
    fi
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

check_wxd_engines() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  rows=`$OCN get wxdengines.watsonxdata.ibm.com --no-headers 2>/dev/null | awk '$1 ~ /^wo-/'` || :
  if [ -z "$rows" ]; then echo "❌ No WXD engines starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  # Use process substitution to avoid subshell issue with pipe
  while read name version type display size reconcile status age; do
    [ -z "$name" ] && continue
    echo "$reconcile" | grep -qi "completed" && recon_ok=1 || recon_ok=0
    echo "$status" | grep -Eqi "^(running|completed)$" && phase_ok=1 || phase_ok=0
    if [ "$recon_ok" -eq 1 ] && [ "$phase_ok" -eq 1 ]; then
      echo "✅ WXD engine $name (${type:-unknown}): Reconcile=$reconcile, Status=$status"
    else
      recon_json=`$OCN get wxdengines.watsonxdata.ibm.com "$name" -o jsonpath='{.status.reconcile}' 2>/dev/null || :`
      phase_json=`$OCN get wxdengines.watsonxdata.ibm.com "$name" -o jsonpath='{.status.phase}' 2>/dev/null || :`
      if { echo "${recon_json}" | grep -qi "completed"; } && { echo "${phase_json:-$status}" | grep -Eqi "^(running|completed)$"; }; then
        echo "✅ WXD engine $name (${type:-unknown}): Reconcile=${recon_json:-$reconcile}, Status=${phase_json:-$status}"
      else
        val_recon="${reconcile:-${recon_json:-Unknown}}"
        val_phase="${status:-${phase_json:-Unknown}}"
        echo "❌ WXD engine $name (${type:-unknown}): Reconcile=$val_recon, Status=$val_phase"
        bad=1
      fi
    fi
  done <<EOF
$rows
EOF
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

check_obc() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  tmp_obc=`mktemp 2>/dev/null || echo "/tmp/wo_obc.$$"`
  $OCN get obc --no-headers 2>/dev/null | awk '$1 ~ /^wo-/' > "$tmp_obc" || :

  if [ ! -s "$tmp_obc" ]; then
    echo "ℹ️ No OBC resources starting with 'wo-' found, skipping"
    rm -f "$tmp_obc"
    return 0
  fi

  bad=0
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    phase="$(printf '%s\n' "$line" | awk '{print $3}')"
    age="$(printf '%s\n' "$line" | awk '{print $4}')"
    [ -z "${name:-}" ] && continue
    if [ "${phase:-}" = "Bound" ]; then
      echo "✅ OBC $name: Phase=Bound Age=${age:-?}"
    else
      echo "❌ OBC $name: Phase=${phase:-Unknown} Age=${age:-?}"
      bad=1
    fi
  done < "$tmp_obc"

  rm -f "$tmp_obc"
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_jobs() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  
  # Get jobs by labels: watson-orchestrate and watson-assistant
  tmp_jobs=`mktemp 2>/dev/null || echo "/tmp/wo_jobs.$$"`
  $OCN get jobs -l 'app.kubernetes.io/name in (watson-orchestrate,watson-assistant)' --no-headers 2>/dev/null > "$tmp_jobs" || :
  
  if [ ! -s "$tmp_jobs" ]; then
    echo "ℹ️ No Orchestrate/Assistant jobs found, skipping"
    rm -f "$tmp_jobs"
    return 0
  fi
  
  bad=0
  failed_jobs=""
  incomplete_jobs=""
  checked_count=0
  
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    age="$(printf '%s\n' "$line" | awk '{print $4}')"
    [ -z "$name" ] && continue
    
    # Skip jobs created by cronjobs (contain "cronjob" in name)
    echo "$name" | grep -qi "cronjob" && continue
    
    # Skip specific job: wo-wa-create-slot-job
    [ "$name" = "wo-wa-create-slot-job" ] && continue
    
    # Check if job is owned by a CronJob
    owner_kind=`$OCN get job "$name" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || :`
    [ "$owner_kind" = "CronJob" ] && continue
    
    checked_count=`expr "${checked_count:-0}" + 1`
    
    # Check job status - both Failed and Complete conditions
    failed=`$OCN get job "$name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || :`
    completed=`$OCN get job "$name" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || :`
    
    if [ "$failed" = "True" ]; then
      failed_jobs="${failed_jobs}
   - $name (Age: $age) - FAILED"
      bad=1
    elif [ "$completed" != "True" ]; then
      incomplete_jobs="${incomplete_jobs}
   - $name (Age: $age) - INCOMPLETE/RUNNING"
      bad=1
    fi
  done < "$tmp_jobs"
  
  if [ "${checked_count:-0}" -eq 0 ]; then
    echo "ℹ️ No non-cronjob Orchestrate/Assistant jobs found (cronjobs excluded)"
    rm -f "$tmp_jobs"
    return 0
  fi
  
  if [ "$bad" -eq 0 ]; then
    echo "✅ All Orchestrate/Assistant jobs completed successfully ($checked_count jobs checked)"
  else
    echo "❌ Some Orchestrate/Assistant jobs have issues:"
    if [ -n "$failed_jobs" ]; then
      echo "$failed_jobs"
    fi
    if [ -n "$incomplete_jobs" ]; then
      echo "$incomplete_jobs"
    fi
  fi
  
  rm -f "$tmp_jobs"
  [ "$bad" -eq 0 ] && return 0 || return 1
}

# -------------------- Troubleshoot Mode ---------------------

# ---------------------- Knative Eventing Checks ----------------------
check_knative_eventing_deployment() {
  # Only print failures, return 0 for success, 1 for failure
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  
  # Check OpenShift Serverless namespace and deployments
  if ! $OC get namespace openshift-serverless >/dev/null 2>&1; then
    echo "❌ OpenShift Serverless namespace not found"
    return 1
  fi
  
  bad=0
  for dep in knative-openshift knative-openshift-ingress knative-operator-webhook; do
    if ! $OC get deployment "$dep" -n openshift-serverless >/dev/null 2>&1; then
      echo "❌ OpenShift Serverless deployment $dep not found"
      bad=1
      continue
    fi
    ready=$($OC get deployment "$dep" -n openshift-serverless -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$($OC get deployment "$dep" -n openshift-serverless -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$ready" != "$desired" ] || [ "$ready" = "0" ]; then
      echo "❌ OpenShift Serverless deployment $dep not ready ($ready/$desired replicas)"
      bad=1
    fi
  done
  
  # Check Knative Eventing namespace
  if ! $OC get namespace knative-eventing >/dev/null 2>&1; then
    echo "❌ Knative Eventing namespace not found"
    return 1
  fi
  
  # Check KnativeEventing CR
  if ! $OC get knativeeventings.operator.knative.dev knative-eventing -n knative-eventing >/dev/null 2>&1; then
    echo "❌ KnativeEventing CR not found"
    bad=1
  else
    ke_ready=$($OC get knativeeventings.operator.knative.dev knative-eventing -n knative-eventing -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [ "$ke_ready" != "True" ]; then
      echo "❌ KnativeEventing CR not ready (status: $ke_ready)"
      bad=1
    fi
  fi
  
  # Check key Knative Eventing deployments
  for dep in eventing-webhook eventing-controller; do
    if ! $OC get deployment "$dep" -n knative-eventing >/dev/null 2>&1; then
      echo "❌ Knative Eventing deployment $dep not found"
      bad=1
      continue
    fi
    ready=$($OC get deployment "$dep" -n knative-eventing -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$($OC get deployment "$dep" -n knative-eventing -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$ready" != "$desired" ] || [ "$ready" = "0" ]; then
      echo "❌ Knative Eventing deployment $dep not ready ($ready/$desired replicas)"
      bad=1
    fi
  done
  
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_orchestrate_operators() {
  # Check watsonx Orchestrate operators and Watson Assistant operator (for agentic editions)
  # This function works in both health check and troubleshoot modes
  bad=0
  scaled_down_operators=""
  
  echo "▶ Checking watsonx Orchestrate Operators and Dependencies"
  
  # Check wo-operator in operators namespace
  if $OC get deployment wo-operator -n "$PROJECT_CPD_INST_OPERATORS" >/dev/null 2>&1; then
    ready=$($OC get deployment wo-operator -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$($OC get deployment wo-operator -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
      echo "  ✅ wo-operator is ready ($ready/$desired replicas)"
    else
      if [ "$desired" = "0" ]; then
        echo "  ⚠️  wo-operator is scaled down (0 replicas)"
        scaled_down_operators="${scaled_down_operators}wo-operator "
      else
        echo "  ❌ wo-operator not ready ($ready/$desired replicas)"
      fi
      bad=1
    fi
  else
    echo "  ❌ wo-operator deployment not found in $PROJECT_CPD_INST_OPERATORS"
    bad=1
  fi
  
  # Check ibm-wxo-componentcontroller-manager in operators namespace
  if $OC get deployment ibm-wxo-componentcontroller-manager -n "$PROJECT_CPD_INST_OPERATORS" >/dev/null 2>&1; then
    ready=$($OC get deployment ibm-wxo-componentcontroller-manager -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$($OC get deployment ibm-wxo-componentcontroller-manager -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
      echo "  ✅ ibm-wxo-componentcontroller-manager is ready ($ready/$desired replicas)"
    else
      if [ "$desired" = "0" ]; then
        echo "  ⚠️  ibm-wxo-componentcontroller-manager is scaled down (0 replicas)"
        scaled_down_operators="${scaled_down_operators}ibm-wxo-componentcontroller-manager "
      else
        echo "  ❌ ibm-wxo-componentcontroller-manager not ready ($ready/$desired replicas)"
      fi
      bad=1
    fi
  else
    echo "  ❌ ibm-wxo-componentcontroller-manager deployment not found in $PROJECT_CPD_INST_OPERATORS"
    bad=1
  fi
  
  # Check IBM Events Operator in operators namespace
  if $OC get deployment -n "$PROJECT_CPD_INST_OPERATORS" -o name 2>/dev/null | grep -qE 'ibm-events-(cluster-)?operator'; then
    events_deploy=$($OC get deployment -n "$PROJECT_CPD_INST_OPERATORS" -o name 2>/dev/null | grep -E 'ibm-events-(cluster-)?operator' | head -n1 | sed 's|deployment.apps/||')
    ready=$($OC get deployment "$events_deploy" -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$($OC get deployment "$events_deploy" -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
      echo "  ✅ IBM Events Operator ($events_deploy) is ready ($ready/$desired replicas)"
    else
      if [ "$desired" = "0" ]; then
        echo "  ⚠️  IBM Events Operator ($events_deploy) is scaled down (0 replicas)"
        scaled_down_operators="${scaled_down_operators}${events_deploy} "
      else
        echo "  ❌ IBM Events Operator ($events_deploy) not ready ($ready/$desired replicas)"
      fi
      bad=1
    fi
  else
    echo "  ℹ️  IBM Events Operator deployment not found in $PROJECT_CPD_INST_OPERATORS (may be in ibm-knative-events namespace)"
  fi
  
  # Check Watson Assistant operator if in agentic-assistant mode
  if [ "${WXO_EDITION:-unknown}" = "agentic_assistant" ] || [ "${WXO_EDITION:-unknown}" = "agentic_skills_assistant" ]; then
    
    # Check if WatsonAssistant CR exists
    wa_exists=$($OC get wa -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | wc -l)
    if [ "$wa_exists" -gt 0 ]; then
      # Check Watson Assistant operator deployment
      wa_operator_found=0
      for dep_name in ibm-watson-assistant-operator watson-assistant-operator wa-operator assistant-operator; do
        if $OC get deployment "$dep_name" -n "$PROJECT_CPD_INST_OPERATORS" >/dev/null 2>&1; then
          wa_operator_found=1
          ready=$($OC get deployment "$dep_name" -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
          desired=$($OC get deployment "$dep_name" -n "$PROJECT_CPD_INST_OPERATORS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
          if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
            echo "  ✅ Watson Assistant operator ($dep_name) is ready ($ready/$desired replicas)"
          else
            if [ "$desired" = "0" ]; then
              echo "  ⚠️  Watson Assistant operator ($dep_name) is scaled down (0 replicas)"
              scaled_down_operators="${scaled_down_operators}${dep_name} "
            else
              echo "  ❌ Watson Assistant operator ($dep_name) not ready ($ready/$desired replicas)"
            fi
            bad=1
          fi
          break
        fi
      done
      
      if [ "$wa_operator_found" -eq 0 ]; then
        echo "  ❌ Watson Assistant operator deployment not found in $PROJECT_CPD_INST_OPERATORS"
        bad=1
      fi
    else
      echo "  ℹ️  No WatsonAssistant CR found, skipping operator check"
    fi
  fi
  
  # In troubleshoot mode ONLY, offer to scale up operators if they're scaled down
  if [ "${TROUBLESHOOT_MODE:-0}" -eq 1 ] && [ -n "$scaled_down_operators" ]; then
    echo
    echo "⚠️  Scaled down operators detected: $scaled_down_operators"
    printf "Would you like to scale up these operators to 1 replica? (y/n) [default: n, auto-skip in ${USER_INPUT_TIMEOUT}s]: "
    
    # Read with timeout
    if read -t $USER_INPUT_TIMEOUT scale_response </dev/tty 2>/dev/null; then
      : # User provided input
    else
      # Timeout - default to no
      scale_response="n"
      echo
      echo "⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping operator scale-up..."
    fi
    
    if [ "$scale_response" = "y" ] || [ "$scale_response" = "Y" ]; then
      echo
      echo "Scaling up operators..."
      for op in $scaled_down_operators; do
        echo "  Scaling $op to 1 replica..."
        $OC scale deployment "$op" -n "$PROJECT_CPD_INST_OPERATORS" --replicas=1
      done
      echo
      echo "Waiting 30 seconds for operators to start..."
      sleep 30
      echo "✅ Operators scaled up. Continuing with health checks..."
    fi
  fi
  
  echo
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_ibm_events_operator() {
  # Check IBM Events Operator - only print failures
  events_ns="ibm-knative-events"
  
  if ! $OC get namespace "$events_ns" >/dev/null 2>&1; then
    echo "❌ IBM Events Operator namespace $events_ns not found"
    return 1
  fi
  
  bad=0
  # Try different deployment names across releases
  # Use pattern matching to handle versioned operator names like ibm-events-operator-v5.2.1-*
  events_deploy=$($OC get deployment -n "$events_ns" -o name 2>/dev/null | grep -E 'ibm-events-(cluster-)?operator' | head -n1 | sed 's|deployment.apps/||')
  
  if [ -z "$events_deploy" ]; then
    echo "❌ IBM Events Operator deployment not found in $events_ns"
    return 1
  fi
  
  ready=$($OC get deployment "$events_deploy" -n "$events_ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  desired=$($OC get deployment "$events_deploy" -n "$events_ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  [ "${DEBUG_MODE:-0}" -eq 1 ] && echo "    [DEBUG] Deployment $events_deploy: ready=$ready, desired=$desired"
  if [ "$ready" != "$desired" ] || [ "$ready" = "0" ]; then
    echo "❌ IBM Events Operator ($events_deploy) not ready ($ready/$desired replicas)"
    bad=1
  fi
  
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_kafka_cluster() {
  # Check Kafka cluster - only print failures
  bad=0
  
  if ! $OC get kafkas.ibmevents.ibm.com knative-eventing-kafka -n knative-eventing >/dev/null 2>&1; then
    echo "❌ Kafka cluster 'knative-eventing-kafka' not found"
    return 1
  fi
  
  kafka_ready=$($OC get kafkas.ibmevents.ibm.com knative-eventing-kafka -n knative-eventing -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "$kafka_ready" != "True" ]; then
    echo "❌ Kafka cluster not ready (status: $kafka_ready)"
    bad=1
  fi
  
  # Check Kafka mode (ZooKeeper or KRaft)
  kafka_api=$($OC get kafkas.ibmevents.ibm.com knative-eventing-kafka -n knative-eventing -o jsonpath='{.apiVersion}' 2>/dev/null || echo "")
  
  if [ "$kafka_api" = "ibmevents.ibm.com/v1beta2" ]; then
    # ZooKeeper mode
    zk_pods=$($OC get pods -n knative-eventing -l ibmevents.ibm.com/cluster=knative-eventing-kafka,ibmevents.ibm.com/name=knative-eventing-kafka-zookeeper --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$zk_pods" -lt 3 ]; then
      echo "❌ Kafka ZooKeeper mode: only $zk_pods/3 ZooKeeper pods running"
      bad=1
    fi
  else
    # KRaft mode
    nodepool_count=$($OC get kafkanodepools.ibmevents.ibm.com -n knative-eventing -l ibmevents.ibm.com/cluster=knative-eventing-kafka --no-headers 2>/dev/null | wc -l)
    if [ "$nodepool_count" -lt 2 ]; then
      echo "❌ Kafka KRaft mode: only $nodepool_count/2 node pools found"
      bad=1
    fi
  fi
  
  # Check Kafka pods
  [ "${DEBUG_MODE:-0}" -eq 1 ] && echo "    [DEBUG] Counting Kafka pods"
  kafka_pods=$($OC get pods -n knative-eventing -l ibmevents.ibm.com/cluster=knative-eventing-kafka --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$kafka_pods" -lt 3 ]; then
    echo "❌ Only $kafka_pods/3 Kafka pods running"
    bad=1
  fi
  
  # Check entity operator
  if ! $OC get deployment knative-eventing-kafka-entity-operator -n knative-eventing >/dev/null 2>&1; then
    echo "❌ Kafka entity operator deployment not found"
    bad=1
  else
    ready=$($OC get deployment knative-eventing-kafka-entity-operator -n knative-eventing -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$ready" = "0" ]; then
      echo "❌ Kafka entity operator not ready"
      bad=1
    fi
  fi
  
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_kafka_user_and_secret() {
  # Check KafkaUser and broker secret - only print failures
  bad=0
  
  if ! $OC get kafkausers.ibmevents.ibm.com ke-kafka-user -n knative-eventing >/dev/null 2>&1; then
    echo "❌ KafkaUser 'ke-kafka-user' not found"
    bad=1
  else
    user_ready=$($OC get kafkausers.ibmevents.ibm.com ke-kafka-user -n knative-eventing -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [ "$user_ready" != "True" ]; then
      echo "❌ KafkaUser not ready (status: $user_ready)"
      bad=1
    fi
  fi
  
  if ! $OC get secret ke-kafka-broker-secret -n knative-eventing >/dev/null 2>&1; then
    echo "❌ Kafka broker secret 'ke-kafka-broker-secret' not found"
    bad=1
  else
    # Verify secret has required keys
    has_ca=$($OC get secret ke-kafka-broker-secret -n knative-eventing -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "")
    has_user_crt=$($OC get secret ke-kafka-broker-secret -n knative-eventing -o jsonpath='{.data.user\.crt}' 2>/dev/null || echo "")
    has_user_key=$($OC get secret ke-kafka-broker-secret -n knative-eventing -o jsonpath='{.data.user\.key}' 2>/dev/null || echo "")
    
    if [ -z "$has_ca" ] || [ -z "$has_user_crt" ] || [ -z "$has_user_key" ]; then
      echo "❌ Kafka broker secret missing required keys (ca.crt, user.crt, user.key)"
      bad=1
    fi
  fi
  
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_knative_kafka() {
  # Check Knative Kafka - only print failures
  bad=0
  
  if ! $OC get knativekafkas.operator.serverless.openshift.io knative-kafka -n knative-eventing >/dev/null 2>&1; then
    echo "❌ KnativeKafka CR 'knative-kafka' not found"
    return 1
  fi
  
  kk_ready=$($OC get knativekafkas.operator.serverless.openshift.io knative-kafka -n knative-eventing -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "$kk_ready" != "True" ]; then
    echo "❌ KnativeKafka not ready (status: $kk_ready)"
    bad=1
  fi
  
  # Check Knative Kafka deployments
  for dep in kafka-controller kafka-broker-receiver kafka-webhook-eventing; do
    if ! $OC get deployment "$dep" -n knative-eventing >/dev/null 2>&1; then
      echo "❌ Knative Kafka deployment $dep not found"
      bad=1
      continue
    fi
    ready=$($OC get deployment "$dep" -n knative-eventing -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$ready" = "0" ]; then
      echo "❌ Knative Kafka deployment $dep not ready"
      bad=1
    fi
  done
  
  [ "$bad" -eq 0 ] && return 0 || return 1
}

fix_kafka_broker_secret() {
  local NAMESPACE="knative-eventing"
  local SECRET_NAME="ke-kafka-broker-secret"
  local USER_SECRET="ke-kafka-user"
  local CA_SECRET="knative-eventing-kafka-cluster-ca-cert"
  
  echo
  echo "  🔧 Fixing Kafka broker secret..."
  echo
  
  # Check for jq dependency
  if ! command -v jq &> /dev/null; then
    echo "  ❌ Error: jq is not installed. Cannot fix Kafka broker secret."
    echo "  ℹ️  Please install jq and try again, or manually update the secret."
    return 1
  fi
  
  # Check if required secrets exist
  if ! $OC get secret "$CA_SECRET" -n "$NAMESPACE" &>/dev/null; then
    echo "  ❌ Error: CA secret '$CA_SECRET' not found in namespace '$NAMESPACE'"
    return 1
  fi
  
  if ! $OC get secret "$USER_SECRET" -n "$NAMESPACE" &>/dev/null; then
    echo "  ❌ Error: User secret '$USER_SECRET' not found in namespace '$NAMESPACE'"
    return 1
  fi
  
  # Create or update the broker secret
  if ! $OC get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "  📝 Creating Kafka broker secret..."
    cat <<EOF | $OC create -f - 2>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
type: Opaque
data:
  ca.crt: U1NM
  protocol: U1NM
  user.crt: U1NM
  user.key: U1NM
EOF
    if [ $? -ne 0 ]; then
      echo "  ❌ Failed to create secret"
      return 1
    fi
  else
    echo "  ℹ️  Secret '$SECRET_NAME' already exists, updating values..."
  fi
  
  # Populate the secret values
  echo "  📝 Updating secret with correct certificates..."
  
  # Get CA certificate data
  ca_cert_data=$($OC get secret "$CA_SECRET" -o jsonpath="{.data['ca\.crt']}" -n "$NAMESPACE" 2>/dev/null)
  if [ -z "$ca_cert_data" ]; then
    echo "  ❌ Failed to get CA certificate data"
    return 1
  fi
  $OC get secret "$SECRET_NAME" -o json -n "$NAMESPACE" | jq --arg ca_cert "$ca_cert_data" '.data["ca.crt"]=$ca_cert' | $OC apply -f - >/dev/null 2>&1
  
  # Get user certificate data
  user_cert_data=$($OC get secret "$USER_SECRET" -o jsonpath="{.data['user\.crt']}" -n "$NAMESPACE" 2>/dev/null)
  if [ -z "$user_cert_data" ]; then
    echo "  ❌ Failed to get user certificate data"
    return 1
  fi
  $OC get secret "$SECRET_NAME" -o json -n "$NAMESPACE" | jq --arg user_cert "$user_cert_data" '.data["user.crt"]=$user_cert' | $OC apply -f - >/dev/null 2>&1
  
  # Get user key data
  user_key_data=$($OC get secret "$USER_SECRET" -o jsonpath="{.data['user\.key']}" -n "$NAMESPACE" 2>/dev/null)
  if [ -z "$user_key_data" ]; then
    echo "  ❌ Failed to get user key data"
    return 1
  fi
  $OC get secret "$SECRET_NAME" -o json -n "$NAMESPACE" | jq --arg user_key "$user_key_data" '.data["user.key"]=$user_key' | $OC apply -f - >/dev/null 2>&1
  
  echo "  ✅ Kafka broker secret has been successfully updated"
  echo "  ℹ️  The broker should reconnect automatically within a few moments"
  return 0
}

check_knative_brokers() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  echo "▶ Checking Knative Brokers"
  
  tmp_brokers=`mktemp 2>/dev/null || echo "/tmp/wo_brokers.$$"`
  $OCN get brokers.eventing.knative.dev --no-headers 2>/dev/null > "$tmp_brokers" || :
  
  if [ ! -s "$tmp_brokers" ]; then
    echo "ℹ️  No Knative Brokers found in namespace $PROJECT_CPD_INST_OPERANDS"
    rm -f "$tmp_brokers"
    return 0
  fi
  
  bad=0
  kafka_auth_error=0
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    url="$(printf '%s\n' "$line" | awk '{print $2}')"
    [ -z "${name:-}" ] && continue
    
    # Get detailed status
    ready_status=`$OCN get broker "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
    ready_reason=`$OCN get broker "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || :`
    ready_message=`$OCN get broker "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || :`
    
    if [ "${ready_status:-}" = "True" ]; then
      echo "  ✅ Broker: $name"
      echo "     URL: ${url:-N/A}"
      echo "     Status: Ready"
    else
      echo "  ❌ Broker: $name"
      echo "     URL: ${url:-N/A}"
      echo "     Status: ${ready_status:-Unknown}"
      echo "     Reason: ${ready_reason:-Unknown}"
      
      # Check if this is a Kafka authentication/broker connection error
      # Check both reason and message fields
      if echo "$ready_reason" | grep -qE "cannot obtain Kafka cluster admin|client has run out of available brokers|connection refused"; then
        kafka_auth_error=1
      elif echo "$ready_message" | grep -qE "cannot obtain Kafka cluster admin|client has run out of available brokers|connection refused"; then
        echo "     Message: ${ready_message}"
        kafka_auth_error=1
      fi
      bad=1
    fi
    echo
  done < "$tmp_brokers"
  
  rm -f "$tmp_brokers"
  
  # If Kafka authentication error detected, offer to fix it
  if [ "$kafka_auth_error" -eq 1 ]; then
    echo "  ⚠️  Detected Kafka broker connectivity/authentication issue"
    echo "  ℹ️  This is typically caused by expired or misconfigured certificates in the broker secret"
    echo
    printf "  Would you like to fix the Kafka broker secret automatically? (y/n) [auto-skip in ${USER_INPUT_TIMEOUT}s]: "
    
    # Read with timeout
    if read -t $USER_INPUT_TIMEOUT fix_kafka 2>/dev/null; then
      : # User provided input
    else
      # Timeout or read not supported with -t
      fix_kafka="n"
      echo
      echo "  ⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping Kafka broker secret fix..."
    fi
    
    if [ "$fix_kafka" = "y" ] || [ "$fix_kafka" = "Y" ]; then
      fix_kafka_broker_secret
      if [ $? -eq 0 ]; then
        echo
        echo "  ⏳ Waiting 10 seconds for broker to reconnect..."
        sleep 10
        echo
        echo "  🔄 Re-running Knative broker check to verify fix..."
        echo
        
        # Re-run the broker check recursively (but only once to avoid infinite loop)
        if [ "${KAFKA_FIX_RECHECK:-0}" -eq 0 ]; then
          export KAFKA_FIX_RECHECK=1
          check_knative_brokers
          local recheck_result=$?
          unset KAFKA_FIX_RECHECK
          
          # If still failing after secret fix, offer to delete and recreate brokers/triggers
          if [ $recheck_result -ne 0 ]; then
            echo
            echo "  ⚠️  Broker issue persists after certificate fix"
            echo "  ℹ️  This may require deleting and recreating the brokers and triggers"
            echo
            printf "  Would you like to delete and recreate brokers (knative-wa-clu-broker) and triggers (wo-wa-ke*)? (y/n) [auto-skip in ${USER_INPUT_TIMEOUT}s]: "
            
            # Read with timeout
            if read -t $USER_INPUT_TIMEOUT delete_recreate 2>/dev/null; then
              : # User provided input
            else
              delete_recreate="n"
              echo
              echo "  ⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping broker/trigger recreation..."
            fi
            
            if [ "$delete_recreate" = "y" ] || [ "$delete_recreate" = "Y" ]; then
              echo
              echo "  🗑️  Deleting brokers starting with 'knative-wa-clu-broker'..."
              $OCN get brokers.eventing.knative.dev --no-headers 2>/dev/null | awk '{print $1}' | grep "^knative-wa-clu-broker" | while read broker_name; do
                echo "     Deleting broker: $broker_name"
                $OCN delete broker "$broker_name" 2>/dev/null || echo "     Failed to delete $broker_name"
              done
              
              echo
              echo "  🗑️  Deleting triggers starting with 'wo-wa-ke'..."
              $OCN get triggers.eventing.knative.dev --no-headers 2>/dev/null | awk '{print $1}' | grep "^wo-wa-ke" | while read trigger_name; do
                echo "     Deleting trigger: $trigger_name"
                $OCN delete trigger "$trigger_name" 2>/dev/null || echo "     Failed to delete $trigger_name"
              done
              
              echo
              echo "  ✅ Deletion complete. The Watson Assistant operator should recreate these resources automatically."
              echo "  ℹ️  Please wait a few minutes for recreation, then re-run the health check"
            else
              echo
              echo "  ℹ️  Skipping broker/trigger recreation. You can manually run:"
              echo "     oc delete broker -n $PROJECT_CPD_INST_OPERANDS knative-wa-clu-broker"
              echo "     oc delete trigger -n $PROJECT_CPD_INST_OPERANDS \$(oc get triggers -n $PROJECT_CPD_INST_OPERANDS --no-headers | grep '^wo-wa-ke' | awk '{print \$1}')"
            fi
          fi
          
          return $recheck_result
        fi
      fi
    else
      echo
      echo "  ℹ️  Skipping Kafka broker secret fix. You can manually run:"
      echo "     cd /path/to/wa-cpd-support/Scripts && bash fix_kafka_broker_secret_value.sh"
    fi
    echo
  fi
  
  [ "$bad" -eq 0 ] && return 0 || return 1
}

check_knative_triggers() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  echo "▶ Checking Knative Triggers"
  
  tmp_triggers=`mktemp 2>/dev/null || echo "/tmp/wo_triggers.$$"`
  $OCN get triggers.eventing.knative.dev --no-headers 2>/dev/null > "$tmp_triggers" || :
  
  if [ ! -s "$tmp_triggers" ]; then
    echo "ℹ️  No Knative Triggers found in namespace $PROJECT_CPD_INST_OPERANDS"
    rm -f "$tmp_triggers"
    return 0
  fi
  
  bad=0
  trigger_count=0
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    broker="$(printf '%s\n' "$line" | awk '{print $2}')"
    subscriber_uri="$(printf '%s\n' "$line" | awk '{print $3}')"
    [ -z "${name:-}" ] && continue
    
    trigger_count=`expr "${trigger_count:-0}" + 1`
    
    # Get detailed status
    ready_status=`$OCN get trigger "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
    ready_reason=`$OCN get trigger "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || :`
    subscriber_status=`$OCN get trigger "$name" -o jsonpath='{.status.conditions[?(@.type=="SubscriberResolved")].status}' 2>/dev/null || :`
    
    if [ "${ready_status:-}" = "True" ]; then
      echo "  ✅ Trigger: $name"
      echo "     Broker: ${broker:-N/A}"
      echo "     Subscriber: ${subscriber_uri:-N/A}"
      echo "     Status: Ready"
    else
      echo "  ❌ Trigger: $name"
      echo "     Broker: ${broker:-N/A}"
      echo "     Subscriber: ${subscriber_uri:-N/A}"
      echo "     Ready Status: ${ready_status:-Unknown}"
      echo "     Ready Reason: ${ready_reason:-Unknown}"
      echo "     Subscriber Status: ${subscriber_status:-Unknown}"
      bad=1
    fi
    echo
  done < "$tmp_triggers"
  
  echo "  Total Triggers: $trigger_count"
  echo
  
  rm -f "$tmp_triggers"
  [ "$bad" -eq 0 ] && return 0 || return 1
}

# Pod remediation functions for troubleshoot mode
get_pod_logs() {
  pod_name="$1"
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  log_dir="./pod_logs_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$log_dir"
  
  echo "  📝 Collecting logs for pod: $pod_name"
  
  # Get all containers in the pod
  containers=$($OCN get pod "$pod_name" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
  
  for container in $containers; do
    echo "     - Container: $container"
    $OCN logs "$pod_name" -c "$container" > "$log_dir/${pod_name}_${container}.log" 2>&1 || :
    $OCN logs "$pod_name" -c "$container" --previous > "$log_dir/${pod_name}_${container}_previous.log" 2>/dev/null || :
  done
  
  echo "  ✅ Logs saved to: $log_dir"
}

get_last_errors() {
  pod_name="$1"
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  
  echo "  🔍 Pod: $pod_name"
  
  # Get all containers in the pod
  containers=$($OCN get pod "$pod_name" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
  
  # Common error keywords to search for
  error_patterns="error|exception|fatal|failed|panic|crash|killed|terminated|timeout|refused|denied|forbidden|unauthorized|unavailable|unreachable|cannot|unable|invalid|missing|not found|failure|core dumped|aborted"
  
  for container in $containers; do
    echo "     Container: $container"
    errors=$($OCN logs "$pod_name" -c "$container" --tail=500 2>/dev/null | grep -iE "$error_patterns" | grep -vi '"level"[[:space:]]*:[[:space:]]*"info"' | grep -vE "$LOG_NOISE_REGEX" | tail -5)
    if [ -n "$errors" ]; then
      echo "$errors" | while IFS= read -r line; do
        echo "       $line"
      done
    else
      echo "       (No errors found)"
    fi
    echo
  done
}

delete_pod() {
  pod_name="$1"
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  
  echo "  🗑️  Deleting pod: $pod_name"
  
  # Try to delete pod, capture output and exit code
  delete_output=$($OCN delete pod "$pod_name" --grace-period=30 2>&1) || delete_exit_code=$?
  
  if [ "${delete_exit_code:-0}" -eq 0 ]; then
    echo "$delete_output"
    echo "  ✅ Pod deleted successfully"
  else
    # Check if pod was already deleted (NotFound error)
    if echo "$delete_output" | grep -q "NotFound"; then
      echo "$delete_output"
      echo "  ℹ️  Pod already deleted or not found (this is OK)"
    else
      echo "$delete_output"
      echo "  ❌ Failed to delete pod"
    fi
  fi
}
list_recent_errors_all_pods() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  
  echo
  echo "▶ Recent Errors in All Orchestrate Pods"
  echo
  echo "Select time period to check:"
  echo "1. Last 1 minute"
  echo "2. Last 5 minutes"
  echo "3. Last 10 minutes"
  echo "4. Last 30 minutes"
  echo "5. Last 1 hour"
  echo "6. Last 6 hours"
  echo "7. Last 24 hours"
  echo "8. Custom (enter minutes)"
  echo
  printf "Enter your choice (1-8) [default: 5 minutes in ${USER_INPUT_TIMEOUT}s]: "
  
  # Read with timeout
  if read -t $USER_INPUT_TIMEOUT time_choice 2>/dev/null; then
    : # User provided input
  else
    # Timeout or read not supported with -t
    time_choice=""
    echo
    echo "⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, using default 5 minutes..."
  fi
  
  # Determine time period
  case "$time_choice" in
    1) time_period="1m"; time_desc="1 minute" ;;
    2|"") time_period="5m"; time_desc="5 minutes" ;;
    3) time_period="10m"; time_desc="10 minutes" ;;
    4) time_period="30m"; time_desc="30 minutes" ;;
    5) time_period="1h"; time_desc="1 hour" ;;
    6) time_period="6h"; time_desc="6 hours" ;;
    7) time_period="24h"; time_desc="24 hours" ;;
    8)
      printf "Enter number of minutes: "
      read custom_minutes </dev/tty
      if [ -n "$custom_minutes" ] && [ "$custom_minutes" -gt 0 ] 2>/dev/null; then
        time_period="${custom_minutes}m"
        time_desc="$custom_minutes minutes"
      else
        echo "Invalid input, using default 5 minutes"
        time_period="5m"
        time_desc="5 minutes"
      fi
      ;;
    *)
      echo "Invalid choice, using default 5 minutes"
      time_period="5m"
      time_desc="5 minutes"
      ;;
  esac
  
  echo
  echo "Checking errors from last $time_desc..."
  echo
  
  # Get all wo- and milvus pods (excluding Completed status)
  tmp_pods=`mktemp 2>/dev/null || echo "/tmp/wo_all_pods.$$"`
  $OCN get pods --no-headers 2>/dev/null | awk '($1 ~ /^wo-/ || $1 ~ /milvus/) && $3 != "Completed" {print $1}' > "$tmp_pods"
  
  if [ ! -s "$tmp_pods" ]; then
    echo "No Orchestrate pods found"
    rm -f "$tmp_pods"
    return 0
  fi
  
  # Common error keywords
  error_patterns="error|exception|fatal|failed|panic|crash|killed|terminated|timeout|refused|denied|forbidden|unauthorized|unavailable|unreachable|cannot|unable|invalid|missing|not found|failure|core dumped|aborted"
  
  pod_count=0
  error_found=0
  while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    pod_count=`expr "${pod_count:-0}" + 1`
    
    # Get containers in the pod
    containers=$($OCN get pod "$pod_name" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    
    for container in $containers; do
      # Get logs from specified time period and search for errors (exclude INFO level and known noise via LOG_NOISE_REGEX)
      errors=$($OCN logs "$pod_name" -c "$container" --since="$time_period" 2>/dev/null | grep -iE "$error_patterns" | grep -vi '"level"[[:space:]]*:[[:space:]]*"info"' | grep -vE "$LOG_NOISE_REGEX" | tail -5 || true)
      
      if [ -n "$errors" ]; then
        echo "  📦 Pod: $pod_name"
        echo "     Container: $container"
        
        # Check if pod has restarts and get termination reason
        restarts=$($OCN get pod "$pod_name" -o jsonpath='{.status.containerStatuses[?(@.name=="'"$container"'")].restartCount}' 2>/dev/null)
        if [ -n "$restarts" ] && [ "$restarts" -gt 0 ] 2>/dev/null; then
          term_reason=$($OCN get pod "$pod_name" -o jsonpath='{.status.containerStatuses[?(@.name=="'"$container"'")].lastState.terminated.reason}' 2>/dev/null)
          term_message=$($OCN get pod "$pod_name" -o jsonpath='{.status.containerStatuses[?(@.name=="'"$container"'")].lastState.terminated.message}' 2>/dev/null)
          term_exit_code=$($OCN get pod "$pod_name" -o jsonpath='{.status.containerStatuses[?(@.name=="'"$container"'")].lastState.terminated.exitCode}' 2>/dev/null)
          
          if [ -n "$term_reason" ]; then
            echo "     🔄 Restarts: $restarts | Terminated: $term_reason (exit code: ${term_exit_code:-unknown})"
            if [ -n "$term_message" ]; then
              echo "        Message: $term_message"
            fi
          fi
        fi
        
        echo "$errors" | while IFS= read -r line; do
          echo "       $line"
        done
        echo
        error_found=1
      fi
    done
  done < "$tmp_pods"
  
  if [ "$error_found" -eq 0 ]; then
    echo "  ✅ No errors found in the last $time_desc"
  fi
  
  echo
  echo "Checked $pod_count pods"
  echo
  
  rm -f "$tmp_pods"
}

check_and_fix_milvus_etcd() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  
  echo
  echo "▶ Checking Milvus Etcd Database Space"
  echo
  
  # Check if etcd pod exists
  etcd_pod=$($OCN get pods --no-headers 2>/dev/null | grep "milvus-etcd" | grep "Running" | awk '{print $1}' | head -1)
  
  if [ -z "$etcd_pod" ]; then
    echo "  ℹ️  No Milvus etcd pod found or pod not running"
    return 0
  fi
  
  echo "  📦 Found etcd pod: $etcd_pod"
  echo
  
  # Check for NOSPACE alarms in etcd pod itself
  echo "  🔍 Checking etcd pod for NOSPACE alarms..."
  space_error_found=0
  
  if $OCN logs "$etcd_pod" --tail=200 2>/dev/null | grep -q "ALARM NOSPACE"; then
    echo "  ⚠️  Found 'ALARM NOSPACE' in etcd pod: $etcd_pod"
    space_error_found=1
  fi
  
  # Check for database space exceeded errors in Milvus pods
  echo "  🔍 Checking Milvus pods for 'database space exceeded' errors..."
  milvus_pods=$($OCN get pods --no-headers 2>/dev/null | grep "milvus-standalone" | awk '{print $1}')
  
  for pod in $milvus_pods; do
    if $OCN logs "$pod" --tail=100 2>/dev/null | grep -qE "database space exceeded|mvcc: database space exceeded"; then
      echo "  ⚠️  Found 'database space exceeded' error in pod: $pod"
      space_error_found=1
    fi
  done
  
  if [ "$space_error_found" -eq 0 ]; then
    echo "  ✅ No etcd space issues found"
    return 0
  fi
  
  echo
  echo "  ❌ Etcd database space exceeded detected!"
  echo
  echo "  This requires compacting, defragmenting, and disarming the etcd database."
  echo
  printf "  Would you like to fix this automatically? (y/n) [auto-skip in ${USER_INPUT_TIMEOUT}s]: "
  
  # Read with timeout
  if read -t $USER_INPUT_TIMEOUT fix_etcd 2>/dev/null; then
    : # User provided input
  else
    # Timeout or read not supported with -t
    fix_etcd="n"
    echo
    echo "  ⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping etcd fix..."
  fi
  
  if [ "$fix_etcd" != "y" ] && [ "$fix_etcd" != "Y" ]; then
    echo
    echo "  ℹ️  Skipping etcd fix. You can manually run these commands:"
    echo "     1. Get current revision: oc exec -n $PROJECT_CPD_INST_OPERANDS $etcd_pod -- sh -lc 'ETCDCTL_API=3 etcdctl endpoint status --write-out=json'"
    echo "     2. Compact: oc exec -n $PROJECT_CPD_INST_OPERANDS $etcd_pod -- sh -lc 'ETCDCTL_API=3 etcdctl compact <revision>'"
    echo "     3. Defrag: oc exec -n $PROJECT_CPD_INST_OPERANDS $etcd_pod -- sh -lc 'ETCDCTL_API=3 etcdctl --command-timeout=300s defrag'"
    echo "     4. Disarm: oc exec -n $PROJECT_CPD_INST_OPERANDS $etcd_pod -- sh -lc 'ETCDCTL_API=3 etcdctl --command-timeout=300s alarm disarm'"
    return 0
  fi
  
  echo
  echo "  🔧 Fixing etcd database space issue..."
  echo
  echo "  ℹ️  When etcd has NOSPACE, defragmentation is the critical step."
  echo "  ℹ️  Compaction may timeout but defrag should still work."
  echo
  
  # Step 1: Get current revision (with fallback)
  echo "  1️⃣  Getting current etcd revision..."
  revision=$($OCN exec "$etcd_pod" -- sh -lc 'ETCDCTL_API=3 etcdctl endpoint status --write-out=json' 2>/dev/null | jq -r '.[0].Status.header.revision' 2>/dev/null)
  
  skip_compact=false
  if [ -z "$revision" ] || [ "$revision" = "null" ]; then
    echo "  ⚠️  Cannot get revision (etcd is unresponsive due to NOSPACE)"
    echo "  ℹ️  Skipping compact step and going directly to defragmentation"
    skip_compact=true
  else
    echo "  ✅ Current revision: $revision"
  fi
  echo
  
  # Step 2: Compact (only if we got a valid revision)
  if [ "$skip_compact" = false ]; then
    echo "  2️⃣  Compacting etcd database to revision $revision (timeout: 60s)..."
    compact_output=$($OCN exec "$etcd_pod" -- sh -lc "ETCDCTL_API=3 etcdctl --command-timeout=300s compact $revision" 2>&1)
    compact_exit=$?
    
    if [ $compact_exit -eq 0 ]; then
      echo "  ✅ Compaction completed successfully"
    else
      # Check if it's just because revision is too high (which is OK)
      if echo "$compact_output" | grep -q "required revision has been compacted"; then
        echo "  ✅ Database already compacted (this is OK)"
      elif echo "$compact_output" | grep -q "context deadline exceeded"; then
        echo "  ⚠️  Compaction timed out (etcd may be severely degraded)"
        echo "  ℹ️  Proceeding with defragmentation - this is the critical step..."
      else
        echo "  ⚠️  Compaction output: $compact_output"
        echo "  ℹ️  Proceeding with defragmentation anyway..."
      fi
    fi
    echo
  else
    echo "  2️⃣  Skipping compaction (etcd unresponsive)"
    echo
  fi
  
  # Step 3: Defragment (with live size tracking and retry logic)
  echo "  3️⃣  Defragmenting etcd database (this may take up to 5 minutes)..."
  
  # Get database size before defrag (try multiple paths)
  echo "  📊 Checking database size before defragmentation..."
  db_size_before=$($OCN exec "$etcd_pod" -- sh -lc 'du -sh /etcd/member 2>/dev/null || du -sh /bitnami/etcd/data/member 2>/dev/null' 2>/dev/null | awk '{print $1}')
  db_file_before=$($OCN exec "$etcd_pod" -- sh -lc 'ls -lh /etcd/member/snap/db 2>/dev/null || ls -lh /bitnami/etcd/data/member/snap/db 2>/dev/null' 2>/dev/null | awk '{print $5}')
  
  if [ -n "$db_size_before" ]; then
    echo "     Database directory size: $db_size_before"
    if [ -n "$db_file_before" ]; then
      echo "     Database file size: $db_file_before"
    fi
  else
    echo "     (Unable to check size - may be inaccessible due to NOSPACE)"
  fi
  
  # Retry defragmentation up to 3 times
  max_defrag_attempts=3
  defrag_attempt=1
  defrag_success=false
  
  while [ $defrag_attempt -le $max_defrag_attempts ] && [ "$defrag_success" = false ]; do
    if [ $defrag_attempt -gt 1 ]; then
      echo
      echo "  🔄 Retry attempt $defrag_attempt of $max_defrag_attempts..."
      sleep 5
    fi
    
    # Run defragmentation in background with progress monitoring
    echo "  🔧 Running defragmentation with live progress monitoring (attempt $defrag_attempt/$max_defrag_attempts)..."
    
    # Create temp file for defrag output
    defrag_log=$(mktemp 2>/dev/null || echo "/tmp/defrag_log.$$")
    
    # Start defrag in background
    ($OCN exec "$etcd_pod" -- sh -lc 'ETCDCTL_API=3 etcdctl --command-timeout=300s defrag' > "$defrag_log" 2>&1) &
    defrag_pid=$!
    
    # Monitor progress while defrag is running
    echo "     Monitoring defragmentation progress..."
    monitor_count=0
    last_size=""
    last_mtime=""
    no_change_count=0
    stuck_threshold=6  # 60 seconds without changes = likely stuck
    
    while kill -0 $defrag_pid 2>/dev/null; do
      sleep 10
      monitor_count=$((monitor_count + 1))
      
      # Check database file size and modification time
      db_info=$($OCN exec "$etcd_pod" -- sh -lc 'stat -c "%s %Y" /etcd/member/snap/db 2>/dev/null || stat -c "%s %Y" /bitnami/etcd/data/member/snap/db 2>/dev/null' 2>/dev/null)
      current_size_bytes=$(echo "$db_info" | awk '{print $1}')
      current_mtime=$(echo "$db_info" | awk '{print $2}')
      
      if [ -n "$current_size_bytes" ]; then
        # Convert bytes to human readable
        current_size_mb=$((current_size_bytes / 1024 / 1024))
        current_size="${current_size_mb}M"
        
        if [ "$current_size" != "$last_size" ] || [ "$current_mtime" != "$last_mtime" ]; then
          echo "     [${monitor_count}0s] Database: ${current_size} (file modified: $(date -d @${current_mtime} '+%H:%M:%S' 2>/dev/null || echo 'recently'))"
          last_size="$current_size"
          last_mtime="$current_mtime"
          no_change_count=0
        else
          no_change_count=$((no_change_count + 1))
          echo "     [${monitor_count}0s] Defragmentation in progress... (size: $current_size, no changes for ${no_change_count}0s)"
          
          # Check if defrag appears stuck
          if [ $no_change_count -ge $stuck_threshold ]; then
            echo
            echo "  ⚠️  Defragmentation appears stuck (no file changes for ${no_change_count}0 seconds)"
            echo "  ℹ️  This can happen when etcd is severely degraded due to NOSPACE"
            echo
            printf "  Would you like to kill defrag and restart the etcd pod? (y/n) [auto-continue in 15s]: "
            
            if read -t 15 restart_choice 2>/dev/null; then
              : # User provided input
            else
              restart_choice="n"
              echo
              echo "  ⏱️  No input received, continuing to wait for defrag..."
            fi
            
            if [ "$restart_choice" = "y" ] || [ "$restart_choice" = "Y" ]; then
              echo
              echo "  🔄 Killing stuck defrag process..."
              kill $defrag_pid 2>/dev/null || true
              wait $defrag_pid 2>/dev/null || true
              
              echo "  🔄 Restarting etcd pod to clear locks..."
              $OCN delete pod "$etcd_pod" --grace-period=30
              
              echo "  ⏳ Waiting for etcd pod to restart..."
              sleep 30
              
              # Wait for pod to be ready
              timeout=120
              start=$(date +%s)
              while true; do
                if $OCN get pod "$etcd_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                  echo "  ✅ Etcd pod restarted successfully"
                  echo
                  echo "  ℹ️  After restart, you may need to:"
                  echo "     1. Re-run the health check script"
                  echo "     2. Try the defrag operation again"
                  echo "     3. Check if NOSPACE alarm is cleared"
                  return 2  # Special return code to indicate restart happened
                fi
                sleep 5
                now=$(date +%s)
                if [ $((now - start)) -gt $timeout ]; then
                  echo "  ⚠️  Timeout waiting for etcd pod to restart"
                  return 1
                fi
              done
            else
              echo "  ℹ️  Continuing to wait for defrag to complete..."
              no_change_count=0  # Reset counter to avoid repeated prompts
            fi
          fi
        fi
      else
        echo "     [${monitor_count}0s] Defragmentation in progress... (cannot access database file)"
      fi
    done
    
    # Wait for defrag to complete and get exit code
    wait $defrag_pid
    defrag_exit=$?
    defrag_output=$(cat "$defrag_log" 2>/dev/null)
    rm -f "$defrag_log"
    
    if [ $defrag_exit -eq 0 ]; then
      echo "  ✅ Defragmentation completed successfully"
      defrag_success=true
      
      # Get final database size
      sleep 2  # Brief pause to let filesystem update
      db_size_after=$($OCN exec "$etcd_pod" -- sh -lc 'du -sh /etcd/member 2>/dev/null || du -sh /bitnami/etcd/data/member 2>/dev/null' 2>/dev/null | awk '{print $1}')
      db_file_after=$($OCN exec "$etcd_pod" -- sh -lc 'ls -lh /etcd/member/snap/db 2>/dev/null || ls -lh /bitnami/etcd/data/member/snap/db 2>/dev/null' 2>/dev/null | awk '{print $5}')
      
      if [ -n "$db_size_after" ]; then
        echo "     📊 Final database directory size: $db_size_after"
        if [ -n "$db_file_after" ]; then
          echo "     📊 Final database file size: $db_file_after"
        fi
        if [ -n "$db_size_before" ]; then
          echo "     ✨ Space reclaimed: $db_size_before → $db_size_after"
          if [ -n "$db_file_before" ] && [ -n "$db_file_after" ]; then
            echo "     ✨ File size change: $db_file_before → $db_file_after"
          fi
        fi
      fi
    else
      echo "  ❌ Defragmentation failed (attempt $defrag_attempt/$max_defrag_attempts)"
      echo "     Output: $defrag_output"
      
      if [ $defrag_attempt -lt $max_defrag_attempts ]; then
        echo "  ℹ️  Will retry defragmentation..."
      else
        echo "  ❌ All defragmentation attempts exhausted"
        return 1
      fi
    fi
    
    defrag_attempt=$((defrag_attempt + 1))
  done
  
  if [ "$defrag_success" = false ]; then
    echo "  ❌ Defragmentation failed after $max_defrag_attempts attempts"
    return 1
  fi
  echo
  
  # Step 4: Disarm alarms
  echo "  4️⃣  Disarming etcd alarms..."
  if $OCN exec "$etcd_pod" -- sh -lc 'ETCDCTL_API=3 etcdctl --command-timeout=300s alarm disarm' 2>&1; then
    echo "  ✅ Alarms disarmed successfully"
  else
    echo "  ⚠️  Failed to disarm alarms or no alarms present"
  fi
  echo
  
  echo "  ✅ Etcd database space fix completed!"
  echo "  ℹ️  You may need to delete the failing Milvus pod to restart it with the fixed etcd"
  echo
  
  return 0
}


handle_bad_pods() {
  tmp_bad="$1"
  
  if [ ! -s "$tmp_bad" ]; then
    return 0
  fi
  
  echo
  echo "▶ Pod Remediation Options"
  echo
  echo "1. List errors in failing pods only (no deletion)"
  echo "2. Delete failing pods immediately"
  echo "3. Take logs backup and delete failing pods"
  echo "4. List errors in failing pods and then delete"
  echo "5. Take backup, list errors and delete failing pods"
  echo "6. List recent errors in ALL Orchestrate pods"
  echo "7. Skip remediation"
  echo
  printf "Enter your choice (1-7) [auto-skip in ${USER_INPUT_TIMEOUT}s]: "
  
  # Read with timeout
  if read -t $USER_INPUT_TIMEOUT choice 2>/dev/null; then
    : # User provided input
  else
    # Timeout or read not supported with -t
    choice="7"
    echo
    echo "⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping remediation and continuing with health checks..."
  fi
  
  case "$choice" in
    1)
      echo
      echo "Listing errors in bad pods..."
      echo
      while IFS=$'\t' read -r name ready status restarts age; do
        [ -z "$name" ] && continue
        get_last_errors "$name"
      done < "$tmp_bad"
      ;;
    2)
      echo
      echo "Deleting pods..."
      echo
      while IFS=$'\t' read -r name ready status restarts age; do
        [ -z "$name" ] && continue
        delete_pod "$name"
        echo
      done < "$tmp_bad"
      ;;
    3)
      echo
      echo "Taking logs backup and deleting pods..."
      echo
      while IFS=$'\t' read -r name ready status restarts age; do
        [ -z "$name" ] && continue
        get_pod_logs "$name"
        echo
        delete_pod "$name"
        echo
      done < "$tmp_bad"
      ;;
    4)
      echo
      echo "Listing errors and deleting pods..."
      echo
      while IFS=$'\t' read -r name ready status restarts age; do
        [ -z "$name" ] && continue
        get_last_errors "$name"
        delete_pod "$name"
        echo
      done < "$tmp_bad"
      ;;
    5)
      echo
      echo "Taking backup, listing errors and deleting pods..."
      echo
      while IFS=$'\t' read -r name ready status restarts age; do
        [ -z "$name" ] && continue
        get_pod_logs "$name"
        echo
        get_last_errors "$name"
        delete_pod "$name"
        echo
      done < "$tmp_bad"
      ;;
    6)
      list_recent_errors_all_pods
      ;;
    7|*)
      echo
      echo "Skipping remediation and continuing with health checks..."
      ;;
  esac
  
  echo "=========================================="
  echo
}

check_wo_pods_troubleshoot() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  bad_found=0
  total_wo=0
  echo "▶ Checking Orchestrate pods (including Milvus)"
  tmp_list=`mktemp 2>/dev/null || echo "/tmp/wo_pods.$$"`
  tmp_bad=`mktemp 2>/dev/null || echo "/tmp/wo_bad.$$"`
  $OCN get pods --no-headers 2>/dev/null > "$tmp_list" || :
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    ready="$(printf '%s\n' "$line" | awk '{print $2}')"
    status="$(printf '%s\n' "$line" | awk '{print $3}')"
    restarts="$(printf '%s\n' "$line" | awk '{print $4}')"
    age="$(printf '%s\n' "$line" | awk '{print $NF}')"
    [ -z "$name" ] && continue
    case "$name" in wo-*|*milvus*) : ;; *) continue ;; esac
    total_wo=`expr "${total_wo:-0}" + 1`
    if [ "$status" = "Completed" ]; then continue; fi
    current=`echo "$ready" | awk -F/ '{print $1}'`
    total=`echo "$ready" | awk -F/ '{print $2}'`
    if [ "$status" = "Running" ] && [ "$current" = "$total" ]; then :; else
      printf "%s\t%s\t%s\t%s\t%s\n" "$name" "$ready" "$status" "${restarts:-?}" "${age:-?}" >> "$tmp_bad"
      bad_found=1
    fi
  done < "$tmp_list"

  if [ "${total_wo:-0}" -eq 0 ]; then
    echo "❌ No pods found with prefix 'wo-' in namespace $PROJECT_CPD_INST_OPERANDS."
    rm -f "$tmp_list" "$tmp_bad"
    return 1
  fi
  if [ "${bad_found:-0}" -eq 0 ]; then
    echo "✅ All Orchestrate pods are healthy"
    echo
    printf "Would you like to check pod logs anyway? (y/n) [auto-skip in ${USER_INPUT_TIMEOUT}s]: "
    
    # Read with timeout
    if read -t $USER_INPUT_TIMEOUT check_logs_response 2>/dev/null; then
      : # User provided input
    else
      # Timeout or read not supported with -t
      check_logs_response="n"
      echo
      echo "⏱️  No input received within ${USER_INPUT_TIMEOUT} seconds, skipping log check..."
    fi
    
    if [ "$check_logs_response" = "y" ] || [ "$check_logs_response" = "Y" ]; then
      echo
      list_recent_errors_all_pods
    fi
    rm -f "$tmp_list" "$tmp_bad"
    return 0
  else
    echo "❌ Some pods are not healthy. Pods with issues:"
    printf "%-55s %-8s %-22s %-10s %-10s\n" "NAME" "READY" "STATUS" "RESTARTS" "AGE"
    printf "%-55s %-8s %-22s %-10s %-10s\n" "----" "-----" "------" "--------" "---"
    awk -F"\t" '{printf "%-55s %-8s %-22s %-10s %-10s\n",$1,$2,$3,$4,$5}' "$tmp_bad"
    
    # Offer remediation options
    handle_bad_pods "$tmp_bad"
    
    rm -f "$tmp_list" "$tmp_bad"
    return 0
  fi
}

run_troubleshoot_mode() {
  echo
  echo "▶ Troubleshoot Mode"
  echo
  
  # Check operators first
  check_orchestrate_operators
  echo
  
  # Check and fix Milvus etcd database space issues
  check_and_fix_milvus_etcd
  echo
  
  # Check pods with remediation options
  check_wo_pods_troubleshoot
  echo
  
  # Check if agentic_assistant or agentic_skills_assistant edition
  if [ "${WXO_EDITION:-unknown}" = "agentic_assistant" ] || [ "${WXO_EDITION:-unknown}" = "agentic_skills_assistant" ]; then
    echo "Running eventing checks for ${WXO_EDITION} edition..."
    echo
    
    # Check Knative Eventing Infrastructure
    echo "▶ Checking Knative Eventing Infrastructure"
    if check_knative_eventing_deployment; then
      echo "  ✅ All Knative Eventing deployment checks passed (OpenShift Serverless + Knative Eventing)"
    else
      echo "  ⚠️  Some Knative Eventing deployment checks failed (see details above)"
    fi
    if check_ibm_events_operator; then
      echo "  ✅ IBM Events Operator deployment is ready"
    else
      echo "  ⚠️  IBM Events Operator checks failed (see details above)"
    fi
    if check_kafka_cluster; then
      echo "  ✅ Kafka cluster is ready (CR, pods, entity operator)"
    else
      echo "  ⚠️  Some Kafka cluster checks failed (see details above)"
    fi
    if check_kafka_user_and_secret; then
      echo "  ✅ Kafka user (ke-kafka-user) and broker secret (ke-kafka-broker-secret) are ready"
    else
      echo "  ⚠️  Kafka user or broker secret checks failed (see details above)"
    fi
    if check_knative_kafka; then
      echo "  ✅ KnativeKafka CR and deployments are ready"
    else
      echo "  ⚠️  Some Knative Kafka checks failed (see details above)"
    fi
    echo
    
    # Check Knative Brokers
    check_knative_brokers || :
    
    # Check Knative Triggers
    check_knative_triggers || :
    
    # Check Watson Assistant operator verification if Assistant CR has issues
    echo
    wa_name=`$OC -n $PROJECT_CPD_INST_OPERANDS get wa --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
    if [ -n "$wa_name" ]; then
      wa_ready=`$OC -n $PROJECT_CPD_INST_OPERANDS get wa "$wa_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
      wa_status=`$OC -n $PROJECT_CPD_INST_OPERANDS get wa "$wa_name" -o jsonpath='{.status.watsonAssistantStatus}' 2>/dev/null || :`
      wa_progress=`$OC -n $PROJECT_CPD_INST_OPERANDS get wa "$wa_name" -o jsonpath='{.status.progress}' 2>/dev/null || :`
      
      if [ "$wa_ready" != "True" ] || [ "$wa_status" != "Completed" ] || [ "$wa_progress" != "100%" ]; then
        echo "▶ Watson Assistant CR shows issues - checking operator verification"
        check_wa_operator_verification
      fi
    fi
  else
    echo "Troubleshoot mode is enabled but no edition-specific checks configured for: ${WXO_EDITION:-unknown}"
    echo
    echo "Available for agentic_assistant and agentic_skills_assistant editions:"
    echo "  - Knative Brokers status check"
    echo "  - Knative Triggers status check"
    echo
  fi
  
  echo "=========================================="
  echo
}

# Function to run all health checks
# Parameter: skip_troubleshoot_items (optional) - set to 1 to skip items already checked in troubleshoot mode
run_health_checks() {
  local skip_troubleshoot_items="${1:-0}"
  
  pods_ok=0; wo_cr_ok=0; wocs_ok=0; wa_cr_ok=0; ifm_cr_ok=0
  docproc_ok=0; de_ok=0; uab_ok=0
  edb_ok=0; kafka_ok=0; redis_ok=0; obc_ok=0; wxd_ok=0; jobs_ok=0; knative_eventing_ok=0; operators_ok=0

  # Check operators first (unless skipped in troubleshoot mode)
  if [ "$skip_troubleshoot_items" -eq 0 ]; then
    section "Checking Operators"
    operators_ok=1; if check_orchestrate_operators; then operators_ok=0; fi
  else
    # Operators already checked in troubleshoot mode, mark as ok
    operators_ok=0
  fi

  if [ "${CHECK_WO_PODS:-1}" -eq 1 ]; then pods_ok=1; if check_wo_pods; then pods_ok=0; fi; fi

  section "Checking Orchestrate Jobs"
  if [ "${CHECK_JOBS:-1}" -eq 1 ]; then jobs_ok=1; if check_jobs; then jobs_ok=0; fi; fi

  section "Checking Orchestrate and supporting Custom Resources"
  if [ "${CHECK_WO_CR:-1}"  -eq 1 ]; then wo_cr_ok=1; if check_wo_cr; then wo_cr_ok=0; fi; fi
  if [ "${CHECK_WOCS:-1}"   -eq 1 ]; then wocs_ok=1; if check_wocomponentservices; then wocs_ok=0; fi; fi

  if [ "${WXO_EDITION:-unknown}" = "agentic" ] || [ "${WXO_EDITION:-unknown}" = "agentic_assistant" ]; then
    OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
    wa_present=`$OCN get wa --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    ifm_present=`$OCN get watsonxaiifm --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    doc_present=`$OCN get documentprocessings.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    de_present=`$OCN get digitalemployees.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    uab_present=`$OCN get uabautomationdecisionservices.uab.ba.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`

    if [ -n "$wa_present" ]  && [ "${CHECK_WA_CR:-1}"   -eq 1 ]; then wa_cr_ok=1;   if check_wa_cr; then wa_cr_ok=0; fi; fi
    if [ -n "$ifm_present" ] && [ "${CHECK_IFM_CR:-1}"  -eq 1 ]; then ifm_cr_ok=1;  if check_ifm_cr; then ifm_cr_ok=0; fi; fi
    if [ -n "$doc_present" ] && [ "${CHECK_DOCPROC:-1}" -eq 1 ]; then
      if is_docproc_enabled_in_wo; then
        docproc_ok=1; if check_docproc; then docproc_ok=0; fi
      else
        echo "ℹ️ DocumentProcessing not enabled in wo CR, skipping"
      fi
    fi
    if [ -n "$de_present" ]  && [ "${CHECK_DE:-1}"      -eq 1 ]; then de_ok=1;      if check_digital_employees; then de_ok=0; fi; fi
    if [ -n "$uab_present" ] && [ "${CHECK_UAB_ADS:-1}" -eq 1 ]; then uab_ok=1;     if check_uab_ads; then uab_ok=0; fi; fi
  else
    if [ "${CHECK_WA_CR:-1}"   -eq 1 ]; then wa_cr_ok=1;   if check_wa_cr; then wa_cr_ok=0; fi; fi
    if [ "${CHECK_IFM_CR:-1}" -eq 1 ]; then
      if is_ifm_enabled_in_wo; then
        ifm_cr_ok=1; if check_ifm_cr; then ifm_cr_ok=0; fi
      else
        echo "ℹ️ IFM disabled in wo CR, skipping"
      fi
    fi
    if [ "${CHECK_DOCPROC:-1}" -eq 1 ]; then
      if [ "${WXO_EDITION:-unknown}" = "full" ]; then
        docproc_ok=1; if check_docproc; then docproc_ok=0; fi
      else
        if is_docproc_enabled_in_wo; then
          docproc_ok=1; if check_docproc; then docproc_ok=0; fi
        else
          echo "ℹ️ DocumentProcessing not enabled in wo CR, skipping"
        fi
      fi
    fi
    if [ "${CHECK_DE:-1}"      -eq 1 ]; then de_ok=1;      if check_digital_employees; then de_ok=0; fi; fi
    if [ "${CHECK_UAB_ADS:-1}" -eq 1 ]; then uab_ok=1;     if check_uab_ads; then uab_ok=0; fi; fi
  fi

  section "Checking Datastores"
  if [ "${CHECK_EDB:-1}"   -eq 1 ]; then edb_ok=1;   if check_edb_clusters; then edb_ok=0; fi; fi
  if [ "${CHECK_KAFKA:-1}" -eq 1 ]; then kafka_ok=1; if check_kafka_readiness; then kafka_ok=0; fi; fi
  if [ "${CHECK_REDIS:-1}" -eq 1 ]; then redis_ok=1; if check_redis_cp; then redis_ok=0; fi; fi
  
  # Check Knative Eventing (unless skipped in troubleshoot mode)
  if [ "$skip_troubleshoot_items" -eq 0 ]; then
    if [ "${CHECK_KNATIVE_EVENTING:-1}" -eq 1 ]; then
      if [ "${WXO_EDITION:-unknown}" = "agentic_assistant" ] || [ "${WXO_EDITION:-unknown}" = "agentic_skills_assistant" ]; then
        section "Checking Knative Eventing (for agentic editions)"
        knative_eventing_ok=1
        if check_knative_eventing_deployment && check_ibm_events_operator && check_kafka_cluster && check_kafka_user_and_secret && check_knative_kafka; then
          knative_eventing_ok=0
        fi
      else
        # Not applicable for this edition, skip silently
        knative_eventing_ok=0
      fi
    fi
  else
    # Knative Eventing already checked in troubleshoot mode, mark as ok
    knative_eventing_ok=0
  fi

  if [ "${CHECK_OBC:-1}"  -eq 1 ]; then obc_ok=1;  if check_obc; then obc_ok=0; fi; fi
  if [ "${CHECK_WXD:-1}"  -eq 1 ]; then wxd_ok=1;  if check_wxd_engines; then wxd_ok=0; fi; fi
}

# --------------------- Main retry loop ----------------------
resolve_namespaces
detect_wxo_edition

trap 'echo; echo "Interrupted. Exiting."; exit 1' INT TERM

# Run configuration mode if enabled (exits after completion)
if [ "${CONFIG_MODE:-0}" -eq 1 ]; then
  run_configuration_mode
  # Configuration mode exits within the function, so this line is never reached
fi

# Show troubleshoot warning BEFORE header (if troubleshoot mode is enabled)
if [ "${TROUBLESHOOT_MODE:-0}" -eq 1 ] && [ "${SKIP_WARNING:-0}" -eq 0 ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║                        TROUBLESHOOT MODE WARNING                             ║"
  echo "╠══════════════════════════════════════════════════════════════════════════════╣"
  echo "║                                                                              ║"
  echo "║  Troubleshoot mode performs advanced diagnostic and remediation operations   ║"
  echo "║  that may impact your running environment. This mode should ONLY be used:    ║"
  echo "║                                                                              ║"
  echo "║    • When working directly with IBM Support                                  ║"
  echo "║    • At the explicit recommendation of IBM Support personnel                 ║"
  echo "║    • Under the guidance of qualified technical support staff                 ║"
  echo "║                                                                              ║"
  echo "║  Do NOT use troubleshoot mode for routine health checks or without           ║"
  echo "║  proper authorization and supervision from IBM Support.                      ║"
  echo "║                                                                              ║"
  echo "║  Tip: Use --yes or -y to bypass this warning in future runs.                 ║"
  echo "║                                                                              ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  read -p "Press Enter to continue or Ctrl+C to cancel..." </dev/tty
  echo ""
fi

# Print header once at the beginning (includes author credit)
print_header

# Run troubleshoot mode if enabled - run troubleshoot + full health check in each cycle until healthy
if [ "${TROUBLESHOOT_MODE:-0}" -eq 1 ]; then

  TRY=1
  while [ "$TRY" -le "$MAX_TRIES" ]; do
    echo
    echo "=========================================="
    echo "🔄 TROUBLESHOOT + HEALTH CHECK CYCLE $TRY of $MAX_TRIES"
    echo "=========================================="
    
    # Run troubleshoot diagnostics first
    run_troubleshoot_mode
    echo
    
    # Now run full health check (skip operators since already checked in troubleshoot)
    run_health_checks 1

    if [ "$operators_ok" -eq 0 ] && [ "$pods_ok" -eq 0 ] && [ "$wo_cr_ok" -eq 0 ] && [ "$wocs_ok" -eq 0 ] \
       && [ "$wa_cr_ok" -eq 0 ] && [ "$ifm_cr_ok" -eq 0 ] \
       && [ "$docproc_ok" -eq 0 ] && [ "$de_ok" -eq 0 ] && [ "$uab_ok" -eq 0 ] \
       && [ "$edb_ok" -eq 0 ] && [ "$kafka_ok" -eq 0 ] && [ "$redis_ok" -eq 0 ] && [ "$obc_ok" -eq 0 ] && [ "$wxd_ok" -eq 0 ] \
       && [ "$jobs_ok" -eq 0 ] && [ "$knative_eventing_ok" -eq 0 ]; then
      echo "🎉 All enabled checks passed on attempt $TRY. Orchestrate is healthy."
      exit 0
    fi

    if [ "$TRY" -lt "$MAX_TRIES" ]; then
      echo
      echo "🔁 Attempt $TRY failed. Rechecking in ${SLEEP_SECS}s ... Ctrl-C to stop"
      sleep "$SLEEP_SECS"
      echo
    fi

    TRY=`expr "$TRY" + 1`
  done

  echo "❌ Exhausted MAX_TRIES=$MAX_TRIES without passing all enabled checks. Exiting with code 1."
  exit 1
else
  # Regular health check mode (no troubleshooting)
  TRY=1
  while [ "$TRY" -le "$MAX_TRIES" ]; do
    echo
    echo "=========================================="
    echo "🔄 HEALTH CHECK CYCLE $TRY of $MAX_TRIES"
    echo "=========================================="

    # Run health checks
    run_health_checks

    if [ "$operators_ok" -eq 0 ] && [ "$pods_ok" -eq 0 ] && [ "$wo_cr_ok" -eq 0 ] && [ "$wocs_ok" -eq 0 ] \
       && [ "$wa_cr_ok" -eq 0 ] && [ "$ifm_cr_ok" -eq 0 ] \
       && [ "$docproc_ok" -eq 0 ] && [ "$de_ok" -eq 0 ] && [ "$uab_ok" -eq 0 ] \
       && [ "$edb_ok" -eq 0 ] && [ "$kafka_ok" -eq 0 ] && [ "$redis_ok" -eq 0 ] && [ "$obc_ok" -eq 0 ] && [ "$wxd_ok" -eq 0 ] \
       && [ "$jobs_ok" -eq 0 ] && [ "$knative_eventing_ok" -eq 0 ]; then
      echo "🎉 All enabled checks passed on attempt $TRY. Orchestrate is healthy."
      exit 0
    fi

    if [ "$TRY" -lt "$MAX_TRIES" ]; then
      echo
      echo "🔁 Attempt $TRY failed. Rechecking in ${SLEEP_SECS}s ... Ctrl-C to stop"
      sleep "$SLEEP_SECS"
      echo
    fi

    TRY=`expr "$TRY" + 1`
  done

  echo "❌ Exhausted MAX_TRIES=$MAX_TRIES without passing all enabled checks. Exiting with code 1."
  exit 1
fi


