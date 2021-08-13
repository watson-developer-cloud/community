#!/bin/bash
# 
#################################################################
# Licensed Materials - Property of IBM
# (C) Copyright IBM Corp. 2020.  All Rights Reserved.
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with
# IBM Corp.
#################################################################
#
# Script to dump OpenShift configuration information

if [ "$DEBUG" ] ; then
    set -x
fi

usage() { 
  echo "This command will attempt to authenticate with the specified OpenShift cluster and retrieve diagnostic information. The information will be compressed into a .tgz file."
  echo ""
  echo "If you need to debug this script, set DEBUG=true and run the script:"
  echo "DEBUG=true $0"
  echo ""
  echo "You can specify a different oc cli via the OCCLI env var. For example, export OCCLI=/tmp/oc321 will force the script to use the oc cli /tmp/oc321"
  echo ""
  echo "Usage:"
  echo "$0 [--cluster <openshift-cluster>] [--namespace <openshift-project>] [--username <openshift-admin-user>] [--password <openshift-admin-password>] [--skip-auth]" 1>&2
  echo ""
  echo "Flags:"
  echo "      -c, --cluster         The OpenShift cluster to connect to (without protocol and port number)"
  echo "      -n, --namespace       The OpenShift project (i.e. namespace) to run diagnostics against"
  echo "      -u, --username        The OpenShift username to log in with (defaults to \"ocadmin\")"
  echo "      -p, --password        The OpenShift password to log in with (defaults to \"ocadmin\")"
  echo "      --skip-auth           The namespace, username and password flags aren't required and will be ignored if they are supplied and"
  echo "                            the script will rely on the user having already authenticated with OpenShift (using oc login) before running the script."
  echo ""
  exit 1 
}

######################
# Get OC Version
######################
function getVersion {
  # RC will be 0 for Openshift v3 and 1 for v4
  $oc version | grep "openshift v3." >/dev/null 2>&1
  RC=$?
  if [ "$RC" == "0" ]; then
    echo "3"
  else
    echo "4"
  fi
}

runCommand() {
  command=$1
  title=$2
  echo "**********************************************************"
  echo "$title"
  echo "**********************************************************"
  eval $command || { echo "ERROR: $title" >&2; }
  echo -e "\n"
}

