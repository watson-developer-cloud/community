#!/bin/sh
################################################################################
# Watson Orchestrate Pre-Installation Prerequisite Check Script
#
# Description: This script validates all prerequisites before Watson Orchestrate
#              installation.
#
# Authors: Amal Paul, Manu Thapar
# Version: 1.0.0
# License: IBM Internal Use
#
# Documentation References:
#   - IBM Software Hub 5.3.x: https://www.ibm.com/docs/en/software-hub/5.3.x
#   - Watson Orchestrate Installation: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=orchestrate-installing
#   - Storage Requirements: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=orchestrate-installing
#   - GPU Requirements: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=requirements-gpu-models
#   - MCG Installation: https://www.ibm.com/docs/en/cloud-paks/cp-data/5.0.x?topic=software-installing-multicloud-object-gateway
#   - Knative Eventing: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=software-installing-red-hat-openshift-serverless-knative-eventing
#
# Usage: sh pre-requisite-script.sh [OPTIONS]
#
# Options:
#   --operator-ns <namespace>      CPD operators namespace (optional, default: auto-detect or cpd-operators)
#   --operand-ns <namespace>       CPD operands namespace (optional, default: auto-detect or cpd-instance-1)
#   --installation-type <type>     Installation type: agentic, agentic_assistant, agentic_skills_assistant (required)
#   --internal-ifm <true|false>    Internal IFM flag (required)
#   -h, --help                     Display this help message
#
# Environment Variables:
#   PROJECT_CPD_INST_OPERATORS - CPD operators namespace (default: cpd-operators)
#   PROJECT_CPD_INST_OPERANDS  - CPD operands namespace (default: cpd-instance-1)
#   PROJECT_IBM_EVENTS         - IBM Events namespace (default: ibm-knative-events)
#
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/tmp/wo_prereq_check_$(date +%Y%m%d_%H%M%S).log}"
ERRORS=0
WARNINGS=0
CHECKS_PASSED=0

# Minimum requirements
MIN_OCP_VERSION="4.12"
MIN_WORKER_NODES=4
MIN_CPU_PER_NODE=16
MIN_MEMORY_PER_NODE=64  # GB
MIN_STORAGE_SIZE=500    # GB
REQUIRED_STORAGE_CLASSES=("block" "file")

# Environment variables with defaults
PROJECT_CPD_INST_OPERATORS="${PROJECT_CPD_INST_OPERATORS:-cpd-operators}"
PROJECT_CPD_INST_OPERANDS="${PROJECT_CPD_INST_OPERANDS:-cpd-instance-1}"
PROJECT_IBM_EVENTS="${PROJECT_IBM_EVENTS:-ibm-knative-events}"

# Installation configuration variables
INSTALLATION_TYPE=""
INTERNAL_IFM=""

# Storage class validation arrays (based on IBM Software Hub 5.3.x documentation)
# Reference: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=orchestrate-installing
UNSUPPORTED_STORAGE_CLASSES=(
    "ibm-storage-scale-container-native"
    "nfs"
    "nutanix"
)

UNSUPPORTED_PROVISIONERS=(
    "kubernetes.io/no-provisioner"
    "nfs"
    "nutanix"
)

SUPPORTED_PROVISIONERS=(
    "ocs"
    "odf"
    "ceph"
    "portworx"
    "netapp"
    "trident"
    "ibm-spectrum-scale"
    "ibm-spectrum-fusion"
    "noobaa"
    "openshift-storage.noobaa.io"
)

################################################################################
# Utility Functions
################################################################################

usage() {
    cat << EOF
Watson Orchestrate Pre-Installation Prerequisite Check Script

Usage: $0 [OPTIONS]

Options:
  --operator-ns <namespace>      CPD operators namespace (optional, default: auto-detect or cpd-operators)
  --operand-ns <namespace>       CPD operands namespace (optional, default: auto-detect or cpd-instance-1)
  --installation-type <type>     Installation type (required)
                                 Valid values: agentic, agentic_assistant, agentic_skills_assistant
  --internal-ifm <true|false>    Internal IFM flag (required)
  -h, --help                     Display this help message

Examples:
  # Basic usage with required parameters
  $0 --installation-type agentic --internal-ifm true

  # Specify custom namespaces
  $0 --operator-ns my-operators --operand-ns my-operands --installation-type agentic_assistant --internal-ifm false

  # Using environment variables
  PROJECT_CPD_INST_OPERATORS=my-operators PROJECT_CPD_INST_OPERANDS=my-operands \\
    $0 --installation-type agentic_skills_assistant --internal-ifm true

Environment Variables:
  PROJECT_CPD_INST_OPERATORS     CPD operators namespace (overridden by --operator-ns)
  PROJECT_CPD_INST_OPERANDS      CPD operands namespace (overridden by --operand-ns)
  PROJECT_IBM_EVENTS             IBM Events namespace (default: ibm-knative-events)

EOF
    exit 0
}

