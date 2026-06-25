#!/bin/sh
################################################################################
# Watson Orchestrate Pre-Installation/Upgrade Prerequisite Check Script
#
# Description: This script validates all prerequisites before Watson Orchestrate
#              installation or upgrade.
#
# Authors: Amal Paul, Manu Thapar
# Version: 1.2.0
#
# Documentation References:
#   Documentation URLs are dynamically generated based on the --version parameter
#   - IBM Software Hub: https://www.ibm.com/docs/en/software-hub/{version}.x
#   - Watson Orchestrate Installation: https://www.ibm.com/docs/en/software-hub/{version}.x?topic=orchestrate-installing
#   - GPU Requirements: https://www.ibm.com/docs/en/software-hub/{version}.x?topic=requirements-gpu-models
#   - MCG Installation: https://www.ibm.com/docs/en/cloud-paks/cp-data/5.0.x?topic=software-installing-multicloud-object-gateway
#   - Knative Eventing: https://www.ibm.com/docs/en/software-hub/{version}.x?topic=software-installing-red-hat-openshift-serverless-knative-eventing
#
# Usage: sh wxo-prereq-check.sh [OPTIONS]
#
# Options:
#   --mode <install|upgrade>       Check mode (required)
#   --operator-ns <namespace>      CPD operators namespace (optional, default: auto-detect or cpd-operators)
#   --operand-ns <namespace>       CPD operands namespace (optional, default: auto-detect or cpd-instance-1)
#   --version <version>            Watson Orchestrate version (required for install, optional for upgrade, e.g., 5.3.0, 5.3.1, 5.4.0)
#   --installation-type <type>     Installation type (required)
#                                  For version 5.3.0: agentic, agentic_assistant, agentic_skills_assistant
#                                  For version >= 5.3.1: agentic, agentic_assistant
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
MODE=""  # install or upgrade (required parameter)
VERSION=""
INSTALLATION_TYPE=""
INTERNAL_IFM=""

# Storage class validation arrays (based on IBM Software Hub documentation)
# Reference: Documentation URL is dynamically generated based on version
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

# Function to get documentation URL based on version
get_doc_url() {
    local doc_type="$1"
    local version_major_minor=$(echo "$VERSION" | cut -d. -f1,2)
    
    case "$doc_type" in
        "installing")
            echo "https://www.ibm.com/docs/en/software-hub/${version_major_minor}.x?topic=orchestrate-installing"
            ;;
        "gpu-requirements")
            echo "https://www.ibm.com/docs/en/software-hub/${version_major_minor}.x?topic=requirements-gpu-models"
            ;;
        "knative-eventing")
            echo "https://www.ibm.com/docs/en/software-hub/${version_major_minor}.x?topic=software-installing-red-hat-openshift-serverless-knative-eventing"
            ;;
        "software-hub")
            echo "https://www.ibm.com/docs/en/software-hub/${version_major_minor}.x?topic=installing-instance-software-hub"
            ;;
        "base")
            echo "https://www.ibm.com/docs/en/software-hub/${version_major_minor}.x"
            ;;
        *)
            echo "https://www.ibm.com/docs/en/software-hub/${version_major_minor}.x"
            ;;
    esac
}