collectDiagnosticsData() {
  echo "********** OpenShift diagnostics data collected on ${openshift_diagnostic_collection_date} **********"
  echo -e "\n"
  echo "**********************************************************"
  echo "Collecting diagnostic data from Clustername $cluster"
  echo "**********************************************************"
  echo -e "\n"

  runCommand "$oc version" "Get oc version"

  runCommand "cloudctl version" "Get cloudctl version"

  runCommand "$oc get dvt --ignore-not-found" "Checking for DVT"

  runCommand "$oc get projects" "Get oc projects"

  echo "**********************************************************"
  echo "Get WA and YAML for each install"
  echo "**********************************************************"
  echo -e "\n"
  for i in `$oc get wa -o=jsonpath={.items[*].metadata.name}`; do
     eval $oc get wa $i -o yaml || { echo "ERROR: Get WA and YAML for each install" >&2; }
  done
  echo -e "\n"
 
  runCommand "$oc get routes --all-namespaces" "Get all routes"

  if [ "$OCVERSION" == "4" ]; then
    runCommand "$oc get routes default-route -n openshift-image-registry"  "Get docker external route"
  else
    runCommand "$oc get routes docker-registry -n default"  "Get docker external route"
  fi

  runCommand "$oc get nodes --show-labels -o wide" "Get nodes"

  runCommand "$oc get nodes -o=jsonpath=\"{range .items[*]}{.metadata.name}{'\t'}{.status.allocatable.memory}{'\t'}{.status.allocatable.cpu}{'\n'}{end}\"" "Memory and CPU"

  runCommand "$oc get images --all-namespaces" "Get list of images from kubernetes"

  runCommand "$oc get images | grep image-registry.openshift-image-registry.svc:5000/$namespace || true" "Get list of images from entitled registry/$namespace"
  
  runCommand "$oc get securitycontextconstraints" "Get SecurityContextConstraints"

  runCommand "$oc get serviceaccounts --all-namespaces" "Get ServiceAccounts"

  runCommand "$oc get roles --all-namespaces" "Get Roles"

  runCommand "$oc get rolebinding --all-namespaces" "Get RoleBindings"

  runCommand "$oc get certificates --all-namespaces" "Get Certificates"

  runCommand "$oc get networkpolicies --all-namespaces" "Get NetworkPolicies"

  runCommand "$oc get cronjobs --all-namespaces" "Get CronJobs"
  
  runCommand "$oc get clusterserviceversion --all-namespaces" "Get ClusterServiceVersions"

  runCommand "$oc get event --namespace=$namespace" "Get Events"

  runCommand "$oc get installplan --all-namespaces" "Get InstallPlans"

  runCommand "$oc get issuer --all-namespaces" "Get Issuers"

  runCommand "$oc get lease --all-namespaces" "Get Leases"

  runCommand "$oc get operandrequest --all-namespaces" "Get OperandRequests"

  runCommand "$oc get operatorgroup --all-namespaces" "Get OperatorGroups"

  runCommand "$oc get zenservice --all-namespaces" "Get ZenServices"

  echo "**********************************************************"
  echo "Checking SCC configuration - see https://github.com/IBM/cloud-pak/tree/master/samples/utilities"
  echo "**********************************************************"
  echo -e "\n"
  # Stolen from https://github.com/IBM/cloud-pak/blob/master/samples/utilities/getSCCs.sh

  TMP_IFS=$IFS
  IFS='
  '

  echo "Checking SCC configuration for namespace: $namespace"
  $oc get namespace $namespace &> /dev/null
  if [ $? -ne 0 ]; then
    echo "Namespace $namespace does not exist."
    exit 1
  fi


  $oc get scc -o name | while read SCC;do
    SCCNAME="$(echo $SCC | cut -d'/' -f2)"
    USERSFILE=$(mktemp)
    trap "rm -f $USERSFILE" EXIT


      # Find all groups from the current SCC
      $oc get $SCC -o jsonpath='{range .groups[*]}{@}{"\n"}{end}' | while read line;do 
        # Check to see if the service account namespace is in the name
        GROUPNS="$line"
        if [ "$GROUPNS" = "system:serviceaccounts:$namespace" ]; then
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "*sys:sa:ns" > $USERSFILE
        elif [ "$GROUPNS" = "system:authenticated" ]; then
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "*sys:auth" > $USERSFILE
        elif [ "$GROUPNS" = "system:serviceaccounts" ]; then
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "*sys:sa" > $USERSFILE
        fi
      done

      # Find all users from the current SCC
      $oc get $SCC -o jsonpath='{range .users[*]}{@}{"\n"}{end}' | while read line;do 
        # Check to see if the service account namespace is in the name
        USERNS="$(echo $line | cut -d':' -f1,2,3)"
        if [ "$USERNS" = "system:serviceaccount:$namespace" ]; then
          SA="$(echo $line | cut -d':' -f4)"
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "$SA" >> $USERSFILE
        fi
      done

      if [ -s "$USERSFILE" ]; then
        echo "$SCCNAME ($(cat $USERSFILE))"
      fi
  done

  IFS=$TMP_IFS
  echo -e "\n"

  runCommand "$oc get storageclass" "Get Storage Classes"
  
  runCommand "$oc describe storageclass" "Describe Storage Classes"  

  runCommand "$oc get persistentvolume" "Get Persistent Volumes"
  
  runCommand "$oc describe persistentvolume" "Describe Persistent Volumes"  

  runCommand "$oc get persistentvolumeclaims --all-namespaces" "Get Persistent Volume Claims"

  runCommand "$oc describe persistentvolumeclaims --all-namespaces" "Describe Persistent Volume Claims"

  runCommand "$oc get configmaps --namespace=$namespace" "Get ConfigMaps in $namespace namespace"

  runCommand "$oc get services --namespace=$namespace" "Get Services in $namespace namespace"

  runCommand "$oc get secrets --namespace=$namespace" "Get Secrets in $namespace namespace"

  runCommand "$oc get statefulsets --namespace=$namespace" "Get Stateful Sets in $namespace namespace"

  runCommand "$oc get replicasets --namespace=$namespace" "Get Replica Sets in $namespace namespace"

  runCommand "$oc get jobs --namespace=$namespace" "Get Jobs in $namespace namespace"

  runCommand "$oc describe jobs --namespace=$namespace" "Describe jobs in $namespace namespace"

  runCommand "$oc get deploy --namespace=$namespace" "Get Deployements in $namespace namespace"

  runCommand "$oc describe deploy --namespace=$namespace" "Describe Deployements in $namespace namespace"

  runCommand "$oc describe ingress --namespace=$namespace" "Describe Ingress in $namespace namespace"

  runCommand "$oc get pods --namespace=$namespace -o wide" "Get Pods in $namespace namespace"

  runCommand "$oc get packagemanifest --namespace=$namespace" "Get PackageManifest in $namespace namespace"

  runCommand "$oc describe packagemanifest --namespace=$namespace" "Describe PackageManifest in $namespace namespace"

  if [ "$OCVERSION" == "4" ]; then
    runCommand "$oc get catalogsource --namespace openshift-marketplace" "Get catalogsource in openshift-marketplace namespace"

    runCommand "$oc describe catalogsource --namespace openshift-marketplace" "Describe catalogsource in openshift-marketplace namespace"

    runCommand "$oc get csv --namespace ibm-common-services" "Get csv in ibm-common-services namespace"

    runCommand "$oc describe csv --namespace ibm-common-services" "Describe csv in ibm-common-services namespace"
  fi

  runCommand "$oc get crds --namespace=$namespace" "Get Custom Resource Definitions in $namespace namespace"

  echo "**********************************************************"
  echo "Get Custom Resource Definition objects in $namespace namespace"
  echo "**********************************************************"
  for i in `$oc get crds --namespace=$namespace | cut -f1 -d " " | sed -n '1!p'`; do
    echo "Listing $i"
    oc get $i --ignore-not-found --namespace=$namespace
    echo ""
  done
  
  runCommand "$oc describe crds --namespace=$namespace" "Describe Custom Resource Definition objects in $namespace namespace"

  runCommand "$oc get olm --namespace=$namespace" "Get OLM in $namespace namespace"

  runCommand "$oc describe olm --namespace=$namespace" "Describe OLM in $namespace namespace"

  runCommand "$oc get subs --namespace=$namespace" "Get Subscription in $namespace namespace"

  runCommand "$oc describe subs --namespace=$namespace" "Describe Subscription in $namespace namespace"

  echo "**********************************************************"
  echo "Fetching Portworx Status"
  echo "**********************************************************"
  echo -e "\n"
  $oc get pods -n kube-system | grep portworx
  echo -e "\n"

  PX_POD=$($oc get pods -l name=portworx -n kube-system -o jsonpath='{.items[0].metadata.name}')
  $oc exec $PX_POD -n kube-system -- /opt/pwx/bin/pxctl status
  echo -e "\n"

  runCommand "$oc get pods --all-namespaces -o wide | grep portworx-api" "Get Portworx Pods in all namespaces"

  echo "**********************************************************"
  echo "Describe Kubernetes Pods in $namespace namespace"
  echo "**********************************************************"
  echo -e "\n"

  getOpenShiftPodsResult=$($oc get pods --namespace=$namespace -o custom-columns=NAME:.metadata.name --no-headers) || { echo "ERROR: Failed to get list of pods." >&2; exit 2; }
  if [ -z "$getOpenShiftPodsResult" ]; then
    echo "No pods found in namespace $namespace"
    echo -e "\n"
  else
    echo "Running Describe for the following pods"
    echo "---------------------------------------"
    echo "${getOpenShiftPodsResult}"
    echo -e "\n"

    echo "$getOpenShiftPodsResult" |
    while read openshiftPodName; do
      echo -e "--------- $openshiftPodName ----------\n"
      $oc describe pods $openshiftPodName --namespace=$namespace || { echo "ERROR: Failed to describe pod $openshiftPodName." >&2; exit 2; }
      echo -e "----------------------------------------------------------------\n"
    done
    echo -e "\n"

    echo "**********************************************************"
    echo "Downloading Portworx logs"
    echo "**********************************************************"
    echo -e "\n"
    PX_PODS=$($oc get pods -n kube-system -l name=portworx --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')
    echo "$PX_PODS" |
    while read px_pod; do
      $oc logs -n kube-system $px_pod > ${openshift_diagnostic_logs_folder}/$px_pod.log || { echo "ERROR: Failed to get logs for Portworx." >&2; }
    done

    echo "**********************************************************"
    echo "Downloading logs from $namespace pods"
    echo "**********************************************************"
    echo -e "\n"

    echo "$getOpenShiftPodsResult" |
    while read openshiftPodName; do
      echo "**********************************************************"
      echo "$opeshiftPodName log(s)"
      echo "**********************************************************"
      echo -e "\n"
      while read openshiftContainerName; do
        echo "**********************************************************"
        echo "$openshiftPodName ($openshiftContainerName) log"
        echo "**********************************************************"
        echo "Writing log to ${openshift_diagnostic_data_folder}/$openshiftPodName-$openshiftContainerName.log"
        echo -e "\n"
        $oc logs $openshiftPodName --namespace=$namespace -c $openshiftContainerName > ${openshift_diagnostic_logs_folder}/$openshiftPodName-$openshiftContainerName.log || { echo "ERROR: Failed to get logs for pod $openshiftPodName($openshiftContainerName)." >&2; }
      done <<<"$(echo "$($oc get pods $openshiftPodName -o jsonpath='{.spec.initContainers[*].name}') $($oc get pods $openshiftPodName -o jsonpath='{.spec.containers[*].name}')" | xargs | tr " " "\n")"
    done
    echo -e "\n"
  fi
}

#########################################################################################
#                                MAIN
#########################################################################################

cluster=
namespace=
username=ocadmin
password=ocadmin
skipAuth=false
# Allow user to specify full path of oc client via OCCLI env var. If OCCLI env var isn't set, use oc found in PATH.
# i.e export OCCLI=/tmp/oc321 will force the script to use the /tmp/oc321 cli.
oc="${OCCLI:-oc}"
RC=0

while (( $# > 0 )); do
  case "$1" in
    -c | --cluster )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo -e "Error: You must specify a cluster."
        echo "**********************************************************"
        usage 
      fi
      shift
      cluster="$1"
      ;;
    -n | --namespace )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo "Error: You must specify a namespace."
        echo "**********************************************************"
        usage
      fi
      shift
      namespace="$1"
      ;;
    -u | --username )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo "Error: You must specify a username."
        echo "**********************************************************"
        echo -e "\n"
        usage
      fi
      shift
      username="$1"
      ;;
    -p | --password )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo "Error: You must specify a password."
        echo "**********************************************************"
        echo -e "\n"
        usage
      fi
      shift
      password="$1"
      ;;
    --skip-auth )
      skipAuth=true
      ;;  
    -h | --h | --help )
      usage 
      exit 0
      ;;
    * | -* )
      echo "Unknown option: $1"
      echo -e "\n"
      usage
      exit 99
      ;;
  esac
  shift