log() {
    printf "%b\n" "$1" | tee -a "$LOG_FILE"
}

log_info() {
    log "${BLUE}[INFO]${NC} $1"
}

log_success() {
    log "${GREEN}[PASS]${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_warning() {
    log "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

log_error() {
    log "${RED}[FAIL]${NC} $1"
    ERRORS=$((ERRORS + 1))
}

print_header() {
    log ""
    log "================================================================================"
    log "$1"
    log "================================================================================"
}

print_summary() {
    log ""
    log "================================================================================"
    log "                        PREREQUISITE CHECK SUMMARY"
    log "================================================================================"
    log "${GREEN}Checks Passed: ${CHECKS_PASSED}${NC}"
    log "${YELLOW}Warnings: ${WARNINGS}${NC}"
    log "${RED}Errors: ${ERRORS}${NC}"
    log "================================================================================"
    log ""
    log "Log file saved to: $LOG_FILE"
    
    if [ $ERRORS -gt 0 ]; then
        log_error "Prerequisites check FAILED. Please fix the errors above before proceeding."
        return 1
    elif [ $WARNINGS -gt 0 ]; then
        log_warning "Prerequisites check completed with warnings. Review warnings before proceeding."
        return 0
    else
        log_success "All prerequisites checks PASSED. You can proceed with Watson Orchestrate installation."
        return 0
    fi
}

################################################################################
# Check Functions
################################################################################

check_oc_login() {
    print_header "Checking OpenShift CLI Authentication"
    
    if ! command -v oc &> /dev/null; then
        log_error "OpenShift CLI (oc) is not installed or not in PATH"
        log_error "Script cannot continue without OpenShift CLI. Exiting..."
        exit 1
    fi
    
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        log_error "Script cannot continue without valid OpenShift authentication. Exiting..."
        exit 1
    fi
    
    local current_user=$(oc whoami)
    local current_server=$(oc whoami --show-server)
    log_info "Server: $current_server"
    log_success "Logged in as: $current_user"
}

check_cluster_version() {
    print_header "Checking OpenShift Cluster Version"
    
    local ocp_version=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // .serverVersion.gitVersion' | sed 's/v//' | cut -d'-' -f1)
    
    if [ -z "$ocp_version" ]; then
        log_error "Unable to determine OpenShift version"
        return 0
    fi
    
    log_info "OpenShift version: $ocp_version"
    
    # Compare versions
    if [ "$(printf '%s\n' "$MIN_OCP_VERSION" "$ocp_version" | sort -V | head -n1)" != "$MIN_OCP_VERSION" ]; then
        log_error "OpenShift version $ocp_version is below minimum required version $MIN_OCP_VERSION"
        return 0
    fi
    
    log_success "OpenShift version meets minimum requirement (>= $MIN_OCP_VERSION)"
}

check_worker_nodes() {
    print_header "Checking Cluster Resources"
    
    local total_nodes=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local ready_nodes=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready" {count++} END{print count+0}')
    
    if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
        log_success "All $total_nodes cluster nodes are Ready"
    else
        log_warning "$ready_nodes/$total_nodes nodes are Ready"
    fi
    
    local worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$worker_nodes" -lt "$MIN_WORKER_NODES" ]; then
        log_error "Insufficient worker nodes. Found: $worker_nodes, Required: $MIN_WORKER_NODES"
    else
        log_success "Worker nodes: $worker_nodes (minimum: $MIN_WORKER_NODES)"
    fi
}

check_storage_classes() {
    print_header "Checking Storage Classes"
    
    local storage_classes=$(oc get storageclass --no-headers 2>/dev/null | awk '{print $1}')
    
    if [ -z "$storage_classes" ]; then
        log_error "No storage classes found in the cluster"
        return 0
    fi
    
    log_info "Available storage classes:"
    echo "$storage_classes" | while read -r sc; do
        local is_default=$(oc get storageclass "$sc" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')
        if [ "$is_default" == "true" ]; then
            log_info "  - $sc (default)"
        else
            log_info "  - $sc"
        fi
    done
    
    log ""
    log_info "Please Validate storage classes against IBM Software Hub 5.3.x requirements..."
    log_info "Reference: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=orchestrate-installing"
    log ""

}
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check IBM Entitlement Key in operator namespace
    if oc get secret ibm-entitlement-key -n "$PROJECT_CPD_INST_OPERATORS" &> /dev/null; then
        log_success "ibm-entitlement-key exists in operator namespace: $PROJECT_CPD_INST_OPERATORS"
    else
        log_error "ibm-entitlement-key missing in operator namespace: $PROJECT_CPD_INST_OPERATORS"
        log_error "  Create the secret using: oc create secret docker-registry ibm-entitlement-key --docker-server=cp.icr.io --docker-username=cp --docker-password=<entitlement-key> -n $PROJECT_CPD_INST_OPERATORS"
    fi
    
    # Check IBM Entitlement Key in operand namespace
    if oc get secret ibm-entitlement-key -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
        log_success "ibm-entitlement-key exists in operand namespace: $PROJECT_CPD_INST_OPERANDS"
    else
        log_error "ibm-entitlement-key missing in operand namespace: $PROJECT_CPD_INST_OPERANDS"
        log_error "  Create the secret using: oc create secret docker-registry ibm-entitlement-key --docker-server=cp.icr.io --docker-username=cp --docker-password=<entitlement-key> -n $PROJECT_CPD_INST_OPERANDS"
    fi
    
    # Check IAM Integration
    if oc get zenservice lite-cr -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
        local iam_integration=$(oc get zenservice lite-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.spec.iamIntegration}' 2>/dev/null || echo "")
        
        if [ "$iam_integration" = "true" ]; then
            log_success "IAM integration is enabled (zenservice lite-cr spec.iamIntegration=true)"
        elif [ "$iam_integration" = "false" ]; then
            log_error "IAM integration is disabled (zenservice lite-cr spec.iamIntegration=false)"
            log_error "  IAM integration must be enabled for Watson Orchestrate"
        else
            log_warning "IAM integration value unknown or not set: '$iam_integration'"
            log_warning "  Verify IAM integration is properly configured"
        fi
    else
        log_warning "Cannot check IAM integration - zenservice lite-cr not found in '$PROJECT_CPD_INST_OPERANDS'"
    fi
    
    # Check MCG/NooBaa and Service Secrets
    if ! oc get namespace openshift-storage &> /dev/null; then
        log_error "openshift-storage namespace not found"
        log_error "  MCG/NooBaa is likely not installed"
        log_error "  Install MCG/NooBaa: https://www.ibm.com/docs/en/cloud-paks/cp-data/5.0.x?topic=software-installing-multicloud-object-gateway"
    else
        log_success "openshift-storage namespace exists"
        
        # Check NooBaa credentials secret
        local creds_secret="noobaa-admin"
        if oc get secret "$creds_secret" -n openshift-storage &> /dev/null; then
            log_success "NooBaa credentials secret exists: openshift-storage/$creds_secret"
        else
            log_error "NooBaa credentials secret missing: openshift-storage/$creds_secret"
        fi
        
        # Check NooBaa certificate secret
        local cert_secret="noobaa-s3-serving-cert"
        if oc get secret "$cert_secret" -n openshift-storage &> /dev/null; then
            log_success "NooBaa certificate secret exists: openshift-storage/$cert_secret"
        else
            log_error "NooBaa certificate secret missing: openshift-storage/$cert_secret"
        fi
        
        log ""
        
        # Check Watson Orchestrate MCG secrets (required for all installation types)
        local wo_secrets=("noobaa-account-watsonx-orchestrate" "noobaa-cert-watsonx-orchestrate" "noobaa-uri-watsonx-orchestrate")
        for secret in "${wo_secrets[@]}"; do
            if oc get secret "$secret" -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
                log_success "MCG service secret exists: $secret"
            else
                log_error "MCG service secret missing: $secret"
            fi
        done
        
        # Check Watson Assistant MCG secrets (for agentic_assistant and agentic_skills_assistant)
        if [ "$INSTALLATION_TYPE" = "agentic_assistant" ] || [ "$INSTALLATION_TYPE" = "agentic_skills_assistant" ]; then
            log ""
            local wa_secrets=("noobaa-account-watson-assistant" "noobaa-cert-watson-assistant" "noobaa-uri-watson-assistant")
            for secret in "${wa_secrets[@]}"; do
                if oc get secret "$secret" -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
                    log_success "MCG service secret exists: $secret"
                else
                    log_error "MCG service secret missing: $secret"
                fi
            done
        fi
    fi
}


check_software_hub_instance() {
    print_header "Checking Control Plane Health"
    
    # Check if namespace exists
    if ! oc get namespace "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
        log_error "Namespace '$PROJECT_CPD_INST_OPERANDS' does not exist"
        log_error "  IBM Software Hub must be installed before Watson Orchestrate"
        log_error "  Install IBM Software Hub first: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=installing-instance-software-hub"
        return 0
    fi

    
    if ! oc get ibmcpd ibmcpd-cr -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
        log_error "IBM Software Hub custom resource 'ibmcpd-cr' not found in namespace: $PROJECT_CPD_INST_OPERANDS"
        log_error "  IBM Software Hub must be installed before Watson Orchestrate"
        log_error "  Install IBM Software Hub first: https://www.ibm.com/docs/en/software-hub/5.3.x?topic=installing-instance-software-hub"
        return 0
    fi

    
    # Get the progress status
    local progress=$(oc get ibmcpd ibmcpd-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.progress}' 2>/dev/null)
    local control_plane_status=$(oc get ibmcpd ibmcpd-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.controlPlaneStatus}' 2>/dev/null)
    local current_version=$(oc get ibmcpd ibmcpd-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.currentVersion}' 2>/dev/null)
    
    if [ -z "$progress" ]; then
        log_error "Unable to determine IBM Software Hub installation progress"
        log_error "  Check the ibmcpd-cr custom resource status manually"
        return 0
    fi
    
    # Check if installation is 100% complete
    if [ "$progress" == "100%" ]; then
        if [ "$control_plane_status" == "Completed" ]; then
            log_success "ibmcpd ibmcpd-cr status is 'Completed'"
        else
            log_warning "Control plane status is '$control_plane_status' (expected: Completed)"
            log_warning "  IBM Software Hub may not be fully operational yet"
        fi
    else
        log_error "IBM Software Hub installation is not complete: $progress"
    fi
    
    
    # Check ZenService status
    
    if ! oc get zenservices lite-cr -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
        log_error "ZenService custom resource 'lite-cr' not found in namespace: $PROJECT_CPD_INST_OPERANDS"
        log_error "  ZenService is required for IBM Software Hub"
        return 0
    fi
    
    # Get the ZenService status
    local zen_progress=$(oc get zenservices lite-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.progress}' 2>/dev/null)
    local zen_status=$(oc get zenservices lite-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.zenStatus}' 2>/dev/null)
    local zen_version=$(oc get zenservices lite-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.currentVersion}' 2>/dev/null)
    local zen_message=$(oc get zenservices lite-cr -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.status.progressMessage}' 2>/dev/null)
    
    if [ -z "$zen_progress" ]; then
        log_error "Unable to determine ZenService installation progress"
        log_error "  Check the lite-cr zenservices custom resource status manually"
        return 0
    fi
    
    # Check if ZenService installation is 100% complete
    if [ "$zen_progress" == "100%" ]; then
        if [ "$zen_status" == "Completed" ]; then
            log_success "ZenService lite-cr status is 'Completed'"
        else
            log_warning "ZenService status is '$zen_status' (expected: Completed)"
            log_warning "  ZenService may not be fully operational yet"
        fi
    else
        log_error "ZenService installation is not complete: $zen_progress"
        log_error "  Current status: $zen_status"
        log_error "  Wait for ZenService to reach 100% before installing Watson Orchestrate"
    fi
    
}

check_openshift_ai_operator() {
    print_header "Checking OpenShift AI Operator"
    
    # Check for OpenShift AI / RHODS operator subscription
    
    local ai_csv=$(oc get csv -A --no-headers 2>/dev/null | grep -iE "rhods|opendatahub|odh|openshift-ai" | head -n 1 || echo "")
    
    if [ -n "$ai_csv" ]; then
        local csv_name=$(echo "$ai_csv" | awk '{print $2}')
        local csv_ns=$(echo "$ai_csv" | awk '{print $1}')
        local csv_phase=$(echo "$ai_csv" | awk '{print $NF}')
        
        if [ "$csv_phase" = "Succeeded" ]; then
            log_success "OpenShift AI operator is installed and healthy (phase: $csv_phase)"
        else
            log_warning "OpenShift AI operator phase is '$csv_phase' (expected: Succeeded)"
        fi
    else
        # If internal IFM is enabled, OpenShift AI operator is required
        if [ "$INTERNAL_IFM" = "true" ]; then
            log_error "OpenShift AI operator not found - REQUIRED for internal IFM"
        fi
    fi
    
    # Check for OpenShift AI namespaces
    local ai_namespaces=("redhat-ods-operator")
    local ns_found=false
    
    for ns in "${ai_namespaces[@]}"; do
        if oc get namespace "$ns" &> /dev/null; then
            log_success "OpenShift AI namespace exists: $ns"
            ns_found=true
            
            # Check pod status in the namespace
            local pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [ "$pods" -gt 0 ]; then
                local running_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
            fi
        fi
    done
    
    
    # Check for DataScienceCluster CRD
    if oc get crd datascienceclusters.datasciencecluster.opendatahub.io &> /dev/null; then
        log_success "DataScienceCluster CRD is present"
    fi
}

check_mcg_storage() {
    print_header "Checking Multicloud Object Gateway (MCG) Storage"
    
    local storage_classes=$(oc get storageclass --no-headers 2>/dev/null | awk '{print $1}')
    
    if [ -z "$storage_classes" ]; then
        log_error "No storage classes found in the cluster"
        return 0
    fi
    
    local mcg_found=false
    for sc in $storage_classes; do
        local provisioner=$(oc get storageclass "$sc" -o jsonpath='{.provisioner}' 2>/dev/null)
        local provisioner_lower=$(echo "$provisioner" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$provisioner_lower" == *"noobaa"* ]]; then
            log_success "MCG/NooBaa storage class found: $sc (provisioner: $provisioner)"
            mcg_found=true
        fi
    done
    
}

check_knative_eventing() {
    print_header "Checking OpenShift Serverless Knative Eventing"
    
    # Check for OpenShift Serverless operator
    local serverless_csv=$(oc get csv -n $PROJECT_IBM_EVENTS --no-headers 2>/dev/null | grep -i "serverless-operator" || echo "")
    
    if [ -z "$serverless_csv" ]; then
        log_error "OpenShift Serverless operator not found"
        log_error "  Install Red Hat OpenShift Serverless operator from OperatorHub"
        log_error "  This is required for Watson Assistant and Watson Orchestrate"
        return 0
    else
        # Check operator status/phase
        local csv_name=$(echo "$serverless_csv" | awk '{print $1}')
        local csv_phase=$(echo "$serverless_csv" | awk '{print $NF}')
        
        if [ "$csv_phase" = "Succeeded" ]; then
            log_success "OpenShift Serverless operator is running (phase: $csv_phase)"
        else
            log_warning "OpenShift Serverless operator phase is '$csv_phase' (expected: Succeeded)"
        fi
    fi
    
    # Check for Knative Eventing
    if oc get knativeeventings.operator.knative.dev --all-namespaces &> /dev/null; then
        local knative_eventing=$(oc get knativeeventings.operator.knative.dev --all-namespaces --no-headers 2>/dev/null)
        if [ -n "$knative_eventing" ]; then
            while IFS= read -r line; do
                if [ -n "$line" ]; then
                    local namespace=$(echo "$line" | awk '{print $1}')
                    local name=$(echo "$line" | awk '{print $2}')
                    local ready=$(echo "$line" | awk '{print $4}')
                    
                    if [ "$ready" != "True" ]; then
                        log_warning "Knative Eventing '$name' is not ready"
                    fi
                fi
            done <<< "$knative_eventing"
        else
            log_error "Knative Eventing custom resource not found"
            log_error "  Install Knative Eventing before Watson Orchestrate"
        fi
    else
        log_error "Knative Eventing CRD not found"
        log_error "  Install Knative Eventing before Watson Orchestrate"
        return 0
    fi
    
    # Check pod status in Knative-related namespaces
    local knative_namespaces=("openshift-serverless" "knative-eventing" "ibm-knative-events")
    
    for ns in "${knative_namespaces[@]}"; do
        if ! oc get namespace "$ns" &> /dev/null; then
            log_warning "Namespace '$ns' does not exist - skipping pod check"
            continue
        fi
        
        log_success "Namespace exists: $ns"
        
        # Check if namespace has pods
        local total_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        if [ "$total_pods" -eq 0 ]; then
            log_info "  No pods found in namespace: $ns"
            continue
        fi
        
        # Check for unhealthy pods (CrashLoopBackOff, Error, ImagePullBackOff, etc.)
        local bad_phase=$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '$3 ~ /(CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError)/ {print}' | head -n 1)
        if [ -n "$bad_phase" ]; then
            log_error "Unhealthy pod found in '$ns': $bad_phase"
            local restarts=$(echo "$bad_phase" | awk '{print $4}')
            if [ -n "$restarts" ] && [ "$restarts" -gt 5 ] 2>/dev/null; then
                log_info "  High restart count: $restarts"
            fi
            continue
        fi
        
        # Check for pending pods
        local pending_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '$3=="Pending" {print}' | wc -l | tr -d ' ')
        if [ "$pending_pods" -gt 0 ]; then
            log_warning "$pending_pods pod(s) in Pending state in '$ns'"
        fi
        
        # Check for pods not fully ready (Running but not all containers ready)
        local not_ready=$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '
            $3=="Running" {
                split($2,a,"/");
                if (a[1] != a[2]) print $0
            }
        ' | head -n 1)
        if [ -n "$not_ready" ]; then
            log_error "Pod not fully ready in '$ns': $not_ready"
            continue
        fi
        
        # Check for high restart counts
        local high_restarts=$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '$4 > 10 {print $1 " (" $4 " restarts)"}' | head -n 3)
        if [ -n "$high_restarts" ]; then
            log_warning "Pods with high restart counts in '$ns':"
            echo "$high_restarts" | while IFS= read -r line; do
                log_info "  $line"
            done
        fi
        
        # All checks passed
        log_success "All pods in '$ns' are healthy and fully ready (100%) for $ns [$total_pods pods]"
    done
    
}