usage() {
    cat << EOF
Watson Orchestrate Pre-Installation/Upgrade Prerequisite Check Script

Usage: $0 [OPTIONS]

Options:
  --mode <install|upgrade>       Check mode (required)
                                 - install: Validates prerequisites for new installation
                                 - upgrade: Validates existing deployment and upgrade readiness
  --operator-ns <namespace>      CPD operators namespace (optional, default: auto-detect or cpd-operators)
  --operand-ns <namespace>       CPD operands namespace (optional, default: auto-detect or cpd-instance-1)
  --version <version>            Watson Orchestrate version (required for install, optional for upgrade, e.g., 5.3.0, 5.3.1, 5.4.0)
  --installation-type <type>     Installation type (required)
                                 For version 5.3.0: agentic, agentic_assistant, agentic_skills_assistant
                                 For version >= 5.3.1: agentic, agentic_assistant
  --internal-ifm <true|false>    Internal IFM flag (required)
  -h, --help                     Display this help message

Mode Details:
  INSTALL MODE (default):
    - Requires: --version, --installation-type, --internal-ifm
    - Validates prerequisites for fresh Watson Orchestrate installation
    - Checks cluster resources, storage, operators, and dependencies
    
  UPGRADE MODE:
    - Requires: --installation-type, --internal-ifm
    - Optional: --version
    - Validates existing Watson Orchestrate deployment health
    - Checks instance status (must be Ready/Completed)
    - Verifies no pending PVCs or failed jobs
    - Reports current versions and compatibility
    - Provides upgrade readiness assessment

Examples:
  # INSTALLATION MODE (requires --version, --installation-type, --internal-ifm)
  $0 --version 5.3.0 --installation-type agentic --internal-ifm true

  # Version 5.3.0 with agentic_skills_assistant
  $0 --version 5.3.0 --installation-type agentic_skills_assistant --internal-ifm true

  # Version 5.3.1 or later (agentic_skills_assistant not available)
  $0 --version 5.3.1 --installation-type agentic_assistant --internal-ifm false

  # Version 5.4.0 or later
  $0 --version 5.4.0 --installation-type agentic --internal-ifm true

  # Specify custom namespaces for installation
  $0 --operator-ns my-operators --operand-ns my-operands --version 5.3.1 --installation-type agentic --internal-ifm false

  # UPGRADE MODE (requires --mode, --installation-type, and --internal-ifm)
  $0 --mode upgrade --installation-type agentic --internal-ifm true

  # Upgrade with custom namespaces
  $0 --mode upgrade --installation-type agentic_assistant --internal-ifm false --operator-ns my-operators --operand-ns my-operands

  # Using environment variables for installation
  PROJECT_CPD_INST_OPERATORS=my-operators PROJECT_CPD_INST_OPERANDS=my-operands \\
    $0 --version 5.3.0 --installation-type agentic_skills_assistant --internal-ifm true

  # Using environment variables for upgrade
  PROJECT_CPD_INST_OPERATORS=my-operators PROJECT_CPD_INST_OPERANDS=my-operands \\
    $0 --mode upgrade --installation-type agentic --internal-ifm true

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
        if [ "$MODE" = "upgrade" ]; then
            log_success "All prerequisites checks PASSED. You can proceed with Watson Orchestrate upgrade."
        else
            log_success "All prerequisites checks PASSED. You can proceed with Watson Orchestrate installation."
        fi
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
    
    # Only check minimum worker nodes requirement in install mode
    if [ "$MODE" = "install" ]; then
        if [ "$worker_nodes" -lt "$MIN_WORKER_NODES" ]; then
            log_error "Insufficient worker nodes. Found: $worker_nodes, Required: $MIN_WORKER_NODES"
        else
            log_success "Worker nodes: $worker_nodes (minimum: $MIN_WORKER_NODES)"
        fi
    else
        # In upgrade mode, just report the count without minimum check
        log_success "Worker nodes: $worker_nodes"
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
    log_info "Please Validate storage classes against IBM Software Hub requirements..."
    log_info "Reference: $(get_doc_url 'installing')"
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
        log_error "  Install IBM Software Hub first: $(get_doc_url 'software-hub')"
        return 0
    fi

    
    if ! oc get ibmcpd ibmcpd-cr -n "$PROJECT_CPD_INST_OPERANDS" &> /dev/null; then
        log_error "IBM Software Hub custom resource 'ibmcpd-cr' not found in namespace: $PROJECT_CPD_INST_OPERANDS"
        log_error "  IBM Software Hub must be installed before Watson Orchestrate"
        log_error "  Install IBM Software Hub first: $(get_doc_url 'software-hub')"
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
        if [ "$MODE" = "install" ]; then
        log_error "  Wait for ZenService to reach 100% before installing Watson Orchestrate"
        fi
        if [ "$MODE" = "upgrade" ]; then
        log_error "  Check ZenServce and IBM Software Hub installation before proceeding with upgrade."
        fi  
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
            --mode)
                MODE="$2"
                shift 2
                ;;
            --operator-ns)
                PROJECT_CPD_INST_OPERATORS="$2"
                shift 2
                ;;
            --operand-ns)
                PROJECT_CPD_INST_OPERANDS="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
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
    
    # Validate MODE is provided
    if [ -z "$MODE" ]; then
        log_error "Missing required parameter: --mode"
        log_error "Valid values: install, upgrade"
        exit 1
    fi
    
    # Validate MODE value
    if [ "$MODE" != "install" ] && [ "$MODE" != "upgrade" ]; then
        log_error "Invalid mode: $MODE"
        log_error "Valid values: install, upgrade"
        exit 1
    fi
    
    # Validate required parameters for INSTALL mode
    if [ "$MODE" = "install" ]; then
        if [ -z "$VERSION" ] && [ -z "$INSTALLATION_TYPE" ] && [ -z "$INTERNAL_IFM" ]; then
            log_error "Missing required parameters: --version, --installation-type, and --internal-ifm"
            log_error "  --version: 5.3.0, 5.3.1, 5.3.2, 5.4.0, or later 5.3.x/5.4.x versions"
            log_error "  --installation-type: agentic, agentic_assistant, agentic_skills_assistant (5.3.0 only)"
            log_error "  --internal-ifm: true, false"
            exit 1
        elif [ -z "$VERSION" ]; then
            log_error "Missing required parameter: --version"
            log_error "Valid values: 5.3.0, 5.3.1, 5.3.2, 5.4.0, or later 5.3.x/5.4.x versions"
            exit 1
        elif [ -z "$INSTALLATION_TYPE" ]; then
            log_error "Missing required parameter: --installation-type"
            log_error "Valid values depend on version:"
            log_error "  Version 5.3.0: agentic, agentic_assistant, agentic_skills_assistant"
            log_error "  Version >= 5.3.1: agentic, agentic_assistant"
            exit 1
        elif [ -z "$INTERNAL_IFM" ]; then
            log_error "Missing required parameter: --internal-ifm"
            log_error "Valid values: true, false"
            exit 1
        fi
    fi
    
    # For UPGRADE mode, installation-type and internal-ifm are required, version is optional
    if [ "$MODE" = "upgrade" ]; then
        if [ -z "$INSTALLATION_TYPE" ] && [ -z "$INTERNAL_IFM" ]; then
            log_error "Missing required parameters: --installation-type and --internal-ifm"
            log_error "  --installation-type: agentic, agentic_assistant, agentic_skills_assistant (5.3.0 only)"
            log_error "  --internal-ifm: true, false"
            exit 1
        elif [ -z "$INSTALLATION_TYPE" ]; then
            log_error "Missing required parameter: --installation-type"
            log_error "Valid values depend on version:"
            log_error "  Version 5.3.0: agentic, agentic_assistant, agentic_skills_assistant"
            log_error "  Version >= 5.3.1: agentic, agentic_assistant"
            exit 1
        elif [ -z "$INTERNAL_IFM" ]; then
            log_error "Missing required parameter: --internal-ifm"
            log_error "Valid values: true, false"
            exit 1
        fi
        log_info "Running in UPGRADE mode - version is optional"
    fi
    
    # Validate version format (basic check) - only if VERSION is provided
    if [ -n "$VERSION" ]; then
        if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            log_error "Invalid version format: $VERSION"
            log_error "Expected format: X.Y.Z (e.g., 5.3.0, 5.3.1, 5.4.0)"
            exit 1
        fi
    fi
    
    # Version comparison function
    version_compare() {
        # Returns 0 if $1 >= $2, 1 otherwise
        local ver1=$1
        local ver2=$2
        
        # Split versions into components
        local v1_major=$(echo "$ver1" | cut -d. -f1)
        local v1_minor=$(echo "$ver1" | cut -d. -f2)
        local v1_patch=$(echo "$ver1" | cut -d. -f3)
        
        local v2_major=$(echo "$ver2" | cut -d. -f1)
        local v2_minor=$(echo "$ver2" | cut -d. -f2)
        local v2_patch=$(echo "$ver2" | cut -d. -f3)
        
        # Compare major version
        if [ "$v1_major" -gt "$v2_major" ]; then
            return 0
        elif [ "$v1_major" -lt "$v2_major" ]; then
            return 1
        fi
        
        # Compare minor version
        if [ "$v1_minor" -gt "$v2_minor" ]; then
            return 0
        elif [ "$v1_minor" -lt "$v2_minor" ]; then
            return 1
        fi
        
        # Compare patch version
        if [ "$v1_patch" -ge "$v2_patch" ]; then
            return 0
        else
            return 1
        fi
    }
    
    # Validate version and installation type only if provided (for install mode or optional upgrade validation)
    if [ -n "$VERSION" ]; then
        # Check if version is less than 5.3.0
        if ! version_compare "$VERSION" "5.3.0"; then
            log_error "Unsupported version: $VERSION"
            log_error "Watson Orchestrate version must be 5.3.0 or higher"
            log_error "This script supports versions 5.3.0 and above"
            exit 1
        fi
    fi
    
    # Validate installation type based on version (only if both are provided)
    if [ -n "$VERSION" ] && [ -n "$INSTALLATION_TYPE" ]; then
        if version_compare "$VERSION" "5.3.1"; then
            # Version >= 5.3.1: agentic_skills_assistant is NOT available
            case "$INSTALLATION_TYPE" in
                agentic|agentic_assistant)
                    ;;
                agentic_skills_assistant)
                    log_error "Invalid installation type for version $VERSION: $INSTALLATION_TYPE"
                    log_error "The 'agentic_skills_assistant' installation type is only available in version 5.3.0"
                    log_error "Valid values for version >= 5.3.1: agentic, agentic_assistant"
                    exit 1
                    ;;
                *)
                    log_error "Invalid installation type: $INSTALLATION_TYPE"
                    log_error "Valid values for version >= 5.3.1: agentic, agentic_assistant"
                    exit 1
                    ;;
            esac
        else
            # Version 5.3.0: all installation types are available
            case "$INSTALLATION_TYPE" in
                agentic|agentic_assistant|agentic_skills_assistant)
                    ;;
                *)
                    log_error "Invalid installation type: $INSTALLATION_TYPE"
                    log_error "Valid values for version 5.3.0: agentic, agentic_assistant, agentic_skills_assistant"
                    exit 1
                    ;;
            esac
        fi
    fi
    
    # Validate internal_ifm only if provided
    if [ -n "$INTERNAL_IFM" ]; then
        case "$INTERNAL_IFM" in
            true|false)
                ;;
            *)
                log_error "Invalid internal-ifm value: $INTERNAL_IFM"
                log_error "Valid values: true, false"
                exit 1
                ;;
        esac
    fi
    
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

