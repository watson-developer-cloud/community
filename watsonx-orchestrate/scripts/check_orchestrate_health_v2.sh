#!/bin/sh
#
# Combined health check for watsonx Orchestrate on OpenShift (POSIX sh)
#
# Lite aware:
#  - Detects lite via wo.spec.wxolite.enabled=true (primary), then other spec hints, then heuristics
#  - Accepts WoComponentServices componentStatus=ReconciledLite as healthy
#  - In lite, WA, IFM, DocumentProcessing, DigitalEmployees, UAB ADS are checked and gate health if present
#
# What it does:
#  - Autodetect namespaces (OPERATORS and OPERANDS) if env vars are not set
#  - Detect edition: full vs lite
#  - Verify all pods starting with "wo-" are either Completed or fully Running (x/x ready)
#  - Check CRs (individually toggleable)
#  - Check datastores only those starting with wo-: EDB Postgres, Kafka, Redis CP, WXD engines
#
# Behavior:
#  - Exits 0 on the first successful pass where all enabled checks are healthy
#  - Otherwise retries up to MAX_TRIES, sleeping SLEEP_SECS between attempts, then exits 1
#
# Contributor - Manu Thapar

set -eu

# ------------------------- Tunables -------------------------
: "${MAX_TRIES:=40}"
: "${SLEEP_SECS:=15}"
OVERRIDE_NS="${OVERRIDE_NS:-}"

# Lite detection controls
: "${DETECT_LITE:=1}"
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

# ---------------------- Arg parsing -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) OVERRIDE_NS="$2"; shift 2 ;;
    --assume-lite)  ASSUME_EDITION="lite"; shift 1 ;;
    --assume-full)  ASSUME_EDITION="full"; shift 1 ;;
    -h|--help) sed -n '1,220p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ------------------------ Utilities -------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
OC="oc"

print_rule() { echo "------------------------------------------------------------"; }
print_header() {
  print_rule
  echo "⏱  $(ts)  Checking Orchestrate health in OPERANDS namespace: $PROJECT_CPD_INST_OPERANDS (operators: ${PROJECT_CPD_INST_OPERATORS:-none})"
  echo "    Edition: ${WXO_EDITION:-unknown}${WXO_DETECT_NOTE:+  (${WXO_DETECT_NOTE})}"
  print_rule
}

section() { echo; echo "▶ $1"; }

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
    autodetected_operators=$($OC get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null \
      | awk '$3=="ibm-cpd-watsonx-orchestrate-operator" {print $1; exit}') || :
    if [ -z "$autodetected_operators" ]; then
      autodetected_operators=$(
        $OC get csv -A --no-headers 2>/dev/null \
        | awk '$2 ~ /watsonx-.*orchestrate-operator/ {print $1; exit}'
      ) || :
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
#   WXO_EDITION = lite | full | unknown
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

  [ "${DETECT_LITE:-1}" -eq 1 ] || { WXO_DETECT_NOTE="detection disabled"; export WXO_EDITION WXO_DETECT_NOTE; return 0; }

  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  wo_name=`$OCN get wo --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :

  if [ -n "$wo_name" ]; then
    wxolite_enabled=`$OCN get wo "$wo_name" -o jsonpath='{.spec.wxolite.enabled}' 2>/dev/null || :`
    case "$(echo "${wxolite_enabled:-}" | tr '[:upper:]' '[:lower:]')" in
      true) WXO_EDITION="lite"; WXO_DETECT_NOTE="wo.spec.wxolite.enabled=true" ;;
    esac

    if [ "$WXO_EDITION" = "unknown" ]; then
      agentic_only=`$OCN get wo "$wo_name" -o jsonpath='{.spec.agenticOnly}' 2>/dev/null || :`
      profile_val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.profile}' 2>/dev/null || :`
      edition_val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.edition}' 2>/dev/null || :`
      mode_val=`$OCN get wo "$wo_name" -o jsonpath='{.spec.mode}' 2>/dev/null || :`
      case "$(echo "${agentic_only:-}" | tr '[:upper:]' '[:lower:]')" in
        true) WXO_EDITION="lite"; WXO_DETECT_NOTE="wo.spec.agenticOnly=true" ;;
      esac
      if [ "$WXO_EDITION" = "unknown" ]; then
        case "$(echo "${profile_val:-}" | tr '[:upper:]' '[:lower:]')" in
          lite) WXO_EDITION="lite"; WXO_DETECT_NOTE="wo.spec.profile=lite" ;;
        esac
      fi
      if [ "$WXO_EDITION" = "unknown" ]; then
        case "$(echo "${edition_val:-}" | tr '[:upper:]' '[:lower:]')" in
          lite) WXO_EDITION="lite"; WXO_DETECT_NOTE="wo.spec.edition=lite" ;;
        esac
      fi
      if [ "$WXO_EDITION" = "unknown" ]; then
        case "$(echo "${mode_val:-}" | tr '[:upper:]' '[:lower:]')" in
          agentic) WXO_EDITION="lite"; WXO_DETECT_NOTE="wo.spec.mode=agentic" ;;
        esac
      fi
    fi

    if [ "$WXO_EDITION" = "unknown" ]; then
      wocs_name=`$OCN get wocomponentservices.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR==1 {print $1}'` || :
      if [ -n "$wocs_name" ]; then
        cstat=`$OCN get wocomponentservices.wo.watsonx.ibm.com "$wocs_name" -o jsonpath='{.status.componentStatus}' 2>/dev/null || :`
        [ "$cstat" = "ReconciledLite" ] && { WXO_EDITION="lite"; WXO_DETECT_NOTE="WoComponentServices.status.componentStatus=ReconciledLite"; }
      fi
    fi
  fi

  if [ "$WXO_EDITION" = "unknown" ]; then
    have_wa=`$OCN get wa --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    have_doc=`$OCN get documentprocessings.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    have_de=`$OCN get digitalemployees.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    have_uab=`$OCN get uabautomationdecisionservices.uab.ba.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    if [ -z "$have_wa" ] && [ -z "$have_doc" ] && [ -z "$have_de" ] && [ -z "$have_uab" ]; then
      WXO_EDITION="lite"
      WXO_DETECT_NOTE="heuristic no WA DocProc DE UAB CRs"
    else
      WXO_EDITION="full"
      WXO_DETECT_NOTE="heuristic at least one non lite CR present"
    fi
  fi

  export WXO_EDITION WXO_DETECT_NOTE
}