check_watson_assistant_standalone() {
    print_header "Checking Watson Assistant Standalone Installation"
    
    # Check for Watson Assistant custom resources named 'wa' (standalone)
    local wa_standalone=$(oc get wa wa -A --no-headers 2>/dev/null)
    
    if [ -z "$wa_standalone" ]; then
        log_success "No standalone Watson Assistant instance found"
        return 0
    fi
    
    # Found standalone Watson Assistant instance(s)
    local conflict_found=false
    
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local namespace=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            
            log_error "Standalone Watson Assistant instance 'wa' found in namespace: $namespace"
            log_error "  Watson Orchestrate CANNOT be installed in namespace: $namespace"
            log_error "  You must choose a different namespace for Watson Orchestrate installation"
            conflict_found=true
        fi
    done <<< "$wa_standalone"
    
    if [ "$conflict_found" = true ]; then
        log_error "CRITICAL: Watson Assistant standalone conflicts detected"
    fi
}

check_gpu_support() {
    print_header "Checking GPU Support"
    
    # Check Node Feature Discovery (NFD) operator
    local nfd_csv=$(oc get csv --all-namespaces 2>/dev/null | grep -iE "nfd|node-feature-discovery" || echo "")
    if [ -n "$nfd_csv" ]; then
        log_success "Node Feature Discovery (NFD) operator is installed"
    else
        log_error "Node Feature Discovery (NFD) operator not found"
    fi
    
    # Check NVIDIA GPU Operator
    local nvidia_csv=$(oc get csv --all-namespaces 2>/dev/null | grep -iE "gpu-operator|nvidia" || echo "")
    if [ -n "$nvidia_csv" ]; then
        log_success "NVIDIA GPU operator is installed"
    else
        log_error "NVIDIA GPU operator not found"
    fi
    
    # Check for GPU nodes and count GPUs
    local gpu_node_list=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | awk '{print $1}')
    
    if [ -n "$gpu_node_list" ]; then
        local gpu_node_count=$(echo "$gpu_node_list" | wc -l | tr -d ' ')
        local total_gpus=0
        
        log_success "GPU nodes detected: $gpu_node_count"
        log_info "GPU details per node:"
        
        while IFS= read -r node; do
            if [ -n "$node" ]; then
                local gpu_count=$(oc get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)
                if [ -n "$gpu_count" ] && [ "$gpu_count" != "0" ]; then
                    log_info "  - $node: $gpu_count GPU(s)"
                    total_gpus=$((total_gpus + gpu_count))
                fi
            fi
        done <<< "$gpu_node_list"
    else
        log_error "No GPU nodes detected"
    fi
}

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --operator-ns)
                PROJECT_CPD_INST_OPERATORS="$2"
                shift 2
                ;;
            --operand-ns)
                PROJECT_CPD_INST_OPERANDS="$2"
                shift 2
                ;;
            --installation-type)
                INSTALLATION_TYPE="$2"
                shift 2
                ;;
            --internal-ifm)
                INTERNAL_IFM="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Validate required parameters
    if [ -z "$INSTALLATION_TYPE" ] && [ -z "$INTERNAL_IFM" ]; then
        log_error "Missing required parameters: --installation-type and --internal-ifm"
        log_error "  --installation-type: agentic, agentic_assistant, agentic_skills_assistant"
        log_error "  --internal-ifm: true, false"
        exit 1
    elif [ -z "$INSTALLATION_TYPE" ]; then
        log_error "Missing required parameter: --installation-type"
        log_error "Valid values: agentic, agentic_assistant, agentic_skills_assistant"
        exit 1
    elif [ -z "$INTERNAL_IFM" ]; then
        log_error "Missing required parameter: --internal-ifm"
        log_error "Valid values: true, false"
        exit 1
    fi
    
    # Validate installation type
    case "$INSTALLATION_TYPE" in
        agentic|agentic_assistant|agentic_skills_assistant)
            ;;
        *)
            log_error "Invalid installation type: $INSTALLATION_TYPE"
            log_error "Valid values: agentic, agentic_assistant, agentic_skills_assistant"
            exit 1
            ;;
    esac
    
    # Validate internal_ifm
    case "$INTERNAL_IFM" in
        true|false)
            ;;
        *)
            log_error "Invalid internal-ifm value: $INTERNAL_IFM"
            log_error "Valid values: true, false"
            exit 1
            ;;
    esac
    
    # Set defaults for optional parameters if not provided
    if [ -z "$PROJECT_CPD_INST_OPERATORS" ]; then
        PROJECT_CPD_INST_OPERATORS="cpd-operators"
        log_info "Using default operator namespace: $PROJECT_CPD_INST_OPERATORS"
    fi
    
    if [ -z "$PROJECT_CPD_INST_OPERANDS" ]; then
        PROJECT_CPD_INST_OPERANDS="cpd-instance-1"
        log_info "Using default operand namespace: $PROJECT_CPD_INST_OPERANDS"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "Starting Watson Orchestrate Pre-Installation Prerequisite Check"
    log_info "Timestamp: $(date)"
    log_info "Log file: $LOG_FILE"
    log ""
    log_info "Configurations:"
    log_info "   Operator Namespace: $PROJECT_CPD_INST_OPERATORS"
    log_info "   Operand Namespace: $PROJECT_CPD_INST_OPERANDS"
    log_info "   Installation Type: $INSTALLATION_TYPE"
    log_info "   Internal IFM: $INTERNAL_IFM"
    
    # Run all checks
    check_oc_login
    check_cluster_version
    check_worker_nodes
    check_storage_classes
    check_prerequisites
    check_software_hub_instance
    
    # Check OpenShift AI operator and GPU support only if internal IFM is enabled
    if [ "$INTERNAL_IFM" = "true" ]; then
        check_openshift_ai_operator
        check_gpu_support
    fi
    
    check_mcg_storage
    check_knative_eventing
    check_watson_assistant_standalone
    
    # Print summary
    print_summary
    return $?
}

# Parse command-line arguments
parse_arguments "$@"

# Run main function
main
exit $?