check_upgrade_prerequisites() {
    print_header "Upgrade-Specific Prerequisites"
    
    # Check for running Watson Orchestrate instances
    local wo_instances=$(oc get watsonxorchestrates -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$wo_instances" -eq 0 ]; then
        log_error "No Watson Orchestrate instances found in '$PROJECT_CPD_INST_OPERANDS'"
        log_error "  Cannot upgrade without an existing Watson Orchestrate installation"
        return 0
    fi
    
    log_success "Found $wo_instances Watson Orchestrate instance(s) in '$PROJECT_CPD_INST_OPERANDS'"
    
    # Check instance status by RECONCILE_PROGRESS
    # Format varies by version:
    # 5.3.x: NAME VERSION DEPLOYED VERIFIED TOTAL INSTALLMODE QUIESCE RECONCILE_PROGRESS AGE
    # 5.4.x: NAME VERSION PATCH_VERSION READY DEPLOYING_COMPONENT DEPLOYED VERIFIED INSTALLMODE QUIESCE RECONCILE_PROGRESS AGE
    #        Note: PATCH_VERSION can contain spaces like "GA (8.0.0)"
    
    # Get header to detect format
    local header=$(oc get watsonxorchestrates -n "$PROJECT_CPD_INST_OPERANDS" 2>/dev/null | head -n 1)
    local has_patch_version=0
    if echo "$header" | grep -q "PATCH_VERSION"; then
        has_patch_version=1
    fi
    
    oc get watsonxorchestrates -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local version=$(echo "$line" | awk '{print $2}')
        local reconcile_progress
        local details
        
        if [ "$has_patch_version" -eq 1 ]; then
            # 5.4.x format: PATCH_VERSION can have spaces, so find RECONCILE_PROGRESS by searching backwards from end
            # The last field is AGE, second-to-last is RECONCILE_PROGRESS
            reconcile_progress=$(echo "$line" | awk '{print $(NF-1)}')
            # Extract patch version (everything between column 3 and before READY column)
            # READY is always "True" or "False", use it as marker
            local patch_version=$(echo "$line" | sed 's/.*'"$version"' \(.*\) True.*/\1/' | sed 's/.*'"$version"' \(.*\) False.*/\1/')
            details="version: $version $patch_version"
        else
            # 5.3.x format: RECONCILE_PROGRESS is second-to-last column (before AGE)
            local deployed=$(echo "$line" | awk '{print $3}')
            local verified=$(echo "$line" | awk '{print $4}')
            local total=$(echo "$line" | awk '{print $5}')
            reconcile_progress=$(echo "$line" | awk '{print $(NF-1)}')
            details="version: $version, deployed: $deployed/$total, verified: $verified/$total"
        fi
        
        if [ "$reconcile_progress" = "100%" ]; then
            log_success "WO instance '$name' is in Completed state ($details, reconcile progress: $reconcile_progress)"
        else
            log_error "WO instance '$name' is not in Completed state ($details, reconcile progress: $reconcile_progress)"
            log_error "  Instance must have RECONCILE_PROGRESS at 100% before upgrade"
        fi
    done
    
    # Check for pending PVCs
    local pending_pvcs=$(oc get pvc -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | awk '$2=="Pending" {print $1}' | wc -l | tr -d ' ')
    if [ "$pending_pvcs" -gt 0 ]; then
        log_error "Found $pending_pvcs pending PVC(s) in '$PROJECT_CPD_INST_OPERANDS'"
        log_error "  Resolve PVC issues before upgrade"
        oc get pvc -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | awk '$2=="Pending" {print "    " $1}'
    else
        log_success "No pending PVCs in '$PROJECT_CPD_INST_OPERANDS'"
    fi
    
    # Check for failed jobs
    local failed_jobs=$(oc get jobs -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | awk '$3 ~ /0\/1/ && $4 > 0 {print $1}' | wc -l | tr -d ' ')
    if [ "$failed_jobs" -gt 0 ]; then
        log_warning "Found $failed_jobs failed job(s) in '$PROJECT_CPD_INST_OPERANDS'"
        log_warning "  Review and resolve failed jobs before upgrade"
    else
        log_success "No failed jobs in '$PROJECT_CPD_INST_OPERANDS'"
    fi
    
    # Check cluster version stability
    local cluster_progressing=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo 'Unknown')
    if [ "$cluster_progressing" = "False" ]; then
        log_success "Cluster version is stable (not progressing)"
    else
        log_warning "Cluster version is progressing - wait for stability before upgrade"
    fi
}