# ------------------------- Checks ---------------------------
check_wo_pods() {
  OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
  bad_found=0
  total_wo=0
  echo "▶ Checking Orchestrate pods"
  tmp_list=`mktemp 2>/dev/null || echo "/tmp/wo_pods.$$"`
  tmp_bad=`mktemp 2>/dev/null || echo "/tmp/wo_bad.$$"`
  $OCN get pods --no-headers 2>/dev/null > "$tmp_list" || :
  while IFS= read -r line; do
    set -- $line
    name="${1:-}"; ready="${2:-}"; status="${3:-}"
    [ -z "$name" ] && continue
    case "$name" in wo-*) : ;; *) continue ;; esac
    total_wo=`expr "${total_wo:-0}" + 1`
    if [ "$status" = "Completed" ]; then continue; fi
    current=`echo "$ready" | awk -F/ '{print $1}'`
    total=`echo "$ready" | awk -F/ '{print $2}'`
    if [ "$status" = "Running" ] && [ "$current" = "$total" ]; then :; else
      printf "   - %s\tReady=%s\tStatus=%s\n" "$name" "$ready" "$status" >> "$tmp_bad"
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
    cat "$tmp_bad"
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
    return 1
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
  names=`$OCN get kafka --no-headers 2>/dev/null | awk '$1 ~ /^wo-/{print $1}'` || :
  if [ -z "$names" ]; then echo "❌ No Kafka resources starting with 'wo-' found in $PROJECT_CPD_INST_OPERANDS"; return 1; fi
  bad=0
  echo "$names" | while read n; do
    [ -z "$n" ] && continue
    cond_ready=`$OCN get kafka "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || :`
    if [ "$cond_ready" = "True" ]; then
      echo "✅ Kafka $n: Ready=True"
    else
      ready_col=`$OCN get kafka "$n" --no-headers 2>/dev/null | awk '{print $5}'` || :
      if [ "$ready_col" = "True" ]; then
        echo "✅ Kafka $n: Ready=True"
      else
        val="$cond_ready"; [ -z "$val" ] && val="$ready_col"; [ -z "$val" ] && val="Unknown"
        echo "❌ Kafka $n: Ready=$val"
        bad=1
      fi
    fi
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
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
  echo "$rows" | while read name version type display size reconcile status age; do
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
  done
  [ "${bad:-0}" -eq 0 ] && return 0 || return 1
}

# --------------------- Main retry loop ----------------------
resolve_namespaces
detect_wxo_edition

trap 'echo; echo "Interrupted. Exiting."; exit 1' INT TERM

