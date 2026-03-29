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
#    -n, --namespace NAMESPACE   Override operands namespace
#    --assume-agentic            Assume agentic edition
#    --assume-agentic-skills     Assume agentic_skills_assistant edition
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
# Debug mode - disabled by default
: "${DEBUG_MODE:=0}"
: "${USER_INPUT_TIMEOUT:=10}"  # Timeout in seconds for user input prompts

# ---------------------- Arg parsing -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) OVERRIDE_NS="$2"; shift 2 ;;
    --assume-agentic)  ASSUME_EDITION="agentic"; shift 1 ;;
    --assume-agentic-skills)  ASSUME_EDITION="agentic_skills_assistant"; shift 1 ;;
    -t|--troubleshoot) TROUBLESHOOT_MODE=1; shift 1 ;;
    -d|--debug) DEBUG_MODE=1; shift 1 ;;
    -h|--help) sed -n '1,220p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ------------------------ Utilities -------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
OC="oc"

print_rule() { echo "------------------------------------------------------------"; }

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

print_header() {
  print_rule
  echo "⏱  $(ts)  Checking Orchestrate health in OPERANDS namespace: $PROJECT_CPD_INST_OPERANDS (operators: ${PROJECT_CPD_INST_OPERATORS:-none})"
  echo "    Edition: ${WXO_EDITION:-unknown}${WXO_DETECT_NOTE:+  (${WXO_DETECT_NOTE})}"
  get_wo_models_info
  print_rule
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
      echo "✅ EDB cluster $n: Ready=$ready/$instances, Status=$status_text"
    else
      echo "❌ EDB cluster $n: Ready=$ready/$instances, Status=${status_text:-Unknown}"
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
  
  echo "▶ Checking watsonx Orchestrate Operators"
  
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
  
  # Check Watson Assistant operator if in agentic-assistant mode
  if [ "${WXO_EDITION:-unknown}" = "agentic_assistant" ] || [ "${WXO_EDITION:-unknown}" = "agentic_skills_assistant" ]; then
    echo
    echo "▶ Checking Watson Assistant Operator (agentic edition detected)"
    
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
  events_deploy=""
  for dep_name in ibm-events-cluster-operator ibm-events-operator; do
    if $OC get deployment "$dep_name" -n "$events_ns" >/dev/null 2>&1; then
      events_deploy="$dep_name"
      break
    fi
  done
  
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
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | awk '{print $1}')"
    url="$(printf '%s\n' "$line" | awk '{print $2}')"
    [ -z "${name:-}" ] && continue
    
    # Get detailed status
    ready_status=`$OCN get broker "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
    ready_reason=`$OCN get broker "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || :`
    
    if [ "${ready_status:-}" = "True" ]; then
      echo "  ✅ Broker: $name"
      echo "     URL: ${url:-N/A}"
      echo "     Status: Ready"
    else
      echo "  ❌ Broker: $name"
      echo "     URL: ${url:-N/A}"
      echo "     Status: ${ready_status:-Unknown}"
      echo "     Reason: ${ready_reason:-Unknown}"
      bad=1
    fi
    echo
  done < "$tmp_brokers"
  
  rm -f "$tmp_brokers"
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
  error_patterns="error|exception|fatal|failed|panic|crash|killed|terminated|timeout|refused|denied|forbidden|unauthorized|unavailable|unreachable|cannot|unable|invalid|missing|not found|failure"
  
  for container in $containers; do
    echo "     Container: $container"
    errors=$($OCN logs "$pod_name" -c "$container" --tail=500 2>/dev/null | grep -iE "$error_patterns" | tail -5)
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
  echo "=========================================="
  echo "🔍 RECENT ERRORS IN ALL ORCHESTRATE PODS"
  echo "=========================================="
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
  error_patterns="error|exception|fatal|failed|panic|crash|killed|terminated|timeout|refused|denied|forbidden|unauthorized|unavailable|unreachable|cannot|unable|invalid|missing|not found|failure"
  
  pod_count=0
  error_found=0
  while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    pod_count=`expr "${pod_count:-0}" + 1`
    
    # Get containers in the pod
    containers=$($OCN get pod "$pod_name" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    
    for container in $containers; do
      # Get logs from specified time period and search for errors (exclude INFO/info level, Redis background saving, and wo-uiproxy session warnings)
      errors=$($OCN logs "$pod_name" -c "$container" --since="$time_period" 2>/dev/null | grep -iE "$error_patterns" | grep -vi '"level"[[:space:]]*:[[:space:]]*"info"' | grep -v "Background saving terminated with success" | grep -v "WXO Session cookie missing" | grep -v "Bearer token not found in the request header" | tail -5 || true)
      
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
    echo
  fi
  
  echo "Checked $pod_count pods"
  echo "=========================================="
  echo
  
  rm -f "$tmp_pods"
}