check_image_overrides() {
    print_header "Checking for Image Overrides"
    
    log_info "Checking for image overrides applied through WO CR..."
    
    # Check for image overrides in WatsonxOrchestrate CR
    local wo_instances=$(oc get watsonxorchestrates -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | awk '{print $1}')
    
    if [ -z "$wo_instances" ]; then
        log_warning "No Watson Orchestrate instances found in '$PROJECT_CPD_INST_OPERANDS'"
        return 0
    fi
    
    local overrides_found=0
    
    for instance in $wo_instances; do
        log_info "Checking WO instance: $instance"
        
        # Check for digestOverrides in spec.image.digestOverrides
        local has_digest_overrides=$(oc get watsonxorchestrates "$instance" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
            jq -r 'select(.spec.image.digestOverrides != null) | "true"')
        
        if [ "$has_digest_overrides" = "true" ]; then
            overrides_found=1
            log_error "Image digest overrides detected in WO CR '$instance'"
            log_error "  Found spec.image.digestOverrides configuration"
            
            # Show the digest override details
            local digest_count=$(oc get watsonxorchestrates "$instance" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
                jq -r '.spec.image.digestOverrides | length' 2>/dev/null)
            
            if [ -n "$digest_count" ] && [ "$digest_count" != "null" ]; then
                log_error "  Number of digest overrides: $digest_count"
                
                # List the overridden images
                local overridden_images=$(oc get watsonxorchestrates "$instance" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
                    jq -r '.spec.image.digestOverrides | keys[]' 2>/dev/null)
                
                if [ -n "$overridden_images" ]; then
                    log_error "  Overridden images:"
                    echo "$overridden_images" | while IFS= read -r img; do
                        local digest=$(oc get watsonxorchestrates "$instance" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
                            jq -r ".spec.image.digestOverrides[\"$img\"]" 2>/dev/null)
                        log_error "    - $img: $digest"
                    done
                fi
            fi
        fi
        
        # Check for other image override fields (legacy or alternative formats)
        local has_other_overrides=$(oc get watsonxorchestrates "$instance" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
            jq -r 'select(.spec.image_overrides != null or .spec.imageOverrides != null or .spec.images != null) | "true"')
        
        if [ "$has_other_overrides" = "true" ]; then
            overrides_found=1
            log_error "Image overrides detected in WO CR '$instance'"
            log_error "  Found image override configuration in spec"
            
            # Show the override details
            local override_details=$(oc get watsonxorchestrates "$instance" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
                jq -r '.spec | {image_overrides, imageOverrides, images} | to_entries | map(select(.value != null)) | .[] | "    \(.key): \(.value | keys | join(", "))"' 2>/dev/null)
            
            if [ -n "$override_details" ]; then
                log_error "  Override fields found:"
                echo "$override_details" | while IFS= read -r line; do
                    log_error "$line"
                done
            fi
        fi
    done
    
    # Check for image overrides in related ConfigMaps
    local override_configmaps=$(oc get configmap -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | \
        awk '{print $1}' | grep -E 'image-override|wo-image' || true)
    
    if [ -n "$override_configmaps" ]; then
        overrides_found=1
        log_error "Found ConfigMaps that may contain image overrides:"
        echo "$override_configmaps" | while IFS= read -r cm; do
            log_error "  ConfigMap: $cm"
        done
    fi
    
    # Check for image overrides in related Secrets
    local override_secrets=$(oc get secret -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | \
        awk '{print $1}' | grep -E 'image-override|wo-image' || true)
    
    if [ -n "$override_secrets" ]; then
        overrides_found=1
        log_error "Found Secrets that may contain image overrides:"
        echo "$override_secrets" | while IFS= read -r secret; do
            log_error "  Secret: $secret"
        done
    fi
    
    if [ "$overrides_found" -eq 1 ]; then
        log_error "Image overrides detected - these must be removed before upgrade"
        log_error "Contact IBM Support for guidance on removing image overrides"
    else
        log_success "No image overrides detected in WO CR or related resources"
    fi
}