done

if [ -z "$cluster" ]; then
  echo "**********************************************************"
  echo "Error: You must specify a cluster."
  echo "**********************************************************"
  echo ""
  usage
  exit 1
fi

if [ -z "$namespace" ] && ! $skipAuth; then
  echo "**********************************************************"
  echo "Error: You must specify a namespace."
  echo "**********************************************************"
  echo ""
  usage
  exit 1
fi

if ! which $oc; then
  echo "$oc client not found. Ensure that you have oc installed and on your PATH."
  exit 1
fi

if ! which cloudctl; then
  echo "Cloudctl client not found. Ensure that you have cloudctl installed and on your PATH."
  exit 1
fi
################
# Get OC Version
################
OCVERSION=$(getVersion)
echo "Found OpenShift v${OCVERSION}"
echo ""
#Set vars based on OpenShift version
if [ "$OCVERSION" == "4" ]; then
  SSH_USER="core"
  cluster_port=6443
else
  SSH_USER="root"
  cluster_port=8443
fi

if ! $skipAuth; then
  echo "**********************************************************"
  echo "Logging into OpenShift"
  echo "**********************************************************"
  $oc login https://$cluster:$cluster_port -u $username -p $password || { echo "ERROR: Logging into OpenShift Failed." >&2; exit 3; }
  $oc project $namespace || { echo "ERROR: Switching to project $namespace Failed." >&2; exit 3; }
