#!/usr/bin/env bash
# 
# Combined health check for Watsonx Orchestrate:
#  - Autodetect namespaces (OPERATORS/OPERANDS) if env vars are not set
#  - Verify EtcdCluster authentication is Enabled for wo-wa-etcd or wo-docproc-etcd
#  - Verify all pods starting with "wo-" are either Completed or fully Running (x/x ready)
#  - Check CR statuses for wo, wa, watsonxaiifm
#  - Check WoComponentServices status and list DeployedStatus entries that are false
# Repeats every 15 seconds until all checks pass. Works on Linux and macOS.
# Contributor - Manu Thapar

set -euo pipefail

SLEEP_SECS=15
OVERRIDE_NS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) OVERRIDE_NS="$2"; shift 2 ;;
    -h|--help) sed -n '1,120p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

ts() { date '+%Y-%m-%d %H:%M:%S'; }
oc_base=(oc)

resolve_namespaces() {
  local autodetected_operands=""
  local autodetected_operators=""

  if [[ -z "${PROJECT_CPD_INST_OPERANDS:-}" ]]; then
    autodetected_operands="$("${oc_base[@]}" get wo -A --no-headers 2>/dev/null | awk 'NR==1 {print $1}')" || true
  fi
  if [[ -z "${PROJECT_CPD_INST_OPERATORS:-}" ]]; then
    autodetected_operators="$("${oc_base[@]}" get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null \
      | awk '$2=="ibm-cpd-watsonx-orchestrate-operator" {print $1; exit}')" || true
  fi

  PROJECT_CPD_INST_OPERANDS="${PROJECT_CPD_INST_OPERANDS:-$autodetected_operands}"
  PROJECT_CPD_INST_OPERATORS="${PROJECT_CPD_INST_OPERATORS:-$autodetected_operators}"
  if [[ -n "$OVERRIDE_NS" ]]; then PROJECT_CPD_INST_OPERANDS="$OVERRIDE_NS"; fi

  if [[ -z "${PROJECT_CPD_INST_OPERATORS:-}" || -z "${PROJECT_CPD_INST_OPERANDS:-}" ]]; then
    echo "[$(ts)] Required environment variables are not set."
    echo "[$(ts)] Please set both variables and re-run:"
    echo "  export PROJECT_CPD_INST_OPERATORS=<operators-namespace>"
    echo "  export PROJECT_CPD_INST_OPERANDS=<operands-namespace>"
    exit 1
  fi
}

print_header() {
  echo "------------------------------------------------------------"
  echo "⏱  $(ts)  Checking Orchestrate health in OPERANDS namespace: ${PROJECT_CPD_INST_OPERANDS} (operators: ${PROJECT_CPD_INST_OPERATORS})"
  echo "------------------------------------------------------------"
}

check_etcd_auth() {
  local oc_operands=("${oc_base[@]}" -n "${PROJECT_CPD_INST_OPERANDS}")
  local candidates=("wo-wa-etcd" "wo-docproc-etcd")
  local found_any=0
  local bad=0

  for name in "${candidates[@]}"; do
    if "${oc_operands[@]}" get etcdcluster "${name}" >/dev/null 2>&1; then
      ((found_any++))
      local auth
      auth="$("${oc_operands[@]}" get etcdcluster "${name}" -o jsonpath='{.status.authentication}' 2>/dev/null || true)"
      if [[ "${auth}" == "Enabled" ]]; then
        echo "✅ Etcd authentication: Enabled (cluster: ${name})"
      else
        if [[ -z "${auth}" ]]; then
          echo "❌ Etcd authentication: <empty/unknown> (cluster: ${name})"
        else
          echo "❌ Etcd authentication: ${auth} (cluster: ${name})"
        fi
        bad=1
      fi
    fi
  done

  if (( found_any == 0 )); then
    echo "❌ No expected EtcdCluster found in namespace ${PROJECT_CPD_INST_OPERANDS} (looked for: wo-wa-etcd, wo-docproc-etcd)"
    return 1
  fi

  if (( bad == 0 )); then
    return 0
  else
    return 1
  fi
}