check_certificate_san_entries() {
    print_header "Checking Certificate SAN Entries"
    
    log_info "Checking for certificates with incorrect SAN entries from previous releases..."
    
    # List of certificates that may have incorrect SAN entries
    local affected_certs=(
        "wo-ibm-connectivity-pack-tls-icert"
        "wo-connection-manager-service-tls-icert"
        "wo-automation-discovery-tls-icert"
        "wo-discover-skills-tls-icert"
        "wo-archer-de-client-tls-icert"
        "wo-uiproxy-tls-icert"
    )
    
    local bad_certs_found=0
    local certs_to_delete=()
    
    for cert_name in "${affected_certs[@]}"; do
        # Check if certificate exists
        if ! oc get certificate "$cert_name" -n "$PROJECT_CPD_INST_OPERANDS" &>/dev/null; then
            log_info "Certificate '$cert_name' not found (may not be installed yet)"
            continue
        fi
        
        log_info "Checking certificate: $cert_name"
        
        # Get DNS names from the certificate
        local dns_names=$(oc get certificate "$cert_name" -n "$PROJECT_CPD_INST_OPERANDS" -o json 2>/dev/null | \
            jq -r '.spec.dnsNames[]?' 2>/dev/null)
        
        if [ -z "$dns_names" ]; then
            log_warning "Could not retrieve DNS names for certificate '$cert_name'"
            continue
        fi
        
        # Check for incorrect SAN entries (missing dots in DNS names)
        # Correct format: wo-uiproxy.watsonx, wo-uiproxy.watsonx.svc, wo-uiproxy.watsonx.svc.cluster.local
        # Incorrect format: wo-uiproxy-watsonx, wo-uiproxy-watsonx.svc, wo-uiproxy-watsonx.svc.cluster.local
        local has_bad_san=0
        local bad_entries=""
        
        while IFS= read -r dns_name; do
            # Check if DNS name contains hyphen before namespace instead of dot
            # Pattern: service-name-namespace instead of service-name.namespace
            if echo "$dns_name" | grep -qE "^wo-[a-z-]+-${PROJECT_CPD_INST_OPERANDS}(\.|$)"; then
                has_bad_san=1
                bad_entries="${bad_entries}    - $dns_name (should use dot separator, not hyphen)\n"
            fi
        done <<< "$dns_names"
        
        if [ "$has_bad_san" -eq 1 ]; then
            bad_certs_found=1
            certs_to_delete+=("$cert_name")
            log_error "Certificate '$cert_name' has incorrect SAN entries:"
            printf "%b" "$bad_entries" | while IFS= read -r line; do
                [ -n "$line" ] && log_error "$line"
            done
        else
            log_success "Certificate '$cert_name' has correct SAN entries"
        fi
    done
    
    if [ "$bad_certs_found" -eq 1 ]; then
        log_error "Certificates with incorrect SAN entries detected - these must be deleted before upgrade"
        log_error "  The operator will automatically recreate them with correct SAN entries"
    else
        log_success "All checked certificates have correct SAN entries"
    fi
}