fi

echo -e "\n"

openshift_diagnostic_collection_date=`date +"%d_%m_%y_%H_%M_%S"`

# if the user skipped auth then we'll fetch the current namespace
if $skipAuth; then
  namespace=$($oc get sa default -o jsonpath='{.metadata.namespace}')
fi

echo "********** OpenShift diagnostics: Starting data collection for Cluster=$cluster & Namespace=$namespace at ${openshift_diagnostic_collection_date} **********"
echo -e "\n"

tempFolder="."
openshift_diagnostic_data_folder_name="${cluster}_${openshift_diagnostic_collection_date}"
openshift_diagnostic_data_folder="${tempFolder}/${openshift_diagnostic_data_folder_name}"
openshift_diagnostic_logs_folder="${openshift_diagnostic_data_folder}/logs"
openshift_diagnostic_data_log="${openshift_diagnostic_data_folder}/watson-diagnostics-data.log"
openshift_diagnostic_data_zipped_file="${openshift_diagnostic_data_folder}.tgz"

echo "Creating temporary folder ${openshift_diagnostic_data_folder}"
if `mkdir -p ${openshift_diagnostic_logs_folder}`; then
  echo "Successfully created temporary folder ${openshift_diagnostic_data_folder}"
else
  echo "Failed creating temporary folder ${openshift_diagnostic_data_folder}"
  exit 1
fi

echo "Collecting Diagnostics data. Please wait...."
echo "NB Any errors caught will be printed below and to the log."
echo "-------------------------------------------"
# redirect output so that stdout and stderr are sent to openshift_diagnostic_data_log ... and stderr is also sent to the console
collectDiagnosticsData $@1 >>${openshift_diagnostic_data_log} 2> >(tee -a ${openshift_diagnostic_data_log} >&2)

$oc describe node >${openshift_diagnostic_data_folder_name}/describe_node.txt
echo -e "\n"

echo "Zipping up OpenShift Diagnostics data from ${openshift_diagnostic_data_folder}"
tar cfz ${openshift_diagnostic_data_zipped_file} --directory ${tempFolder} ${openshift_diagnostic_data_folder_name}
if [ $? -eq 0 ]; then
  echo "Cleaning up temporary folder ${openshift_diagnostic_data_folder}"
  rm -rf ${openshift_diagnostic_data_folder}
  echo "********** Successfully collected and zipped up OpenShift diagnostics data. The diagnostics data is available at ${openshift_diagnostic_data_zipped_file} **********"
else
  echo "********** Failed to zip up diagnostics data. Diagnostics data folder is available at ${openshift_diagnostic_data_folder} **********"
fi