check_wo_pods() {
  local oc_operands=("${oc_base[@]}" -n "${PROJECT_CPD_INST_OPERANDS}")
  local bad_found=0 total_wo=0
  while read -r name ready status rest; do
    [[ -z "$name" ]] && continue
    [[ "$name" =~ ^wo- ]] || continue
    (( total_wo++ ))
    if [[ "$status" == "Completed" ]]; then continue; fi
    local current="${ready%/*}" total="${ready#*/}"
    if [[ "$status" == "Running" && "$current" == "$total" ]]; then continue; fi
    printf "❌ %s\tReady=%s\tStatus=%s\n" "$name" "$ready" "$status"
    bad_found=1
  done < <("${oc_operands[@]}" get pods --no-headers 2>/dev/null || true)

  if (( total_wo == 0 )); then
    echo "❌ No pods found with prefix 'wo-' in namespace ${PROJECT_CPD_INST_OPERANDS}. (Is Orchestrate installed?)"
    bad_found=1
  fi
  if (( bad_found == 0 )); then echo "✅ All Orchestrate pods are healthy"; return 0; else return 1; fi
}

check_cr_statuses() {
  local oc_operands=("${oc_base[@]}" -n "${PROJECT_CPD_INST_OPERANDS}")
  local ok=0
  echo "🔎 Checking CR statuses (wo, wa, watsonxaiifm) in ${PROJECT_CPD_INST_OPERANDS}..."

  # WO
  local wo_name; wo_name="$("${oc_operands[@]}" get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}')" || true
  if [[ -z "${wo_name}" ]]; then echo "❌ WO CR not found (oc get wo)"; ok=1
  else
    local wo_ready wo_status wo_progress
    wo_ready="$("${oc_operands[@]}" get wo "${wo_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    wo_status="$("${oc_operands[@]}" get wo "${wo_name}" -o jsonpath='{.status.watsonxOrchestrateStatus}' 2>/dev/null || true)"
    wo_progress="$("${oc_operands[@]}" get wo "${wo_name}" -o jsonpath='{.status.progress}' 2>/dev/null || true)"
    if [[ "${wo_ready}" == "True" && "${wo_status}" == "Completed" && "${wo_progress}" == "100%" ]]; then
      echo "✅ WO (${wo_name}): Ready=True, Status=Completed, Progress=100%"
    else
      echo "❌ WO (${wo_name}): Ready=${wo_ready}, Status=${wo_status}, Progress=${wo_progress}"; ok=1
    fi
  fi

  # WA
  local wa_name; wa_name="$("${oc_operands[@]}" get wa --no-headers 2>/dev/null | awk 'NR==1 {print $1}')" || true
  if [[ -z "${wa_name}" ]]; then echo "❌ WA CR not found (oc get wa)"; ok=1
  else
    local wa_ready wa_status wa_progress
    wa_ready="$("${oc_operands[@]}" get wa "${wa_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    wa_status="$("${oc_operands[@]}" get wa "${wa_name}" -o jsonpath='{.status.watsonAssistantStatus}' 2>/dev/null || true)"
    wa_progress="$("${oc_operands[@]}" get wa "${wa_name}" -o jsonpath='{.status.progress}' 2>/dev/null || true)"
    if [[ "${wa_ready}" == "True" && "${wa_status}" == "Completed" && "${wa_progress}" == "100%" ]]; then
      echo "✅ WA (${wa_name}): Ready=True, Status=Completed, Progress=100%"
    else
      echo "❌ WA (${wa_name}): Ready=${wa_ready}, Status=${wa_status}, Progress=${wa_progress}"; ok=1
    fi
  fi

  # IFM
  local ifm_name; ifm_name="$("${oc_operands[@]}" get watsonxaiifm --no-headers 2>/dev/null | awk 'NR==1 {print $1}')" || true
  if [[ -z "${ifm_name}" ]]; then echo "❌ Watsonx AI IFM CR not found (oc get watsonxaiifm)"; ok=1
  else
    local cond_success cond_failure ifm_status ifm_progress
    cond_success="$("${oc_operands[@]}" get watsonxaiifm "${ifm_name}" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"
    cond_failure="$("${oc_operands[@]}" get watsonxaiifm "${ifm_name}" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || true)"
    ifm_status="$("${oc_operands[@]}" get watsonxaiifm "${ifm_name}" -o jsonpath='{.status.watsonxaiifmStatus}' 2>/dev/null || true)"
    ifm_progress="$("${oc_operands[@]}" get watsonxaiifm "${ifm_name}" -o jsonpath='{.status.progress}' 2>/dev/null || true)"
    if [[ "${cond_success}" == "True" && ( "${cond_failure}" == "False" || -z "${cond_failure}" ) && "${ifm_status}" == "Completed" && "${ifm_progress}" == "100%" ]]; then
      echo "✅ IFM (${ifm_name}): Successful=True, Failure=${cond_failure:-None}, Status=Completed, Progress=100%"
    else
      echo "❌ IFM (${ifm_name}): Successful=${cond_success}, Failure=${cond_failure}, Status=${ifm_status}, Progress=${ifm_progress}"; ok=1
    fi
  fi

  return $ok
}

check_wocomponentservices() {
  # Checks WoComponentServices CR status in the OPERANDS namespace.
  local oc_operands=("${oc_base[@]}" -n "${PROJECT_CPD_INST_OPERANDS}")

  local name
  name="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR==1 {print $1}')" || true

  if [[ -z "${name}" ]]; then
    echo "❌ WoComponentServices CR not found (oc get wocomponentservices.wo.watsonx.ibm.com)"
    return 1
  fi

  local comp_status deployed upgrade failure running successful
  comp_status="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o jsonpath='{.status.componentStatus}' 2>/dev/null || true)"
  deployed="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o jsonpath='{.status.Deployed}' 2>/dev/null || true)"
  upgrade="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o jsonpath='{.status.Upgrade}' 2>/dev/null || true)"
  failure="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || true)"
  running="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || true)"
  successful="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"

  # Gather any DeployedStatus entries that are 'false' robustly from JSON (avoid jsonpath map quirks)
  local false_components
  false_components="$("${oc_operands[@]}" get wocomponentservices.wo.watsonx.ibm.com "${name}" -o json 2>/dev/null \
    | awk '
      BEGIN { inDS=0 }
      /"DeployedStatus"\s*:/ { inDS=1; next }
      inDS {
        if ($0 ~ /}/) { inDS=0; exit }
        gsub(/[,"]/,"");
        sub(/^[[:space:]]*/,"");
        if ($0 ~ /: *false$/ || $0 ~ /: *False$/) print $0
      }' || true)"

  if { [[ "${comp_status}" == "FullInstallComplete" || "${comp_status}" == "Reconciled" ]]; } \
     && [[ "${failure}" != "True" ]]; then
    echo "✅ WoComponentServices (${name}): componentStatus=${comp_status}, Deployed=${deployed}, Upgrade=${upgrade}, Successful=${successful}, Running=${running}"
    if [[ -n "${false_components}" ]]; then
      echo "   Components with DeployedStatus=false:"
      echo "${false_components}" | awk -F: '{gsub(/[[:space:]]*/,"",$1); gsub(/[[:space:]]*/,"",$2); print "     - " $1 " = " tolower($2)}'
    fi
    return 0
  else
    echo "❌ WoComponentServices (${name}): componentStatus=${comp_status}, Deployed=${deployed}, Upgrade=${upgrade}, Successful=${successful}, Running=${running}"
    if [[ -n "${false_components}" ]]; then
      echo "   Components with DeployedStatus=false:"
      echo "${false_components}" | awk -F: '{gsub(/[[:space:]]*/,"",$1); gsub(/[[:space:]]*/,"",$2); print "     - " $1 " = " tolower($2)}'
    fi
    return 1
  fi
}

# --- Main ---
resolve_namespaces
trap 'echo; echo "Interrupted. Exiting."; exit 1' INT TERM

while true; do
  print_header
  etcd_ok=1; pods_ok=1; cr_ok=1; wocs_ok=1

  if check_etcd_auth; then etcd_ok=0; fi
  if check_wo_pods;   then pods_ok=0;  fi
  if check_cr_statuses; then cr_ok=0;  fi
  if check_wocomponentservices; then wocs_ok=0; fi

  if (( ${etcd_ok:-1} == 0 && ${pods_ok:-1} == 0 && ${cr_ok:-1} == 0 && ${wocs_ok:-1} == 0 )); then
    echo "🎉 All checks passed. Orchestrate is healthy."; exit 0
  fi

  echo; echo "🔁 Rechecking in ${SLEEP_SECS}s ... (Ctrl-C to stop)"; sleep "${SLEEP_SECS}"; echo
done