check_version_compatibility() {
    print_header "Version Compatibility Check"
    
    # Get current WO version from VERSION column (column 2)
    local current_wo_ver=$(oc get watsonxorchestrates -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | awk 'NR==1{print $2}')
    if [ -n "$current_wo_ver" ]; then
        log_success "Current Watson Orchestrate version: $current_wo_ver"
    else
        log_warning "Could not determine current Watson Orchestrate version"
    fi
    
    # Get CPD platform version
    local cpd_ver=$(oc get zenservices lite-cr -n "$PROJECT_CPD_INST_OPERANDS" --no-headers 2>/dev/null | awk '{print $2}')
    if [ -n "$cpd_ver" ]; then
        log_success "Current Cloud Pak for Data version: $cpd_ver"
    else
        log_warning "Could not determine Cloud Pak for Data version"
    fi
    
    # Get OpenShift version
    local ocp_ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo 'unknown')
    if [ "$ocp_ver" != "unknown" ]; then
        log_success "OpenShift version: $ocp_ver"
        
        # Check if OCP version is supported (basic check for 4.x)
        local ocp_major=$(echo "$ocp_ver" | cut -d. -f1)
        local ocp_minor=$(echo "$ocp_ver" | cut -d. -f2)
        
        if [ "$ocp_major" = "4" ] && [ "$ocp_minor" -ge 12 ]; then
            log_success "OpenShift version is supported (4.12+)"
        else
            log_warning "OpenShift version may not be supported - verify compatibility"
        fi
    else
        log_warning "Could not determine OpenShift version"
    fi
}