handle_bad_pods() {
  tmp_bad="$1"
  
  if [ ! -s "$tmp_bad" ]; then
    return 0
  fi
  
  echo
  echo "=========================================="
  echo "🔧 POD REMEDIATION OPTIONS"
  echo "=========================================="
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
  echo "=========================================="
  echo "🔍 TROUBLESHOOT MODE"
  echo "=========================================="
  echo
  echo "Edition: ${WXO_EDITION:-unknown}"
  echo "Namespace: $PROJECT_CPD_INST_OPERANDS"
  echo
  
  # Check operators first
  check_orchestrate_operators
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
    check_knative_brokers
    
    # Check Knative Triggers
    check_knative_triggers
    
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

# --------------------- Main retry loop ----------------------
resolve_namespaces
detect_wxo_edition

trap 'echo; echo "Interrupted. Exiting."; exit 1' INT TERM

# Print author credit
echo "=========================================="
echo "📋 watsonx Orchestrate Health Check Script"
echo "   Author: Manu Thapar"
echo "   For issues or feature requests, please contact the author"
echo "=========================================="
echo ""

# Run troubleshoot mode if enabled - loop until healthy
if [ "${TROUBLESHOOT_MODE:-0}" -eq 1 ]; then
  TROUBLESHOOT_TRY=1
  while [ "$TROUBLESHOOT_TRY" -le "$MAX_TRIES" ]; do
    echo
    echo "=========================================="
    echo "🔄 TROUBLESHOOT CYCLE $TROUBLESHOOT_TRY of $MAX_TRIES"
    echo "=========================================="
    run_troubleshoot_mode
    
    # After troubleshoot, run a quick health check to see if we're healthy
    echo
    echo "Running health verification..."
    echo
    
    # Quick health check
    operators_ok=1; if check_orchestrate_operators; then operators_ok=0; fi
    pods_ok=1; if check_wo_pods; then pods_ok=0; fi
    
    # If operators and pods are healthy, we're done
    if [ "$operators_ok" -eq 0 ] && [ "$pods_ok" -eq 0 ]; then
      echo
      echo "🎉 Troubleshooting complete! Orchestrate is healthy after $TROUBLESHOOT_TRY cycle(s)."
      exit 0
    fi
    
    # Not healthy yet, continue loop
    if [ "$TROUBLESHOOT_TRY" -lt "$MAX_TRIES" ]; then
      echo
      echo "⚠️  System not yet healthy. Running another troubleshoot cycle in ${SLEEP_SECS}s..."
      echo "   Press Ctrl-C to stop"
      sleep "$SLEEP_SECS"
    fi
    
    TROUBLESHOOT_TRY=`expr "$TROUBLESHOOT_TRY" + 1`
  done
  
  echo
  echo "❌ Exhausted $MAX_TRIES troubleshoot cycles without achieving healthy state."
  exit 1
fi

TRY=1
while [ "$TRY" -le "$MAX_TRIES" ]; do
  print_header

  pods_ok=0; wo_cr_ok=0; wocs_ok=0; wa_cr_ok=0; ifm_cr_ok=0
  docproc_ok=0; de_ok=0; uab_ok=0
  edb_ok=0; kafka_ok=0; redis_ok=0; obc_ok=0; wxd_ok=0; jobs_ok=0; knative_eventing_ok=0; operators_ok=0

  # Check operators first
  section "Checking Operators"
  operators_ok=1; if check_orchestrate_operators; then operators_ok=0; fi

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

  if [ "${CHECK_OBC:-1}"  -eq 1 ]; then obc_ok=1;  if check_obc; then obc_ok=0; fi; fi
  if [ "${CHECK_WXD:-1}"  -eq 1 ]; then wxd_ok=1;  if check_wxd_engines; then wxd_ok=0; fi; fi

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


