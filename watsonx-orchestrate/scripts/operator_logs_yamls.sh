#!/bin/bash

if [[ -z "$PROJECT_CPD_INST_OPERATORS"|| -z "$PROJECT_CPD_INST_OPERANDS" ]]; then
        echo -e "\nPlease source your cpd_vars.sh file OR set your PROJECT_CPD_INST_OPERANDS and PROJECT_CPD_INST_OPERATORS env' variables and try again \n"
        exit 1
fi

if [ -d "./operatorLogs+yamls" ]
then
  rm -rf operatorLogs+yamls
fi

mkdir operatorLogs+yamls
mkdir operatorLogs+yamls/logs
mkdir operatorLogs+yamls/yamls

echo -e " \nGathering the Watsonx Orchestrate operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep wo-operator | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/WO-operator.log

echo -e "Gathering the Watsonx Orchestrate yaml ..........  \n"
oc get wo -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/WO.yaml

echo -e "Gathering the Watsonx Assistant operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-watson-assistant-operator | grep -v catalog | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/WA-operator.log

echo -e "Gathering the Watsonx Assistant yaml ..........  \n"
oc get wa -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/WA.yaml

echo -e "Gathering the Digital Employee operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep digital-employee-operator | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/DigitalEmployee-operator.log

echo -e "Gathering the Digital Employee yaml ..........  \n"
oc get de -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/DigitalEmployee.yaml

echo -e "Gathering the ADS operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-uab-ads-operator | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/ADS-operator.log

echo -e "Gathering the ADS yaml ..........  \n"
oc get uabads -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/ADS.yaml

echo -e "Gathering the Workflow operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ba-saas-uab-wf-operator | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Workflow-operator.log

echo -e "Gathering the Workflow yaml ..........  \n"
oc get workflowservers -n $PROJECT_CPD_INST_OPERANDS > operatorLogs+yamls/yamls/Workflow.yaml
echo -e "\n" >> operatorLogs+yamls/yamls/Workflow.yaml
oc get workflowservers -n $PROJECT_CPD_INST_OPERANDS -oyaml >> operatorLogs+yamls/yamls/Workflow.yaml

echo -e "Gathering the Document Processor operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-document-processing-operator | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/DocProc-operator.log

echo -e "Gathering the Document Processor yaml ..........  \n"
oc get docproc -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/DocProc.yaml

echo -e "Gathering the Milvus operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-lakehouse-controller-manager | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Milvus-operator.log

echo -e "Gathering the Milvus yaml ..........  \n"
oc get wxdengines -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/Milvus.yaml

echo -e "Gathering the ETCD operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-etcd-operator  | grep -v catalog | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/ETCD-operator.log

echo -e "Gathering the ETCD yaml ..........  \n"
oc get etcdcluster -n $PROJECT_CPD_INST_OPERANDS > operatorLogs+yamls/yamls/ETCD.yaml
echo -e "\n" >> operatorLogs+yamls/yamls/ETCD.yaml
oc get etcdcluster -n $PROJECT_CPD_INST_OPERANDS -oyaml >> operatorLogs+yamls/yamls/ETCD.yaml

echo -e "Gathering the Rabbitmq operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-rabbitmq-operator  | grep -v catalog | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Rabbitmq-operator.log

echo -e "Gathering the Rabbitmq yaml ..........  \n"
oc get rabbitmqcluster -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/Rabbitmq.yaml

echo -e "Gathering the Watsonx AI IFM operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-cpd-watsonx-ai-ifm-operator | grep -v catalog | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Watsonxaiifm-operator.log

echo -e "Gathering the Watsonx AI IFM yaml ..........  \n"
oc get watsonxaiifm -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/Watsonxaiifm.yaml

echo -e "Gathering the WO Component Controller operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-wxo-componentcontroller-manager | awk '{ print $1 }' | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/WO-Component-Services-operator.log 2> /dev/null

echo -e "Gathering the WO component services yaml ..........  \n"
oc get wocomponentservices -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/WO-Component-Services.yaml

echo -e "Gathering the Kafka operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERANDS | grep kafka-entity-operator | awk '{ print $1 }'  | xargs oc logs -n $PROJECT_CPD_INST_OPERANDS > operatorLogs+yamls/logs/Kafka-operator.log

echo -e "Gathering the Kafka yamls ..........  \n"
oc get strimzi -n $PROJECT_CPD_INST_OPERANDS > operatorLogs+yamls/yamls/Kafka.yaml
echo -e "\n" >> operatorLogs+yamls/yamls/Kafka.yaml
oc get strimzi -n $PROJECT_CPD_INST_OPERANDS -oyaml >> operatorLogs+yamls/yamls/Kafka.yaml

echo -e "Gathering the postgres operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep postgresql-operator-controller-manager | awk '{ print $1 }'  | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Postgresql-operator.log

echo -e "Gathering the wo-watson-orchestrate-postgresedb postgres yaml .........."
oc get cluster.postgres -n $PROJECT_CPD_INST_OPERANDS wo-watson-orchestrate-postgresedb -oyaml >> operatorLogs+yamls/yamls/wo-watson-orchestrate-postgresedb.yaml

echo -e "Gathering the wo-wa-postgres-16 postgres yaml ..........  \n"
oc get cluster.postgres -n $PROJECT_CPD_INST_OPERANDS wo-wa-postgres-16 -oyaml > operatorLogs+yamls/yamls/wo-wa-postgres-16.yaml

echo -e "Gathering the redis operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-redis-cp-operator | awk '{ print $1 }'  | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Redis-operator.log

echo -e "Gathering the redis yamls ..........  \n"
oc get rediscp -n $PROJECT_CPD_INST_OPERANDS > operatorLogs+yamls/yamls/Redis.yaml
echo -e "\n" >> operatorLogs+yamls/yamls/Redis.yaml
oc get rediscp -n $PROJECT_CPD_INST_OPERANDS -oyaml >> operatorLogs+yamls/yamls/Redis.yaml

echo -e "Gathering the datagovernor operator log .........."
oc get pod -n $PROJECT_CPD_INST_OPERATORS | grep ibm-data-governor-operator | grep -v catalog | awk '{ print $1 }'  | xargs oc logs -n $PROJECT_CPD_INST_OPERATORS > operatorLogs+yamls/logs/Data-Governor-operator.log

echo -e "Gathering the datagovernor yaml ..........  \n"
oc get datagovernor -n $PROJECT_CPD_INST_OPERANDS -oyaml > operatorLogs+yamls/yamls/DataGovernor.yaml


echo -e "\n ----------------------------------------------------------------------------------------------------------------------"

tar -czvf operatorLogs+yamls.tar.gz operatorLogs+yamls

rm -rf operatorLogs+yamls