main() {
    local mode_text="Pre-Installation"
    if [ "$MODE" = "upgrade" ]; then
        mode_text="Pre-Upgrade"
    fi
    
    log_info "Starting Watson Orchestrate $mode_text Prerequisite Check"
    log_info "Timestamp: $(date)"
    log_info "Log file: $LOG_FILE"
    log ""
    log_info "Configurations:"
    log_info "   Check Mode: $MODE"
    if [ -n "$VERSION" ]; then
        log_info "   Watson Orchestrate Version: $VERSION"
    fi
    log_info "   Operator Namespace: $PROJECT_CPD_INST_OPERATORS"
    log_info "   Operand Namespace: $PROJECT_CPD_INST_OPERANDS"
    if [ -n "$INSTALLATION_TYPE" ]; then
        log_info "   Installation Type: $INSTALLATION_TYPE"
    fi
    if [ -n "$INTERNAL_IFM" ]; then
        log_info "   Internal IFM: $INTERNAL_IFM"
    fi
    
    check_oc_login
    check_cluster_version
    check_worker_nodes
    
    # Skip storage class validation in upgrade mode (already installed)
    if [ "$MODE" = "install" ]; then
        check_storage_classes
        check_prerequisites
    fi    
    check_software_hub_instance
    
    # Check OpenShift AI operator and GPU support only if internal IFM is enabled (or in upgrade mode)
    if [ "$INTERNAL_IFM" = "true" ]; then
        check_openshift_ai_operator
        if [ "$INTERNAL_IFM" = "true" ]; then
            check_gpu_support
        fi
    fi

    # Skip Multicloud Object Gateway (MCG) Storage validation in upgrade mode (already installed)
    if [ "$MODE" = "install" ]; then
        check_mcg_storage
    fi

    # Skip Knative Eventing check for 'agentic' installation type (or check in upgrade mode)
    if [ "$INSTALLATION_TYPE" != "agentic" ] || [ "$MODE" = "upgrade" ]; then
        check_knative_eventing
    fi
    
    check_watson_assistant_standalone
    
    # Run upgrade-specific checks if in upgrade mode
    if [ "$MODE" = "upgrade" ]; then
        check_version_compatibility
        check_certificate_san_entries
        check_image_overrides
        check_upgrade_prerequisites
    fi
    
    # Print summary
    print_summary
    return $?
}

# Parse command-line arguments
parse_arguments "$@"

# Run main function
main
exit $?
