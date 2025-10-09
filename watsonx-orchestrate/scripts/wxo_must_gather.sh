#!/bin/bash

   if [[ -z "$PROJECT_CPD_INST_OPERANDS" ]]; then
        echo "Please source your cpd_vars.sh file OR set your PROJECT_CPD_INST_OPERANDS env' variable and try again"
        exit 1
    fi

$OC_LOGIN
$CPDM_OC_LOGIN

echo -e "\n----------------------------------------------------------------------------"
echo -e "OPENSHIFT VERSION:"
echo -e "---------------------------------------------------------------------------- \n"

oc version 

echo -e "\n----------------------------------------------------------------------------"
echo -e "CLUSTER HEALTHCHECK:"
echo -e "---------------------------------------------------------------------------- \n"

cpd-cli health cluster
cpd-cli health nodes

echo -e "\n----------------------------------------------------------------------------"
echo -e "STATUS OF ALL NODES ON THE CLUSTER:"
echo -e "---------------------------------------------------------------------------- \n"

oc get nodes

echo -e "\n----------------------------------------------------------------------------"
echo -e "CURRENT NODE RESOURCE USAGE:"
echo -e "---------------------------------------------------------------------------- \n"

oc adm top node

echo -e "\n----------------------------------------------------------------------------"
echo -e "STORAGE USED:"
echo -e "---------------------------------------------------------------------------- \n"

oc get wo -oyaml -n $PROJECT_CPD_INST_OPERANDS | grep StorageClass

echo -e "\n----------------------------------------------------------------------------"
echo -e "WATSON ASSISTANT STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get wa -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "WATSON ORCHESTRATE STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get wo -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "CPD-CLI wxO STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} --components=watsonx_orchestrate

echo -e "\n----------------------------------------------------------------------------"
echo -e "FAILED WXO COMPONENTS:"
echo -e "---------------------------------------------------------------------------- \n"

foc=$(oc get wo -oyaml -n $PROJECT_CPD_INST_OPERANDS | grep "verified: false")
if [[ $foc ]]; then
        oc get wo -oyaml -n $PROJECT_CPD_INST_OPERANDS | grep "verified: false" -B4
else
        echo "${GREEN}✅  There are no wxO COMONENTS that have failed"
fi

echo -e "\n----------------------------------------------------------------------------"
echo -e "IFM STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get watsonxaiifm -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "MILVUS STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get wxdengines -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "UAB ADS STATUS:"
echo -e "---------------------------------------------------------------------------- \n"
oc get uabads -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "WORKFLOW STATUS:"
echo -e "---------------------------------------------------------------------------- \n"
oc get workflowservers -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "WO COMPONET SERVICES STATUS:"
echo -e "---------------------------------------------------------------------------- \n"
oc get wocomponentservices -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "DIGITAL EMPLOYEE STATUS:"
echo -e "---------------------------------------------------------------------------- \n"
oc get de -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "KAFKA STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get strimzi -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "POSTGRES CLUSTER STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get clusters.postgresql.k8s.enterprisedb.io -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "ETCDCLUSTER STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get etcdcluster -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "RABBITMQCLUSTER STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get rabbitmqcluster -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "REDIS STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get rediscp -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "NOOBAA STATUS:"
echo -e "---------------------------------------------------------------------------- \n"
oc get noobaa -A

echo -e "\nNoobaa pods:"
oc get pods -A | grep nooba

echo -e "\nNoobaa secrets:"
oc get secret -n $PROJECT_CPD_INST_OPERANDS | grep noobaa

echo -e "\n----------------------------------------------------------------------------"
echo -e "DATAGOVERNOR STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get datagovernor -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "KNATIVE STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get broker -A
oc get trigger -A

echo -e "\n----------------------------------------------------------------------------"
echo -e "DOCUMENT PROCESSOR STATUS:"
echo -e "---------------------------------------------------------------------------- \n"

oc get docproc -n $PROJECT_CPD_INST_OPERANDS

echo -e "\n----------------------------------------------------------------------------"
echo -e "LIST OF ALL FAILING PODS ON THE CLUSTER:"
echo -e "---------------------------------------------------------------------------- \n"

lfp=$(oc get pods -A --no-headers | grep -Ev '1/1|2/2|3/3|4/4|5/5|6/6|7/7|8/8' | grep -iv Completed)
if [[ $lfp ]]; then
        oc get pods -A | grep -Ev '1/1|2/2|3/3|4/4|5/5|6/6|7/7|8/8' | grep -iv Completed
else
        echo "${GREEN}✅ There are no PODS that have failed"
fi

echo -e "\n----------------------------------------------------------------------------"
echo -e "LIST OF ALL FAILING JOBS ON THE CLUSTER:"
echo -e "---------------------------------------------------------------------------- \n"

lfj=$(oc get job -A --no-headers | grep -v 1/1)
if [[ $lfj ]]; then
        oc get job -A | grep -v 1/1
else
        echo "${GREEN}✅  There are no JOBS that have failed"
fi

echo -e "\n----------------------------------------------------------------------------"
echo -e "LIST OF FAILED CERTIFICATES"
echo -e "---------------------------------------------------------------------------- \n"

lfc=$(oc get cert -A --no-headers | grep -v True)
if [[ $lfc ]]; then
        oc get job -A | grep -v 1/1
else
        echo "${GREEN}✅  There are no CERTIFICATES that have failed"
fi

echo -e "\n----------------------------------------------------------------------------"
echo -e "LIST OF EXPIRED SECRETS"
echo -e "---------------------------------------------------------------------------- \n"

# Function to check TLS secret expiry
check_tls_secrets() {
  oc get secrets -A -o go-template='{{range .items}}{{if eq .type "kubernetes.io/tls"}}{{.metadata.namespace}}{{" "}}{{.metadata.name}}{{" "}}{{index .data "tls.crt"}}{{"\n"}}{{end}}{{end}}' \
  | while read namespace name cert; do
      expiry=$(echo "$cert" | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if [[ -n "$expiry" ]]; then
          expiry_epoch=$(date -d "$expiry" +%s)
          now_epoch=$(date +%s)
          if (( expiry_epoch < now_epoch )); then
              echo -e "$namespace\t$name\t$expiry\t(internal TLS secret)"
          fi
      fi
  done
}

expired=$( { check_tls_secrets; } )
if [[ -z "$expired" ]]; then
    echo -e "${GREEN}✅ There are no SECRETS that have expired"
else
    echo -e "NAMESPACE\tNAME\tEXPIRY\tSOURCE"
    echo "$expired" | column -t
fi

echo -e "---------------------------------------------------------------------------- \n"