TRY=1
while [ "$TRY" -le "$MAX_TRIES" ]; do
  print_header

  pods_ok=0; wo_cr_ok=0; wocs_ok=0; wa_cr_ok=0; ifm_cr_ok=0
  docproc_ok=0; de_ok=0; uab_ok=0
  edb_ok=0; kafka_ok=0; redis_ok=0; wxd_ok=0

  if [ "${CHECK_WO_PODS:-1}" -eq 1 ]; then pods_ok=1; if check_wo_pods; then pods_ok=0; fi; fi

  section "Checking Orchestrate and supporting Custom Resources"
  if [ "${CHECK_WO_CR:-1}"  -eq 1 ]; then wo_cr_ok=1; if check_wo_cr; then wo_cr_ok=0; fi; fi
  if [ "${CHECK_WOCS:-1}"   -eq 1 ]; then wocs_ok=1; if check_wocomponentservices; then wocs_ok=0; fi; fi

  if [ "${WXO_EDITION:-unknown}" = "lite" ]; then
    OCN="$OC -n $PROJECT_CPD_INST_OPERANDS"
    wa_present=`$OCN get wa --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    ifm_present=`$OCN get watsonxaiifm --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    doc_present=`$OCN get documentprocessings.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    de_present=`$OCN get digitalemployees.wo.watsonx.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`
    uab_present=`$OCN get uabautomationdecisionservices.uab.ba.ibm.com --no-headers 2>/dev/null | awk 'NR>0{print "y"; exit}' || true`

    if [ -n "$wa_present" ]  && [ "${CHECK_WA_CR:-1}"   -eq 1 ]; then wa_cr_ok=1;   if check_wa_cr; then wa_cr_ok=0; fi; fi
    if [ -n "$ifm_present" ] && [ "${CHECK_IFM_CR:-1}"  -eq 1 ]; then ifm_cr_ok=1;  if check_ifm_cr; then ifm_cr_ok=0; fi; fi
    if [ -n "$doc_present" ] && [ "${CHECK_DOCPROC:-1}" -eq 1 ]; then docproc_ok=1; if check_docproc; then docproc_ok=0; fi; fi
    if [ -n "$de_present" ]  && [ "${CHECK_DE:-1}"      -eq 1 ]; then de_ok=1;      if check_digital_employees; then de_ok=0; fi; fi
    if [ -n "$uab_present" ] && [ "${CHECK_UAB_ADS:-1}" -eq 1 ]; then uab_ok=1;     if check_uab_ads; then uab_ok=0; fi; fi
  else
    if [ "${CHECK_WA_CR:-1}"   -eq 1 ]; then wa_cr_ok=1;   if check_wa_cr; then wa_cr_ok=0; fi; fi
    if [ "${CHECK_IFM_CR:-1}"  -eq 1 ]; then ifm_cr_ok=1;  if check_ifm_cr; then ifm_cr_ok=0; fi; fi
    if [ "${CHECK_DOCPROC:-1}" -eq 1 ]; then docproc_ok=1; if check_docproc; then docproc_ok=0; fi; fi
    if [ "${CHECK_DE:-1}"      -eq 1 ]; then de_ok=1;      if check_digital_employees; then de_ok=0; fi; fi
    if [ "${CHECK_UAB_ADS:-1}" -eq 1 ]; then uab_ok=1;     if check_uab_ads; then uab_ok=0; fi; fi
  fi

  section "Checking Datastores"
  if [ "${CHECK_EDB:-1}"   -eq 1 ]; then edb_ok=1;   if check_edb_clusters; then edb_ok=0; fi; fi
  if [ "${CHECK_KAFKA:-1}" -eq 1 ]; then kafka_ok=1; if check_kafka_readiness; then kafka_ok=0; fi; fi
  if [ "${CHECK_REDIS:-1}" -eq 1 ]; then redis_ok=1; if check_redis_cp; then redis_ok=0; fi; fi
  if [ "${CHECK_WXD:-1}"   -eq 1 ]; then wxd_ok=1;   if check_wxd_engines; then wxd_ok=0; fi; fi

  if [ "$pods_ok" -eq 0 ] && [ "$wo_cr_ok" -eq 0 ] && [ "$wocs_ok" -eq 0 ] \
     && [ "$wa_cr_ok" -eq 0 ] && [ "$ifm_cr_ok" -eq 0 ] \
     && [ "$docproc_ok" -eq 0 ] && [ "$de_ok" -eq 0 ] && [ "$uab_ok" -eq 0 ] \
     && [ "$edb_ok" -eq 0 ] && [ "$kafka_ok" -eq 0 ] && [ "$redis_ok" -eq 0 ] && [ "$wxd_ok" -eq 0 ]; then
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
