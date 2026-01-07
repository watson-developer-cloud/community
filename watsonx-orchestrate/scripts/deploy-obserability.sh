#!/usr/bin/env bash
set -e
set -o pipefail

Help() 
{
cat << EOM
deploy-observability
--------------------
Apply the needed setup to support the use of observability in WatsonX Orchestrate.
This software is required if you want use observability features like agent tracing
in your development.  NOTE: All options all optional, for most people things will
work without options, only use optional if they are needed for your specific setup.

Basic Syntax
------
${CMD_PREFIX} deploy-observability

Optional Syntax
------
${CMD_PREFIX} deploy-observability \
[--image_pull_secret=<IBM Image Repo Access Key> \]
[--image_pull_prefix=<Optiona: IBM Image Repo URL> \]
[--cpd_instance_ns=<Optional: Namespace for resources> \]
[--os_user=<Optional: OpenSearch Username> \]
[--os_pass=<Optional: OpenSearch password> \]
[--redhat_token=<RedHat Image Repo Access Token> \]

Options
-------
--image_pull_secret=<Optional: IBM Image Repo Access Key>
    The IBM image repo access key for IBM images download.  Only 
    needed if you are using a different repo than cp.icr.io
--image_pull_prefix=<Optional: IBM image repo url>
    The url for the IBM image repo, if needed.  Default: cp.icr.io
--cpd_instance_ns=<Optional: Namespace for resources>
    The namespace to use for the Observability resources.  Default: cpd-instance-1
--os_user=<Optional: OpenSearch Username>
    The username for use to access OpenSearch.  Default: admin
--os_pass=<Optional: OpenSearch password> 
    The password for use to access OpenSearch.  Default: a 16 character random string
--redhat_token=<Optional: RedHat Image Repo Access Token>
    The access token for the RedHat image repo, to download the operators for use.
    Only needed if you want to use a different token from the OpenShift install.

EOM
exit
}

wait_for_endpoints() {
  local ns="$1"
  local svc="$2"

  echo "Waiting for service endpoints: $svc in namespace: $ns"

  for i in {1..60}; do
    if oc get endpoints "$svc" -n "$ns" -o jsonpath='{.subsets[*].addresses}' | grep -q .; then
      echo "Service $svc has ready endpoints."
      return 0
    fi

    echo "Waiting for endpoints... ($i/60)"
    sleep 5
  done

  echo "ERROR: Service $svc did not become ready."
  exit 1
}

wait_for_cluster() {
  local ns="$1"
  local cluster="$2"

  echo "Waiting for Opensearch cluster: $cluster in namespace: $ns"
  
  for i in {1..60}; do
    PHASE=$(oc get cluster "$cluster" -n  "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Available" ]]; then
        echo "OpenSearch cluster is ready: phase=${PHASE}"
        return 0
    fi

    echo "Waiting... phase=${PHASE}..($i/60)"
    sleep 5
  done

  echo "ERROR: Cluster $cluster did not become ready."
  exit 1
}

InstallIBMOpenSearchClusterYAML() {
  local ns="$1"
  local OS_USER="$2"
  local OS_PASS="$3"
  local IMAGE_PREFIX="$4"
  cat <<EOF | oc apply -f -
---
# Source: opencontent-opensearch/templates/configmap.yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: wo-opensearch-custom-config
  namespace: $ns
data:
  debug: 'false'
  forceEphemeral: 'false'
  jvm.options: |
    ## JVM configuration

    ################################################################
    ## IMPORTANT: JVM heap size
    ################################################################
    ##
    ## You should always set the min and max JVM heap
    ## size to the same value. For example, to set
    ## the heap to 4 GB, set:
    ##
    ## -Xms4g
    ## -Xmx4g
    ##
    ## See https://opensearch.org/docs/opensearch/install/important-settings/
    ## for more information
    ##
    ################################################################

    # Xms represents the initial size of total heap space
    # Xmx represents the maximum size of total heap space



    -Xms1G
    -Xmx1G

    ################################################################
    ## Expert settings
    ################################################################
    ##
    ## All settings below this section are considered
    ## expert settings. Don't tamper with them unless
    ## you understand what you are doing
    ##
    ################################################################

    ## GC configuration
    8-10:-XX:+UseConcMarkSweepGC
    8-10:-XX:CMSInitiatingOccupancyFraction=75
    8-10:-XX:+UseCMSInitiatingOccupancyOnly

    ## G1GC Configuration
    # NOTE: G1GC is the default GC for all JDKs 11 and newer
    11-:-XX:+UseG1GC
    # See https://github.com/elastic/elasticsearch/pull/46169 for the history
    # behind these settings, but the tl;dr is that default values can lead
    # to situations where heap usage grows enough to trigger a circuit breaker
    # before GC kicks in.
    11-:-XX:G1ReservePercent=25
    11-:-XX:InitiatingHeapOccupancyPercent=30

    ## JVM temporary directory
    -Djava.io.tmpdir=\${OPENSEARCH_TMPDIR}

    ## heap dumps

    # generate a heap dump when an allocation from the Java heap fails
    # heap dumps are created in the working directory of the JVM
    -XX:+HeapDumpOnOutOfMemoryError

    # specify an alternative path for heap dumps; ensure the directory exists and
    # has sufficient space
    -XX:HeapDumpPath=data

    # specify an alternative path for JVM fatal error logs
    -XX:ErrorFile=logs/hs_err_pid%p.log

    ## JDK 8 GC logging
    8:-XX:+PrintGCDetails
    8:-XX:+PrintGCDateStamps
    8:-XX:+PrintTenuringDistribution
    8:-XX:+PrintGCApplicationStoppedTime
    8:-Xloggc:logs/gc.log
    8:-XX:+UseGCLogFileRotation
    8:-XX:NumberOfGCLogFiles=32
    8:-XX:GCLogFileSize=64m

    # JDK 9+ GC logging
    9-:-Xlog:gc*,gc+age=trace,safepoint:file=logs/gc.log:utctime,pid,tags:filecount=32,filesize=64m

    # Explicitly allow security manager (https://bugs.openjdk.java.net/browse/JDK-8270380)
    18-:-Djava.security.manager=allow

    # JDK 20+ Incubating Vector Module for SIMD optimizations;
    # disabling may reduce performance on vector optimized lucene
    20-:--add-modules=jdk.incubator.vector

    # HDFS ForkJoinPool.common() support by SecurityManager
    -Djava.util.concurrent.ForkJoinPool.common.threadFactory=org.opensearch.secure_sm.SecuredForkJoinWorkerThreadFactory

    # Suppress warnings for java agent loading for Instana
    -XX:+EnableDynamicAgentLoading
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: wo-opensearch-ca
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wo-opensearch-ca-cert
  namespace: $ns
spec:
  isCA: true
  secretName: wo-opensearch-ca-secret
  commonName: wo-opensearch-ca
  issuerRef:
    name: wo-opensearch-ca
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: wo-opensearch-ca-signer
  namespace: $ns
spec:
  ca:
    secretName: wo-opensearch-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wo-opensearch-cert
  namespace: $ns
spec:
  secretName: wo-opensearch-tls
  duration: 8760h
  renewBefore: 720h
  commonName: wo-opensearch-cluster.$ns.svc.cluster.local
  dnsNames:
    - wo-opensearch-cluster.$ns.svc.cluster.local
  keyUsages:
    - digital signature
    - key encipherment
  extendedKeyUsages:
    - server auth
  issuerRef:
    name: wo-opensearch-ca-signer
    kind: Issuer
---
apiVersion: v1
kind: Secret
metadata:
  name: wo-opensearch-cluster-login-secret
  namespace: $ns
type: kubernetes.io/opaque
stringData:
  $OS_USER: $OS_PASS
---
apiVersion: opensearch.cloudpackopen.ibm.com/v1
kind: Cluster
metadata:
  labels:
    app.kubernetes.io/created-by: ibm-opensearch-operator
    app.kubernetes.io/instance: single
    app.kubernetes.io/managed-by: ansible
    app.kubernetes.io/name: cluster
    app.kubernetes.io/part-of: ibm-opensearch-operator
    icpdsupport/addOnId: ibm-opensearch-operator
  name: wo-opensearch-cluster
  namespace: $ns
spec:
  backup:
    brConfigmapPriority: 100
    checkpointConfigmapPriority: 100
    enable: true
    sizeLimit: 30Gi
    snapshotPVC: ""
    snapshotPVCStorageClass: ocs-storagecluster-cephfs
    snapshotWhitelistIndices: ""
  baseImage: ${IMAGE_PREFIX}/cp/opencontent-ibm-opensearch-base-10@sha256:d8c9304f57765e88c0325a16e5cb11b03a1f7ffb290505f526ac3c894cebf1a5
  license:
    accept: true
  nodePools:
  - addConfigmaps:
    - location: /workdir/opensearch/config/jvm.options
      name: wo-opensearch-custom-config
      subPath: jvm.options
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: kubernetes.io/arch
              operator: In
              values:
              - amd64
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - podAffinityTerm:
            labelSelector:
              matchLabels:
                cluster.opensearch.cloudpackopen.ibm.com: wo-opensearch-cluster
                nodepool.opensearch.cloudpackopen.ibm.com: wo-opensearch-cluster-all
            topologyKey: kubernetes.io/hostname
          weight: 80
    captureContainerLogLimit: 30
    disableConfigMounts:
      jvmOptions: true
    name: all
    opensearchyml: |
      indices.query.bool.max_clause_count: 1024
      cluster.auto_shrink_voting_configuration: false
      cluster.election.back_off_time: 500ms
      cluster.election.duration: 2500ms
      cluster.election.initial_timeout: 500ms
      cluster.election.max_timeout: 51s
      cluster.routing.allocation.disk.watermark.flood_stage: 500mb
      cluster.routing.allocation.disk.watermark.high: 1gb
      cluster.routing.allocation.disk.watermark.low: 2gb
      discovery.find_peers_interval: 10000ms
      discovery.probe.handshake_timeout: 5000ms
      discovery.request_peers_timeout: 10000ms
      discovery.seed_resolver.timeout: 10s
      http.compression: false
      node.max_local_storage_nodes: 1
      script.max_size_in_bytes: 10000000
      search.max_buckets: 5000000
      plugins.security.ssl.http.enabled: true
      plugins.security.allow_default_init_securityindex: true
      plugins.security.nodes_dn:
        - 'CN=internal-tls-certificate*'
    patches:
    - name: libpath
      nodePoolKubernetesPods: '[{ "op": "add", "path": "/spec/containers/0/env/-1",
        "value": { "name": "LD_LIBRARY_PATH", "value": "/workdir/opensearch/plugins/opensearch-knn/lib"
        }}]'
    replicas: 3
    resources:
      limits:
        cpu: 1000m
        memory: 2Gi
      requests:
        cpu: 80m
        memory: 1Gi
    storage:
      data:
        sizeLimit: 30Gi
        storageClass: ocs-storagecluster-ceph-rbd
        useEphemeral: false
      deployment:
        sizeLimit: 2Gi
        storageClass: ""
        useEphemeral: true
  opensearchImage: ${IMAGE_PREFIX}/cp/opencontent-ibm-opensearch-min-2.19.3@sha256:a7fd1076b7cf9964860b8ea24c6ed7f8d3abfbd2662610a93568305a485b4455
  plugins:
    image: ${IMAGE_PREFIX}/cp/opencontent-ibm-opensearch-plugins-2.19.3@sha256:f33e22e5929bb9475ec692cd58e6b6720998da62c9288ef68410ac4873a92eda
    knn:
      enabled: true
      image: ${IMAGE_PREFIX}/cp/opencontent-ibm-opensearch-plugin-knn-2.19.3.0@sha256:63fa066bec1f240e7a610fd3948f568f42a0b273306d94dd904f67146a76d597
      version: 2.19.3.0
    security:
      enabled: true
      image: ${IMAGE_PREFIX}/cp/opencontent-ibm-opensearch-plugin-security-2.19.3.0@sha256:53e1c55af88a052eaf02537c9b2137228749c4cccaba0634455333e015115439
      internalUserSecret: wo-opensearch-cluster-login-secret
      version: 2.19.3.0
      httpCertificateSecret: wo-opensearch-tls
  serviceAccount: ""
  version: 2.19.3
EOF
}

InstallOtelOperatorYAML() {
  local RH_TOKEN="$1"
  cat <<EOF | oc apply -f -
---
# Source: opentelemetry-operator/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
automountServiceAccountToken: true
metadata:
  name: opentelemetry-operator
  namespace: cpd-operators
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
---
# Source: opentelemetry-operator/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: 15478606-opentelemetry-operator-pull-pull-secret
data:
  .dockerconfigjson: $RH_TOKEN
type: kubernetes.io/dockerconfigjson
---
# Source: opentelemetry-operator/templates/admission-webhooks/operator-webhook.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
  creationTimestamp: null
  labels:
    app.kubernetes.io/name: opentelemetry-operator
  name: opampbridges.opentelemetry.io
spec:
  group: opentelemetry.io
  names:
    kind: OpAMPBridge
    listKind: OpAMPBridgeList
    plural: opampbridges
    singular: opampbridge
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    - description: OpenTelemetry Version
      jsonPath: .status.version
      name: Version
      type: string
    - jsonPath: .spec.endpoint
      name: Endpoint
      type: string
    name: v1alpha1
    schema:
      openAPIV3Schema:
        properties:
          apiVersion:
            type: string
          kind:
            type: string
          metadata:
            type: object
          spec:
            properties:
              affinity:
                properties:
                  nodeAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            preference:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            weight:
                              format: int32
                              type: integer
                          required:
                          - preference
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        properties:
                          nodeSelectorTerms:
                            items:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            type: array
                            x-kubernetes-list-type: atomic
                        required:
                        - nodeSelectorTerms
                        type: object
                        x-kubernetes-map-type: atomic
                    type: object
                  podAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  podAntiAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                type: object
              capabilities:
                additionalProperties:
                  type: boolean
                type: object
              componentsAllowed:
                additionalProperties:
                  items:
                    type: string
                  type: array
                type: object
              description:
                properties:
                  non_identifying_attributes:
                    additionalProperties:
                      type: string
                    type: object
                required:
                - non_identifying_attributes
                type: object
              endpoint:
                type: string
              env:
                items:
                  properties:
                    name:
                      type: string
                    value:
                      type: string
                    valueFrom:
                      properties:
                        configMapKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                        fieldRef:
                          properties:
                            apiVersion:
                              type: string
                            fieldPath:
                              type: string
                          required:
                          - fieldPath
                          type: object
                          x-kubernetes-map-type: atomic
                        resourceFieldRef:
                          properties:
                            containerName:
                              type: string
                            divisor:
                              anyOf:
                              - type: integer
                              - type: string
                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                              x-kubernetes-int-or-string: true
                            resource:
                              type: string
                          required:
                          - resource
                          type: object
                          x-kubernetes-map-type: atomic
                        secretKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                      type: object
                  required:
                  - name
                  type: object
                type: array
              envFrom:
                items:
                  properties:
                    configMapRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    prefix:
                      type: string
                    secretRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                  type: object
                type: array
              headers:
                additionalProperties:
                  type: string
                type: object
              hostNetwork:
                type: boolean
              image:
                type: string
              imagePullPolicy:
                type: string
              ipFamilies:
                items:
                  type: string
                type: array
              ipFamilyPolicy:
                type: string
              nodeSelector:
                additionalProperties:
                  type: string
                type: object
              podAnnotations:
                additionalProperties:
                  type: string
                type: object
              podDnsConfig:
                properties:
                  nameservers:
                    items:
                      type: string
                    type: array
                    x-kubernetes-list-type: atomic
                  options:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  searches:
                    items:
                      type: string
                    type: array
                    x-kubernetes-list-type: atomic
                type: object
              podSecurityContext:
                properties:
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  fsGroup:
                    format: int64
                    type: integer
                  fsGroupChangePolicy:
                    type: string
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxChangePolicy:
                    type: string
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  supplementalGroups:
                    items:
                      format: int64
                      type: integer
                    type: array
                    x-kubernetes-list-type: atomic
                  supplementalGroupsPolicy:
                    type: string
                  sysctls:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      required:
                      - name
                      - value
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              ports:
                items:
                  properties:
                    appProtocol:
                      type: string
                    name:
                      type: string
                    nodePort:
                      format: int32
                      type: integer
                    port:
                      format: int32
                      type: integer
                    protocol:
                      default: TCP
                      type: string
                    targetPort:
                      anyOf:
                      - type: integer
                      - type: string
                      x-kubernetes-int-or-string: true
                  required:
                  - port
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              priorityClassName:
                type: string
              replicas:
                format: int32
                maximum: 1
                type: integer
              resources:
                properties:
                  claims:
                    items:
                      properties:
                        name:
                          type: string
                        request:
                          type: string
                      required:
                      - name
                      type: object
                    type: array
                    x-kubernetes-list-map-keys:
                    - name
                    x-kubernetes-list-type: map
                  limits:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                  requests:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                type: object
              securityContext:
                properties:
                  allowPrivilegeEscalation:
                    type: boolean
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  capabilities:
                    properties:
                      add:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                      drop:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  privileged:
                    type: boolean
                  procMount:
                    type: string
                  readOnlyRootFilesystem:
                    type: boolean
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              serviceAccount:
                type: string
              tolerations:
                items:
                  properties:
                    effect:
                      type: string
                    key:
                      type: string
                    operator:
                      type: string
                    tolerationSeconds:
                      format: int64
                      type: integer
                    value:
                      type: string
                  type: object
                type: array
              topologySpreadConstraints:
                items:
                  properties:
                    labelSelector:
                      properties:
                        matchExpressions:
                          items:
                            properties:
                              key:
                                type: string
                              operator:
                                type: string
                              values:
                                items:
                                  type: string
                                type: array
                                x-kubernetes-list-type: atomic
                            required:
                            - key
                            - operator
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        matchLabels:
                          additionalProperties:
                            type: string
                          type: object
                      type: object
                      x-kubernetes-map-type: atomic
                    matchLabelKeys:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    maxSkew:
                      format: int32
                      type: integer
                    minDomains:
                      format: int32
                      type: integer
                    nodeAffinityPolicy:
                      type: string
                    nodeTaintsPolicy:
                      type: string
                    topologyKey:
                      type: string
                    whenUnsatisfiable:
                      type: string
                  required:
                  - maxSkew
                  - topologyKey
                  - whenUnsatisfiable
                  type: object
                type: array
              upgradeStrategy:
                enum:
                - automatic
                - none
                type: string
              volumeMounts:
                items:
                  properties:
                    mountPath:
                      type: string
                    mountPropagation:
                      type: string
                    name:
                      type: string
                    readOnly:
                      type: boolean
                    recursiveReadOnly:
                      type: string
                    subPath:
                      type: string
                    subPathExpr:
                      type: string
                  required:
                  - mountPath
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              volumes:
                items:
                  properties:
                    awsElasticBlockStore:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    azureDisk:
                      properties:
                        cachingMode:
                          type: string
                        diskName:
                          type: string
                        diskURI:
                          type: string
                        fsType:
                          default: ext4
                          type: string
                        kind:
                          type: string
                        readOnly:
                          default: false
                          type: boolean
                      required:
                      - diskName
                      - diskURI
                      type: object
                    azureFile:
                      properties:
                        readOnly:
                          type: boolean
                        secretName:
                          type: string
                        shareName:
                          type: string
                      required:
                      - secretName
                      - shareName
                      type: object
                    cephfs:
                      properties:
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        secretFile:
                          type: string
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          type: string
                      required:
                      - monitors
                      type: object
                    cinder:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    configMap:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    csi:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        nodePublishSecretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        readOnly:
                          type: boolean
                        volumeAttributes:
                          additionalProperties:
                            type: string
                          type: object
                      required:
                      - driver
                      type: object
                    downwardAPI:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                            required:
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    emptyDir:
                      properties:
                        medium:
                          type: string
                        sizeLimit:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                      type: object
                    ephemeral:
                      properties:
                        volumeClaimTemplate:
                          properties:
                            metadata:
                              properties:
                                annotations:
                                  additionalProperties:
                                    type: string
                                  type: object
                                finalizers:
                                  items:
                                    type: string
                                  type: array
                                labels:
                                  additionalProperties:
                                    type: string
                                  type: object
                                name:
                                  type: string
                                namespace:
                                  type: string
                              type: object
                            spec:
                              properties:
                                accessModes:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                dataSource:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                  x-kubernetes-map-type: atomic
                                dataSourceRef:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                    namespace:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                resources:
                                  properties:
                                    limits:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                    requests:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                  type: object
                                selector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                storageClassName:
                                  type: string
                                volumeAttributesClassName:
                                  type: string
                                volumeMode:
                                  type: string
                                volumeName:
                                  type: string
                              type: object
                          required:
                          - spec
                          type: object
                      type: object
                    fc:
                      properties:
                        fsType:
                          type: string
                        lun:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        targetWWNs:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        wwids:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    flexVolume:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        options:
                          additionalProperties:
                            type: string
                          type: object
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                      required:
                      - driver
                      type: object
                    flocker:
                      properties:
                        datasetName:
                          type: string
                        datasetUUID:
                          type: string
                      type: object
                    gcePersistentDisk:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        pdName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - pdName
                      type: object
                    gitRepo:
                      properties:
                        directory:
                          type: string
                        repository:
                          type: string
                        revision:
                          type: string
                      required:
                      - repository
                      type: object
                    glusterfs:
                      properties:
                        endpoints:
                          type: string
                        path:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - endpoints
                      - path
                      type: object
                    hostPath:
                      properties:
                        path:
                          type: string
                        type:
                          type: string
                      required:
                      - path
                      type: object
                    image:
                      properties:
                        pullPolicy:
                          type: string
                        reference:
                          type: string
                      type: object
                    iscsi:
                      properties:
                        chapAuthDiscovery:
                          type: boolean
                        chapAuthSession:
                          type: boolean
                        fsType:
                          type: string
                        initiatorName:
                          type: string
                        iqn:
                          type: string
                        iscsiInterface:
                          default: default
                          type: string
                        lun:
                          format: int32
                          type: integer
                        portals:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        targetPortal:
                          type: string
                      required:
                      - iqn
                      - lun
                      - targetPortal
                      type: object
                    name:
                      type: string
                    nfs:
                      properties:
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        server:
                          type: string
                      required:
                      - path
                      - server
                      type: object
                    persistentVolumeClaim:
                      properties:
                        claimName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - claimName
                      type: object
                    photonPersistentDisk:
                      properties:
                        fsType:
                          type: string
                        pdID:
                          type: string
                      required:
                      - pdID
                      type: object
                    portworxVolume:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    projected:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        sources:
                          items:
                            properties:
                              clusterTrustBundle:
                                properties:
                                  labelSelector:
                                    properties:
                                      matchExpressions:
                                        items:
                                          properties:
                                            key:
                                              type: string
                                            operator:
                                              type: string
                                            values:
                                              items:
                                                type: string
                                              type: array
                                              x-kubernetes-list-type: atomic
                                          required:
                                          - key
                                          - operator
                                          type: object
                                        type: array
                                        x-kubernetes-list-type: atomic
                                      matchLabels:
                                        additionalProperties:
                                          type: string
                                        type: object
                                    type: object
                                    x-kubernetes-map-type: atomic
                                  name:
                                    type: string
                                  optional:
                                    type: boolean
                                  path:
                                    type: string
                                  signerName:
                                    type: string
                                required:
                                - path
                                type: object
                              configMap:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              downwardAPI:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        fieldRef:
                                          properties:
                                            apiVersion:
                                              type: string
                                            fieldPath:
                                              type: string
                                          required:
                                          - fieldPath
                                          type: object
                                          x-kubernetes-map-type: atomic
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                        resourceFieldRef:
                                          properties:
                                            containerName:
                                              type: string
                                            divisor:
                                              anyOf:
                                              - type: integer
                                              - type: string
                                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                              x-kubernetes-int-or-string: true
                                            resource:
                                              type: string
                                          required:
                                          - resource
                                          type: object
                                          x-kubernetes-map-type: atomic
                                      required:
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                type: object
                              secret:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              serviceAccountToken:
                                properties:
                                  audience:
                                    type: string
                                  expirationSeconds:
                                    format: int64
                                    type: integer
                                  path:
                                    type: string
                                required:
                                - path
                                type: object
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    quobyte:
                      properties:
                        group:
                          type: string
                        readOnly:
                          type: boolean
                        registry:
                          type: string
                        tenant:
                          type: string
                        user:
                          type: string
                        volume:
                          type: string
                      required:
                      - registry
                      - volume
                      type: object
                    rbd:
                      properties:
                        fsType:
                          type: string
                        image:
                          type: string
                        keyring:
                          default: /etc/ceph/keyring
                          type: string
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        pool:
                          default: rbd
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          default: admin
                          type: string
                      required:
                      - image
                      - monitors
                      type: object
                    scaleIO:
                      properties:
                        fsType:
                          default: xfs
                          type: string
                        gateway:
                          type: string
                        protectionDomain:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        sslEnabled:
                          type: boolean
                        storageMode:
                          default: ThinProvisioned
                          type: string
                        storagePool:
                          type: string
                        system:
                          type: string
                        volumeName:
                          type: string
                      required:
                      - gateway
                      - secretRef
                      - system
                      type: object
                    secret:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        optional:
                          type: boolean
                        secretName:
                          type: string
                      type: object
                    storageos:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeName:
                          type: string
                        volumeNamespace:
                          type: string
                      type: object
                    vsphereVolume:
                      properties:
                        fsType:
                          type: string
                        storagePolicyID:
                          type: string
                        storagePolicyName:
                          type: string
                        volumePath:
                          type: string
                      required:
                      - volumePath
                      type: object
                  required:
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
            required:
            - capabilities
            - endpoint
            type: object
          status:
            properties:
              version:
                type: string
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
status:
  acceptedNames:
    kind: ""
    plural: ""
  conditions: null
  storedVersions: null
---
# Source: opentelemetry-operator/templates/admission-webhooks/operator-webhook.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
  creationTimestamp: null
  labels:
    app.kubernetes.io/name: opentelemetry-operator
  name: targetallocators.opentelemetry.io
spec:
  group: opentelemetry.io
  names:
    kind: TargetAllocator
    listKind: TargetAllocatorList
    plural: targetallocators
    singular: targetallocator
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    - jsonPath: .status.image
      name: Image
      type: string
    - description: Management State
      jsonPath: .spec.managementState
      name: Management
      type: string
    name: v1alpha1
    schema:
      openAPIV3Schema:
        properties:
          apiVersion:
            type: string
          kind:
            type: string
          metadata:
            type: object
          spec:
            properties:
              additionalContainers:
                items:
                  properties:
                    args:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    command:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    env:
                      items:
                        properties:
                          name:
                            type: string
                          value:
                            type: string
                          valueFrom:
                            properties:
                              configMapKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                              secretKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                            type: object
                        required:
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - name
                      x-kubernetes-list-type: map
                    envFrom:
                      items:
                        properties:
                          configMapRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                          prefix:
                            type: string
                          secretRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    image:
                      type: string
                    imagePullPolicy:
                      type: string
                    lifecycle:
                      properties:
                        postStart:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                        preStop:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                      type: object
                    livenessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    name:
                      type: string
                    ports:
                      items:
                        properties:
                          containerPort:
                            format: int32
                            type: integer
                          hostIP:
                            type: string
                          hostPort:
                            format: int32
                            type: integer
                          name:
                            type: string
                          protocol:
                            default: TCP
                            type: string
                        required:
                        - containerPort
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - containerPort
                      - protocol
                      x-kubernetes-list-type: map
                    readinessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    resizePolicy:
                      items:
                        properties:
                          resourceName:
                            type: string
                          restartPolicy:
                            type: string
                        required:
                        - resourceName
                        - restartPolicy
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    resources:
                      properties:
                        claims:
                          items:
                            properties:
                              name:
                                type: string
                              request:
                                type: string
                            required:
                            - name
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - name
                          x-kubernetes-list-type: map
                        limits:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        requests:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                      type: object
                    restartPolicy:
                      type: string
                    securityContext:
                      properties:
                        allowPrivilegeEscalation:
                          type: boolean
                        appArmorProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        capabilities:
                          properties:
                            add:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            drop:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        privileged:
                          type: boolean
                        procMount:
                          type: string
                        readOnlyRootFilesystem:
                          type: boolean
                        runAsGroup:
                          format: int64
                          type: integer
                        runAsNonRoot:
                          type: boolean
                        runAsUser:
                          format: int64
                          type: integer
                        seLinuxOptions:
                          properties:
                            level:
                              type: string
                            role:
                              type: string
                            type:
                              type: string
                            user:
                              type: string
                          type: object
                        seccompProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        windowsOptions:
                          properties:
                            gmsaCredentialSpec:
                              type: string
                            gmsaCredentialSpecName:
                              type: string
                            hostProcess:
                              type: boolean
                            runAsUserName:
                              type: string
                          type: object
                      type: object
                    startupProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    stdin:
                      type: boolean
                    stdinOnce:
                      type: boolean
                    terminationMessagePath:
                      type: string
                    terminationMessagePolicy:
                      type: string
                    tty:
                      type: boolean
                    volumeDevices:
                      items:
                        properties:
                          devicePath:
                            type: string
                          name:
                            type: string
                        required:
                        - devicePath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - devicePath
                      x-kubernetes-list-type: map
                    volumeMounts:
                      items:
                        properties:
                          mountPath:
                            type: string
                          mountPropagation:
                            type: string
                          name:
                            type: string
                          readOnly:
                            type: boolean
                          recursiveReadOnly:
                            type: string
                          subPath:
                            type: string
                          subPathExpr:
                            type: string
                        required:
                        - mountPath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - mountPath
                      x-kubernetes-list-type: map
                    workingDir:
                      type: string
                  required:
                  - name
                  type: object
                type: array
              affinity:
                properties:
                  nodeAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            preference:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            weight:
                              format: int32
                              type: integer
                          required:
                          - preference
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        properties:
                          nodeSelectorTerms:
                            items:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            type: array
                            x-kubernetes-list-type: atomic
                        required:
                        - nodeSelectorTerms
                        type: object
                        x-kubernetes-map-type: atomic
                    type: object
                  podAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  podAntiAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                type: object
              allocationStrategy:
                default: consistent-hashing
                enum:
                - least-weighted
                - consistent-hashing
                - per-node
                type: string
              args:
                additionalProperties:
                  type: string
                type: object
              collectorNotReadyGracePeriod:
                default: 30s
                format: duration
                type: string
              env:
                items:
                  properties:
                    name:
                      type: string
                    value:
                      type: string
                    valueFrom:
                      properties:
                        configMapKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                        fieldRef:
                          properties:
                            apiVersion:
                              type: string
                            fieldPath:
                              type: string
                          required:
                          - fieldPath
                          type: object
                          x-kubernetes-map-type: atomic
                        resourceFieldRef:
                          properties:
                            containerName:
                              type: string
                            divisor:
                              anyOf:
                              - type: integer
                              - type: string
                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                              x-kubernetes-int-or-string: true
                            resource:
                              type: string
                          required:
                          - resource
                          type: object
                          x-kubernetes-map-type: atomic
                        secretKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                      type: object
                  required:
                  - name
                  type: object
                type: array
              envFrom:
                items:
                  properties:
                    configMapRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    prefix:
                      type: string
                    secretRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                  type: object
                type: array
              filterStrategy:
                default: relabel-config
                enum:
                - ""
                - relabel-config
                type: string
              global:
                type: object
              hostNetwork:
                type: boolean
              image:
                type: string
              imagePullPolicy:
                type: string
              initContainers:
                items:
                  properties:
                    args:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    command:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    env:
                      items:
                        properties:
                          name:
                            type: string
                          value:
                            type: string
                          valueFrom:
                            properties:
                              configMapKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                              secretKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                            type: object
                        required:
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - name
                      x-kubernetes-list-type: map
                    envFrom:
                      items:
                        properties:
                          configMapRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                          prefix:
                            type: string
                          secretRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    image:
                      type: string
                    imagePullPolicy:
                      type: string
                    lifecycle:
                      properties:
                        postStart:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                        preStop:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                      type: object
                    livenessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    name:
                      type: string
                    ports:
                      items:
                        properties:
                          containerPort:
                            format: int32
                            type: integer
                          hostIP:
                            type: string
                          hostPort:
                            format: int32
                            type: integer
                          name:
                            type: string
                          protocol:
                            default: TCP
                            type: string
                        required:
                        - containerPort
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - containerPort
                      - protocol
                      x-kubernetes-list-type: map
                    readinessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    resizePolicy:
                      items:
                        properties:
                          resourceName:
                            type: string
                          restartPolicy:
                            type: string
                        required:
                        - resourceName
                        - restartPolicy
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    resources:
                      properties:
                        claims:
                          items:
                            properties:
                              name:
                                type: string
                              request:
                                type: string
                            required:
                            - name
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - name
                          x-kubernetes-list-type: map
                        limits:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        requests:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                      type: object
                    restartPolicy:
                      type: string
                    securityContext:
                      properties:
                        allowPrivilegeEscalation:
                          type: boolean
                        appArmorProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        capabilities:
                          properties:
                            add:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            drop:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        privileged:
                          type: boolean
                        procMount:
                          type: string
                        readOnlyRootFilesystem:
                          type: boolean
                        runAsGroup:
                          format: int64
                          type: integer
                        runAsNonRoot:
                          type: boolean
                        runAsUser:
                          format: int64
                          type: integer
                        seLinuxOptions:
                          properties:
                            level:
                              type: string
                            role:
                              type: string
                            type:
                              type: string
                            user:
                              type: string
                          type: object
                        seccompProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        windowsOptions:
                          properties:
                            gmsaCredentialSpec:
                              type: string
                            gmsaCredentialSpecName:
                              type: string
                            hostProcess:
                              type: boolean
                            runAsUserName:
                              type: string
                          type: object
                      type: object
                    startupProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    stdin:
                      type: boolean
                    stdinOnce:
                      type: boolean
                    terminationMessagePath:
                      type: string
                    terminationMessagePolicy:
                      type: string
                    tty:
                      type: boolean
                    volumeDevices:
                      items:
                        properties:
                          devicePath:
                            type: string
                          name:
                            type: string
                        required:
                        - devicePath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - devicePath
                      x-kubernetes-list-type: map
                    volumeMounts:
                      items:
                        properties:
                          mountPath:
                            type: string
                          mountPropagation:
                            type: string
                          name:
                            type: string
                          readOnly:
                            type: boolean
                          recursiveReadOnly:
                            type: string
                          subPath:
                            type: string
                          subPathExpr:
                            type: string
                        required:
                        - mountPath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - mountPath
                      x-kubernetes-list-type: map
                    workingDir:
                      type: string
                  required:
                  - name
                  type: object
                type: array
              ipFamilies:
                items:
                  type: string
                type: array
              ipFamilyPolicy:
                default: SingleStack
                type: string
              lifecycle:
                properties:
                  postStart:
                    properties:
                      exec:
                        properties:
                          command:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      httpGet:
                        properties:
                          host:
                            type: string
                          httpHeaders:
                            items:
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                              required:
                              - name
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          path:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                          scheme:
                            type: string
                        required:
                        - port
                        type: object
                      sleep:
                        properties:
                          seconds:
                            format: int64
                            type: integer
                        required:
                        - seconds
                        type: object
                      tcpSocket:
                        properties:
                          host:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                        required:
                        - port
                        type: object
                    type: object
                  preStop:
                    properties:
                      exec:
                        properties:
                          command:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      httpGet:
                        properties:
                          host:
                            type: string
                          httpHeaders:
                            items:
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                              required:
                              - name
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          path:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                          scheme:
                            type: string
                        required:
                        - port
                        type: object
                      sleep:
                        properties:
                          seconds:
                            format: int64
                            type: integer
                        required:
                        - seconds
                        type: object
                      tcpSocket:
                        properties:
                          host:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                        required:
                        - port
                        type: object
                    type: object
                type: object
              managementState:
                default: managed
                enum:
                - managed
                - unmanaged
                type: string
              networkPolicy:
                properties:
                  enabled:
                    type: boolean
                type: object
              nodeSelector:
                additionalProperties:
                  type: string
                type: object
              observability:
                properties:
                  metrics:
                    properties:
                      disablePrometheusAnnotations:
                        type: boolean
                      enableMetrics:
                        type: boolean
                      extraLabels:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                type: object
              podAnnotations:
                additionalProperties:
                  type: string
                type: object
              podDisruptionBudget:
                properties:
                  maxUnavailable:
                    anyOf:
                    - type: integer
                    - type: string
                    x-kubernetes-int-or-string: true
                  minAvailable:
                    anyOf:
                    - type: integer
                    - type: string
                    x-kubernetes-int-or-string: true
                type: object
              podDnsConfig:
                properties:
                  nameservers:
                    items:
                      type: string
                    type: array
                    x-kubernetes-list-type: atomic
                  options:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  searches:
                    items:
                      type: string
                    type: array
                    x-kubernetes-list-type: atomic
                type: object
              podSecurityContext:
                properties:
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  fsGroup:
                    format: int64
                    type: integer
                  fsGroupChangePolicy:
                    type: string
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxChangePolicy:
                    type: string
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  supplementalGroups:
                    items:
                      format: int64
                      type: integer
                    type: array
                    x-kubernetes-list-type: atomic
                  supplementalGroupsPolicy:
                    type: string
                  sysctls:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      required:
                      - name
                      - value
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              ports:
                items:
                  properties:
                    appProtocol:
                      type: string
                    hostPort:
                      format: int32
                      type: integer
                    name:
                      type: string
                    nodePort:
                      format: int32
                      type: integer
                    port:
                      format: int32
                      type: integer
                    protocol:
                      default: TCP
                      type: string
                    targetPort:
                      anyOf:
                      - type: integer
                      - type: string
                      x-kubernetes-int-or-string: true
                  required:
                  - port
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              priorityClassName:
                type: string
              prometheusCR:
                properties:
                  allowNamespaces:
                    items:
                      type: string
                    type: array
                  denyNamespaces:
                    items:
                      type: string
                    type: array
                  enabled:
                    type: boolean
                  podMonitorSelector:
                    properties:
                      matchExpressions:
                        items:
                          properties:
                            key:
                              type: string
                            operator:
                              type: string
                            values:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          required:
                          - key
                          - operator
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      matchLabels:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                    x-kubernetes-map-type: atomic
                  probeSelector:
                    properties:
                      matchExpressions:
                        items:
                          properties:
                            key:
                              type: string
                            operator:
                              type: string
                            values:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          required:
                          - key
                          - operator
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      matchLabels:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                    x-kubernetes-map-type: atomic
                  scrapeConfigSelector:
                    properties:
                      matchExpressions:
                        items:
                          properties:
                            key:
                              type: string
                            operator:
                              type: string
                            values:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          required:
                          - key
                          - operator
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      matchLabels:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                    x-kubernetes-map-type: atomic
                  scrapeInterval:
                    default: 30s
                    format: duration
                    type: string
                  serviceMonitorSelector:
                    properties:
                      matchExpressions:
                        items:
                          properties:
                            key:
                              type: string
                            operator:
                              type: string
                            values:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          required:
                          - key
                          - operator
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      matchLabels:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                    x-kubernetes-map-type: atomic
                type: object
              replicas:
                default: 1
                format: int32
                type: integer
              resources:
                properties:
                  claims:
                    items:
                      properties:
                        name:
                          type: string
                        request:
                          type: string
                      required:
                      - name
                      type: object
                    type: array
                    x-kubernetes-list-map-keys:
                    - name
                    x-kubernetes-list-type: map
                  limits:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                  requests:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                type: object
              scrapeConfigs:
                items:
                  type: object
                type: array
                x-kubernetes-list-type: atomic
                x-kubernetes-preserve-unknown-fields: true
              securityContext:
                properties:
                  allowPrivilegeEscalation:
                    type: boolean
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  capabilities:
                    properties:
                      add:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                      drop:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  privileged:
                    type: boolean
                  procMount:
                    type: string
                  readOnlyRootFilesystem:
                    type: boolean
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              serviceAccount:
                type: string
              shareProcessNamespace:
                type: boolean
              terminationGracePeriodSeconds:
                format: int64
                type: integer
              tolerations:
                items:
                  properties:
                    effect:
                      type: string
                    key:
                      type: string
                    operator:
                      type: string
                    tolerationSeconds:
                      format: int64
                      type: integer
                    value:
                      type: string
                  type: object
                type: array
              topologySpreadConstraints:
                items:
                  properties:
                    labelSelector:
                      properties:
                        matchExpressions:
                          items:
                            properties:
                              key:
                                type: string
                              operator:
                                type: string
                              values:
                                items:
                                  type: string
                                type: array
                                x-kubernetes-list-type: atomic
                            required:
                            - key
                            - operator
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        matchLabels:
                          additionalProperties:
                            type: string
                          type: object
                      type: object
                      x-kubernetes-map-type: atomic
                    matchLabelKeys:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    maxSkew:
                      format: int32
                      type: integer
                    minDomains:
                      format: int32
                      type: integer
                    nodeAffinityPolicy:
                      type: string
                    nodeTaintsPolicy:
                      type: string
                    topologyKey:
                      type: string
                    whenUnsatisfiable:
                      type: string
                  required:
                  - maxSkew
                  - topologyKey
                  - whenUnsatisfiable
                  type: object
                type: array
              trafficDistribution:
                type: string
              volumeMounts:
                items:
                  properties:
                    mountPath:
                      type: string
                    mountPropagation:
                      type: string
                    name:
                      type: string
                    readOnly:
                      type: boolean
                    recursiveReadOnly:
                      type: string
                    subPath:
                      type: string
                    subPathExpr:
                      type: string
                  required:
                  - mountPath
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              volumes:
                items:
                  properties:
                    awsElasticBlockStore:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    azureDisk:
                      properties:
                        cachingMode:
                          type: string
                        diskName:
                          type: string
                        diskURI:
                          type: string
                        fsType:
                          default: ext4
                          type: string
                        kind:
                          type: string
                        readOnly:
                          default: false
                          type: boolean
                      required:
                      - diskName
                      - diskURI
                      type: object
                    azureFile:
                      properties:
                        readOnly:
                          type: boolean
                        secretName:
                          type: string
                        shareName:
                          type: string
                      required:
                      - secretName
                      - shareName
                      type: object
                    cephfs:
                      properties:
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        secretFile:
                          type: string
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          type: string
                      required:
                      - monitors
                      type: object
                    cinder:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    configMap:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    csi:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        nodePublishSecretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        readOnly:
                          type: boolean
                        volumeAttributes:
                          additionalProperties:
                            type: string
                          type: object
                      required:
                      - driver
                      type: object
                    downwardAPI:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                            required:
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    emptyDir:
                      properties:
                        medium:
                          type: string
                        sizeLimit:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                      type: object
                    ephemeral:
                      properties:
                        volumeClaimTemplate:
                          properties:
                            metadata:
                              properties:
                                annotations:
                                  additionalProperties:
                                    type: string
                                  type: object
                                finalizers:
                                  items:
                                    type: string
                                  type: array
                                labels:
                                  additionalProperties:
                                    type: string
                                  type: object
                                name:
                                  type: string
                                namespace:
                                  type: string
                              type: object
                            spec:
                              properties:
                                accessModes:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                dataSource:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                  x-kubernetes-map-type: atomic
                                dataSourceRef:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                    namespace:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                resources:
                                  properties:
                                    limits:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                    requests:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                  type: object
                                selector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                storageClassName:
                                  type: string
                                volumeAttributesClassName:
                                  type: string
                                volumeMode:
                                  type: string
                                volumeName:
                                  type: string
                              type: object
                          required:
                          - spec
                          type: object
                      type: object
                    fc:
                      properties:
                        fsType:
                          type: string
                        lun:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        targetWWNs:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        wwids:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    flexVolume:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        options:
                          additionalProperties:
                            type: string
                          type: object
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                      required:
                      - driver
                      type: object
                    flocker:
                      properties:
                        datasetName:
                          type: string
                        datasetUUID:
                          type: string
                      type: object
                    gcePersistentDisk:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        pdName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - pdName
                      type: object
                    gitRepo:
                      properties:
                        directory:
                          type: string
                        repository:
                          type: string
                        revision:
                          type: string
                      required:
                      - repository
                      type: object
                    glusterfs:
                      properties:
                        endpoints:
                          type: string
                        path:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - endpoints
                      - path
                      type: object
                    hostPath:
                      properties:
                        path:
                          type: string
                        type:
                          type: string
                      required:
                      - path
                      type: object
                    image:
                      properties:
                        pullPolicy:
                          type: string
                        reference:
                          type: string
                      type: object
                    iscsi:
                      properties:
                        chapAuthDiscovery:
                          type: boolean
                        chapAuthSession:
                          type: boolean
                        fsType:
                          type: string
                        initiatorName:
                          type: string
                        iqn:
                          type: string
                        iscsiInterface:
                          default: default
                          type: string
                        lun:
                          format: int32
                          type: integer
                        portals:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        targetPortal:
                          type: string
                      required:
                      - iqn
                      - lun
                      - targetPortal
                      type: object
                    name:
                      type: string
                    nfs:
                      properties:
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        server:
                          type: string
                      required:
                      - path
                      - server
                      type: object
                    persistentVolumeClaim:
                      properties:
                        claimName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - claimName
                      type: object
                    photonPersistentDisk:
                      properties:
                        fsType:
                          type: string
                        pdID:
                          type: string
                      required:
                      - pdID
                      type: object
                    portworxVolume:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    projected:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        sources:
                          items:
                            properties:
                              clusterTrustBundle:
                                properties:
                                  labelSelector:
                                    properties:
                                      matchExpressions:
                                        items:
                                          properties:
                                            key:
                                              type: string
                                            operator:
                                              type: string
                                            values:
                                              items:
                                                type: string
                                              type: array
                                              x-kubernetes-list-type: atomic
                                          required:
                                          - key
                                          - operator
                                          type: object
                                        type: array
                                        x-kubernetes-list-type: atomic
                                      matchLabels:
                                        additionalProperties:
                                          type: string
                                        type: object
                                    type: object
                                    x-kubernetes-map-type: atomic
                                  name:
                                    type: string
                                  optional:
                                    type: boolean
                                  path:
                                    type: string
                                  signerName:
                                    type: string
                                required:
                                - path
                                type: object
                              configMap:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              downwardAPI:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        fieldRef:
                                          properties:
                                            apiVersion:
                                              type: string
                                            fieldPath:
                                              type: string
                                          required:
                                          - fieldPath
                                          type: object
                                          x-kubernetes-map-type: atomic
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                        resourceFieldRef:
                                          properties:
                                            containerName:
                                              type: string
                                            divisor:
                                              anyOf:
                                              - type: integer
                                              - type: string
                                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                              x-kubernetes-int-or-string: true
                                            resource:
                                              type: string
                                          required:
                                          - resource
                                          type: object
                                          x-kubernetes-map-type: atomic
                                      required:
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                type: object
                              secret:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              serviceAccountToken:
                                properties:
                                  audience:
                                    type: string
                                  expirationSeconds:
                                    format: int64
                                    type: integer
                                  path:
                                    type: string
                                required:
                                - path
                                type: object
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    quobyte:
                      properties:
                        group:
                          type: string
                        readOnly:
                          type: boolean
                        registry:
                          type: string
                        tenant:
                          type: string
                        user:
                          type: string
                        volume:
                          type: string
                      required:
                      - registry
                      - volume
                      type: object
                    rbd:
                      properties:
                        fsType:
                          type: string
                        image:
                          type: string
                        keyring:
                          default: /etc/ceph/keyring
                          type: string
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        pool:
                          default: rbd
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          default: admin
                          type: string
                      required:
                      - image
                      - monitors
                      type: object
                    scaleIO:
                      properties:
                        fsType:
                          default: xfs
                          type: string
                        gateway:
                          type: string
                        protectionDomain:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        sslEnabled:
                          type: boolean
                        storageMode:
                          default: ThinProvisioned
                          type: string
                        storagePool:
                          type: string
                        system:
                          type: string
                        volumeName:
                          type: string
                      required:
                      - gateway
                      - secretRef
                      - system
                      type: object
                    secret:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        optional:
                          type: boolean
                        secretName:
                          type: string
                      type: object
                    storageos:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeName:
                          type: string
                        volumeNamespace:
                          type: string
                      type: object
                    vsphereVolume:
                      properties:
                        fsType:
                          type: string
                        storagePolicyID:
                          type: string
                        storagePolicyName:
                          type: string
                        volumePath:
                          type: string
                      required:
                      - volumePath
                      type: object
                  required:
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
            type: object
          status:
            properties:
              image:
                type: string
              version:
                type: string
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
status:
  acceptedNames:
    kind: ""
    plural: ""
  conditions: null
  storedVersions: null
---
# Source: opentelemetry-operator/templates/admission-webhooks/operator-webhook.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    cert-manager.io/inject-ca-from: cpd-operators/otel-operator-opentelemetry-operator-serving-cert
    controller-gen.kubebuilder.io/version: v0.19.0
  creationTimestamp: null
  labels:
    app.kubernetes.io/name: opentelemetry-operator
  name: opentelemetrycollectors.opentelemetry.io
spec:
  conversion:
    strategy: Webhook
    webhook:
      clientConfig:
        service:
          name: otel-operator-opentelemetry-operator-webhook
          namespace: cpd-operators
          path: /convert
          port: 443

      conversionReviewVersions:
      - v1alpha1
      - v1beta1
  group: opentelemetry.io
  names:
    kind: OpenTelemetryCollector
    listKind: OpenTelemetryCollectorList
    plural: opentelemetrycollectors
    shortNames:
    - otelcol
    - otelcols
    singular: opentelemetrycollector
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - description: Deployment Mode
      jsonPath: .spec.mode
      name: Mode
      type: string
    - description: OpenTelemetry Version
      jsonPath: .status.version
      name: Version
      type: string
    - jsonPath: .status.scale.statusReplicas
      name: Ready
      type: string
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    - jsonPath: .status.image
      name: Image
      type: string
    - description: Management State
      jsonPath: .spec.managementState
      name: Management
      type: string
    deprecated: true
    deprecationWarning: OpenTelemetryCollector v1alpha1 is deprecated. Migrate to
      v1beta1.
    name: v1alpha1
    schema:
      openAPIV3Schema:
        properties:
          apiVersion:
            type: string
          kind:
            type: string
          metadata:
            type: object
          spec:
            properties:
              additionalContainers:
                items:
                  properties:
                    args:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    command:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    env:
                      items:
                        properties:
                          name:
                            type: string
                          value:
                            type: string
                          valueFrom:
                            properties:
                              configMapKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                              secretKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                            type: object
                        required:
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - name
                      x-kubernetes-list-type: map
                    envFrom:
                      items:
                        properties:
                          configMapRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                          prefix:
                            type: string
                          secretRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    image:
                      type: string
                    imagePullPolicy:
                      type: string
                    lifecycle:
                      properties:
                        postStart:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                        preStop:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                      type: object
                    livenessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    name:
                      type: string
                    ports:
                      items:
                        properties:
                          containerPort:
                            format: int32
                            type: integer
                          hostIP:
                            type: string
                          hostPort:
                            format: int32
                            type: integer
                          name:
                            type: string
                          protocol:
                            default: TCP
                            type: string
                        required:
                        - containerPort
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - containerPort
                      - protocol
                      x-kubernetes-list-type: map
                    readinessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    resizePolicy:
                      items:
                        properties:
                          resourceName:
                            type: string
                          restartPolicy:
                            type: string
                        required:
                        - resourceName
                        - restartPolicy
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    resources:
                      properties:
                        claims:
                          items:
                            properties:
                              name:
                                type: string
                              request:
                                type: string
                            required:
                            - name
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - name
                          x-kubernetes-list-type: map
                        limits:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        requests:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                      type: object
                    restartPolicy:
                      type: string
                    securityContext:
                      properties:
                        allowPrivilegeEscalation:
                          type: boolean
                        appArmorProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        capabilities:
                          properties:
                            add:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            drop:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        privileged:
                          type: boolean
                        procMount:
                          type: string
                        readOnlyRootFilesystem:
                          type: boolean
                        runAsGroup:
                          format: int64
                          type: integer
                        runAsNonRoot:
                          type: boolean
                        runAsUser:
                          format: int64
                          type: integer
                        seLinuxOptions:
                          properties:
                            level:
                              type: string
                            role:
                              type: string
                            type:
                              type: string
                            user:
                              type: string
                          type: object
                        seccompProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        windowsOptions:
                          properties:
                            gmsaCredentialSpec:
                              type: string
                            gmsaCredentialSpecName:
                              type: string
                            hostProcess:
                              type: boolean
                            runAsUserName:
                              type: string
                          type: object
                      type: object
                    startupProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    stdin:
                      type: boolean
                    stdinOnce:
                      type: boolean
                    terminationMessagePath:
                      type: string
                    terminationMessagePolicy:
                      type: string
                    tty:
                      type: boolean
                    volumeDevices:
                      items:
                        properties:
                          devicePath:
                            type: string
                          name:
                            type: string
                        required:
                        - devicePath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - devicePath
                      x-kubernetes-list-type: map
                    volumeMounts:
                      items:
                        properties:
                          mountPath:
                            type: string
                          mountPropagation:
                            type: string
                          name:
                            type: string
                          readOnly:
                            type: boolean
                          recursiveReadOnly:
                            type: string
                          subPath:
                            type: string
                          subPathExpr:
                            type: string
                        required:
                        - mountPath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - mountPath
                      x-kubernetes-list-type: map
                    workingDir:
                      type: string
                  required:
                  - name
                  type: object
                type: array
              affinity:
                properties:
                  nodeAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            preference:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            weight:
                              format: int32
                              type: integer
                          required:
                          - preference
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        properties:
                          nodeSelectorTerms:
                            items:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            type: array
                            x-kubernetes-list-type: atomic
                        required:
                        - nodeSelectorTerms
                        type: object
                        x-kubernetes-map-type: atomic
                    type: object
                  podAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  podAntiAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                type: object
              args:
                additionalProperties:
                  type: string
                type: object
              autoscaler:
                properties:
                  behavior:
                    properties:
                      scaleDown:
                        properties:
                          policies:
                            items:
                              properties:
                                periodSeconds:
                                  format: int32
                                  type: integer
                                type:
                                  type: string
                                value:
                                  format: int32
                                  type: integer
                              required:
                              - periodSeconds
                              - type
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          selectPolicy:
                            type: string
                          stabilizationWindowSeconds:
                            format: int32
                            type: integer
                        type: object
                      scaleUp:
                        properties:
                          policies:
                            items:
                              properties:
                                periodSeconds:
                                  format: int32
                                  type: integer
                                type:
                                  type: string
                                value:
                                  format: int32
                                  type: integer
                              required:
                              - periodSeconds
                              - type
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          selectPolicy:
                            type: string
                          stabilizationWindowSeconds:
                            format: int32
                            type: integer
                        type: object
                    type: object
                  maxReplicas:
                    format: int32
                    type: integer
                  metrics:
                    items:
                      properties:
                        pods:
                          properties:
                            metric:
                              properties:
                                name:
                                  type: string
                                selector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                              required:
                              - name
                              type: object
                            target:
                              properties:
                                averageUtilization:
                                  format: int32
                                  type: integer
                                averageValue:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type:
                                  type: string
                                value:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                              required:
                              - type
                              type: object
                          required:
                          - metric
                          - target
                          type: object
                        type:
                          type: string
                      required:
                      - type
                      type: object
                    type: array
                  minReplicas:
                    format: int32
                    type: integer
                  targetCPUUtilization:
                    format: int32
                    type: integer
                  targetMemoryUtilization:
                    format: int32
                    type: integer
                type: object
              config:
                type: string
              configmaps:
                items:
                  properties:
                    mountpath:
                      type: string
                    name:
                      type: string
                  required:
                  - mountpath
                  - name
                  type: object
                type: array
              deploymentUpdateStrategy:
                properties:
                  rollingUpdate:
                    properties:
                      maxSurge:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                      maxUnavailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                    type: object
                  type:
                    type: string
                type: object
              env:
                items:
                  properties:
                    name:
                      type: string
                    value:
                      type: string
                    valueFrom:
                      properties:
                        configMapKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                        fieldRef:
                          properties:
                            apiVersion:
                              type: string
                            fieldPath:
                              type: string
                          required:
                          - fieldPath
                          type: object
                          x-kubernetes-map-type: atomic
                        resourceFieldRef:
                          properties:
                            containerName:
                              type: string
                            divisor:
                              anyOf:
                              - type: integer
                              - type: string
                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                              x-kubernetes-int-or-string: true
                            resource:
                              type: string
                          required:
                          - resource
                          type: object
                          x-kubernetes-map-type: atomic
                        secretKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                      type: object
                  required:
                  - name
                  type: object
                type: array
              envFrom:
                items:
                  properties:
                    configMapRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    prefix:
                      type: string
                    secretRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                  type: object
                type: array
              hostNetwork:
                type: boolean
              image:
                type: string
              imagePullPolicy:
                type: string
              ingress:
                properties:
                  annotations:
                    additionalProperties:
                      type: string
                    type: object
                  hostname:
                    type: string
                  ingressClassName:
                    type: string
                  route:
                    properties:
                      termination:
                        enum:
                        - insecure
                        - edge
                        - passthrough
                        - reencrypt
                        type: string
                    type: object
                  ruleType:
                    enum:
                    - path
                    - subdomain
                    type: string
                  tls:
                    items:
                      properties:
                        hosts:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        secretName:
                          type: string
                      type: object
                    type: array
                  type:
                    enum:
                    - ingress
                    - route
                    type: string
                type: object
              initContainers:
                items:
                  properties:
                    args:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    command:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    env:
                      items:
                        properties:
                          name:
                            type: string
                          value:
                            type: string
                          valueFrom:
                            properties:
                              configMapKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                              secretKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                            type: object
                        required:
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - name
                      x-kubernetes-list-type: map
                    envFrom:
                      items:
                        properties:
                          configMapRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                          prefix:
                            type: string
                          secretRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    image:
                      type: string
                    imagePullPolicy:
                      type: string
                    lifecycle:
                      properties:
                        postStart:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                        preStop:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                      type: object
                    livenessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    name:
                      type: string
                    ports:
                      items:
                        properties:
                          containerPort:
                            format: int32
                            type: integer
                          hostIP:
                            type: string
                          hostPort:
                            format: int32
                            type: integer
                          name:
                            type: string
                          protocol:
                            default: TCP
                            type: string
                        required:
                        - containerPort
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - containerPort
                      - protocol
                      x-kubernetes-list-type: map
                    readinessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    resizePolicy:
                      items:
                        properties:
                          resourceName:
                            type: string
                          restartPolicy:
                            type: string
                        required:
                        - resourceName
                        - restartPolicy
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    resources:
                      properties:
                        claims:
                          items:
                            properties:
                              name:
                                type: string
                              request:
                                type: string
                            required:
                            - name
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - name
                          x-kubernetes-list-type: map
                        limits:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        requests:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                      type: object
                    restartPolicy:
                      type: string
                    securityContext:
                      properties:
                        allowPrivilegeEscalation:
                          type: boolean
                        appArmorProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        capabilities:
                          properties:
                            add:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            drop:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        privileged:
                          type: boolean
                        procMount:
                          type: string
                        readOnlyRootFilesystem:
                          type: boolean
                        runAsGroup:
                          format: int64
                          type: integer
                        runAsNonRoot:
                          type: boolean
                        runAsUser:
                          format: int64
                          type: integer
                        seLinuxOptions:
                          properties:
                            level:
                              type: string
                            role:
                              type: string
                            type:
                              type: string
                            user:
                              type: string
                          type: object
                        seccompProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        windowsOptions:
                          properties:
                            gmsaCredentialSpec:
                              type: string
                            gmsaCredentialSpecName:
                              type: string
                            hostProcess:
                              type: boolean
                            runAsUserName:
                              type: string
                          type: object
                      type: object
                    startupProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    stdin:
                      type: boolean
                    stdinOnce:
                      type: boolean
                    terminationMessagePath:
                      type: string
                    terminationMessagePolicy:
                      type: string
                    tty:
                      type: boolean
                    volumeDevices:
                      items:
                        properties:
                          devicePath:
                            type: string
                          name:
                            type: string
                        required:
                        - devicePath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - devicePath
                      x-kubernetes-list-type: map
                    volumeMounts:
                      items:
                        properties:
                          mountPath:
                            type: string
                          mountPropagation:
                            type: string
                          name:
                            type: string
                          readOnly:
                            type: boolean
                          recursiveReadOnly:
                            type: string
                          subPath:
                            type: string
                          subPathExpr:
                            type: string
                        required:
                        - mountPath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - mountPath
                      x-kubernetes-list-type: map
                    workingDir:
                      type: string
                  required:
                  - name
                  type: object
                type: array
              lifecycle:
                properties:
                  postStart:
                    properties:
                      exec:
                        properties:
                          command:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      httpGet:
                        properties:
                          host:
                            type: string
                          httpHeaders:
                            items:
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                              required:
                              - name
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          path:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                          scheme:
                            type: string
                        required:
                        - port
                        type: object
                      sleep:
                        properties:
                          seconds:
                            format: int64
                            type: integer
                        required:
                        - seconds
                        type: object
                      tcpSocket:
                        properties:
                          host:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                        required:
                        - port
                        type: object
                    type: object
                  preStop:
                    properties:
                      exec:
                        properties:
                          command:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      httpGet:
                        properties:
                          host:
                            type: string
                          httpHeaders:
                            items:
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                              required:
                              - name
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          path:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                          scheme:
                            type: string
                        required:
                        - port
                        type: object
                      sleep:
                        properties:
                          seconds:
                            format: int64
                            type: integer
                        required:
                        - seconds
                        type: object
                      tcpSocket:
                        properties:
                          host:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                        required:
                        - port
                        type: object
                    type: object
                type: object
              livenessProbe:
                properties:
                  failureThreshold:
                    format: int32
                    type: integer
                  initialDelaySeconds:
                    format: int32
                    type: integer
                  periodSeconds:
                    format: int32
                    type: integer
                  successThreshold:
                    format: int32
                    type: integer
                  terminationGracePeriodSeconds:
                    format: int64
                    type: integer
                  timeoutSeconds:
                    format: int32
                    type: integer
                type: object
              managementState:
                default: managed
                enum:
                - managed
                - unmanaged
                type: string
              maxReplicas:
                format: int32
                type: integer
              minReplicas:
                format: int32
                type: integer
              mode:
                enum:
                - daemonset
                - deployment
                - sidecar
                - statefulset
                type: string
              nodeSelector:
                additionalProperties:
                  type: string
                type: object
              observability:
                properties:
                  metrics:
                    properties:
                      DisablePrometheusAnnotations:
                        type: boolean
                      enableMetrics:
                        type: boolean
                    type: object
                type: object
              podAnnotations:
                additionalProperties:
                  type: string
                type: object
              podDisruptionBudget:
                properties:
                  maxUnavailable:
                    anyOf:
                    - type: integer
                    - type: string
                    x-kubernetes-int-or-string: true
                  minAvailable:
                    anyOf:
                    - type: integer
                    - type: string
                    x-kubernetes-int-or-string: true
                type: object
              podSecurityContext:
                properties:
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  fsGroup:
                    format: int64
                    type: integer
                  fsGroupChangePolicy:
                    type: string
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxChangePolicy:
                    type: string
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  supplementalGroups:
                    items:
                      format: int64
                      type: integer
                    type: array
                    x-kubernetes-list-type: atomic
                  supplementalGroupsPolicy:
                    type: string
                  sysctls:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      required:
                      - name
                      - value
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              ports:
                items:
                  properties:
                    appProtocol:
                      type: string
                    hostPort:
                      format: int32
                      type: integer
                    name:
                      type: string
                    nodePort:
                      format: int32
                      type: integer
                    port:
                      format: int32
                      type: integer
                    protocol:
                      default: TCP
                      type: string
                    targetPort:
                      anyOf:
                      - type: integer
                      - type: string
                      x-kubernetes-int-or-string: true
                  required:
                  - port
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              priorityClassName:
                type: string
              replicas:
                default: 1
                format: int32
                type: integer
              resources:
                properties:
                  claims:
                    items:
                      properties:
                        name:
                          type: string
                        request:
                          type: string
                      required:
                      - name
                      type: object
                    type: array
                    x-kubernetes-list-map-keys:
                    - name
                    x-kubernetes-list-type: map
                  limits:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                  requests:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                type: object
              securityContext:
                properties:
                  allowPrivilegeEscalation:
                    type: boolean
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  capabilities:
                    properties:
                      add:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                      drop:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  privileged:
                    type: boolean
                  procMount:
                    type: string
                  readOnlyRootFilesystem:
                    type: boolean
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              serviceAccount:
                type: string
              serviceName:
                type: string
              shareProcessNamespace:
                type: boolean
              targetAllocator:
                properties:
                  affinity:
                    properties:
                      nodeAffinity:
                        properties:
                          preferredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                preference:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchFields:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  type: object
                                  x-kubernetes-map-type: atomic
                                weight:
                                  format: int32
                                  type: integer
                              required:
                              - preference
                              - weight
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          requiredDuringSchedulingIgnoredDuringExecution:
                            properties:
                              nodeSelectorTerms:
                                items:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchFields:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  type: object
                                  x-kubernetes-map-type: atomic
                                type: array
                                x-kubernetes-list-type: atomic
                            required:
                            - nodeSelectorTerms
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      podAffinity:
                        properties:
                          preferredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                podAffinityTerm:
                                  properties:
                                    labelSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    matchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    mismatchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    namespaceSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    namespaces:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    topologyKey:
                                      type: string
                                  required:
                                  - topologyKey
                                  type: object
                                weight:
                                  format: int32
                                  type: integer
                              required:
                              - podAffinityTerm
                              - weight
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          requiredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      podAntiAffinity:
                        properties:
                          preferredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                podAffinityTerm:
                                  properties:
                                    labelSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    matchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    mismatchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    namespaceSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    namespaces:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    topologyKey:
                                      type: string
                                  required:
                                  - topologyKey
                                  type: object
                                weight:
                                  format: int32
                                  type: integer
                              required:
                              - podAffinityTerm
                              - weight
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          requiredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                    type: object
                  allocationStrategy:
                    default: consistent-hashing
                    enum:
                    - least-weighted
                    - consistent-hashing
                    - per-node
                    type: string
                  enabled:
                    type: boolean
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  filterStrategy:
                    default: relabel-config
                    type: string
                  image:
                    type: string
                  nodeSelector:
                    additionalProperties:
                      type: string
                    type: object
                  observability:
                    properties:
                      metrics:
                        properties:
                          DisablePrometheusAnnotations:
                            type: boolean
                          enableMetrics:
                            type: boolean
                        type: object
                    type: object
                  podDisruptionBudget:
                    properties:
                      maxUnavailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                      minAvailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                    type: object
                  podSecurityContext:
                    properties:
                      appArmorProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      fsGroup:
                        format: int64
                        type: integer
                      fsGroupChangePolicy:
                        type: string
                      runAsGroup:
                        format: int64
                        type: integer
                      runAsNonRoot:
                        type: boolean
                      runAsUser:
                        format: int64
                        type: integer
                      seLinuxChangePolicy:
                        type: string
                      seLinuxOptions:
                        properties:
                          level:
                            type: string
                          role:
                            type: string
                          type:
                            type: string
                          user:
                            type: string
                        type: object
                      seccompProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      supplementalGroups:
                        items:
                          format: int64
                          type: integer
                        type: array
                        x-kubernetes-list-type: atomic
                      supplementalGroupsPolicy:
                        type: string
                      sysctls:
                        items:
                          properties:
                            name:
                              type: string
                            value:
                              type: string
                          required:
                          - name
                          - value
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      windowsOptions:
                        properties:
                          gmsaCredentialSpec:
                            type: string
                          gmsaCredentialSpecName:
                            type: string
                          hostProcess:
                            type: boolean
                          runAsUserName:
                            type: string
                        type: object
                    type: object
                  prometheusCR:
                    properties:
                      enabled:
                        type: boolean
                      podMonitorSelector:
                        additionalProperties:
                          type: string
                        type: object
                      scrapeInterval:
                        default: 30s
                        format: duration
                        type: string
                      serviceMonitorSelector:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                  replicas:
                    format: int32
                    type: integer
                  resources:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  securityContext:
                    properties:
                      allowPrivilegeEscalation:
                        type: boolean
                      appArmorProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      capabilities:
                        properties:
                          add:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          drop:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      privileged:
                        type: boolean
                      procMount:
                        type: string
                      readOnlyRootFilesystem:
                        type: boolean
                      runAsGroup:
                        format: int64
                        type: integer
                      runAsNonRoot:
                        type: boolean
                      runAsUser:
                        format: int64
                        type: integer
                      seLinuxOptions:
                        properties:
                          level:
                            type: string
                          role:
                            type: string
                          type:
                            type: string
                          user:
                            type: string
                        type: object
                      seccompProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      windowsOptions:
                        properties:
                          gmsaCredentialSpec:
                            type: string
                          gmsaCredentialSpecName:
                            type: string
                          hostProcess:
                            type: boolean
                          runAsUserName:
                            type: string
                        type: object
                    type: object
                  serviceAccount:
                    type: string
                  tolerations:
                    items:
                      properties:
                        effect:
                          type: string
                        key:
                          type: string
                        operator:
                          type: string
                        tolerationSeconds:
                          format: int64
                          type: integer
                        value:
                          type: string
                      type: object
                    type: array
                  topologySpreadConstraints:
                    items:
                      properties:
                        labelSelector:
                          properties:
                            matchExpressions:
                              items:
                                properties:
                                  key:
                                    type: string
                                  operator:
                                    type: string
                                  values:
                                    items:
                                      type: string
                                    type: array
                                    x-kubernetes-list-type: atomic
                                required:
                                - key
                                - operator
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            matchLabels:
                              additionalProperties:
                                type: string
                              type: object
                          type: object
                          x-kubernetes-map-type: atomic
                        matchLabelKeys:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        maxSkew:
                          format: int32
                          type: integer
                        minDomains:
                          format: int32
                          type: integer
                        nodeAffinityPolicy:
                          type: string
                        nodeTaintsPolicy:
                          type: string
                        topologyKey:
                          type: string
                        whenUnsatisfiable:
                          type: string
                      required:
                      - maxSkew
                      - topologyKey
                      - whenUnsatisfiable
                      type: object
                    type: array
                type: object
              terminationGracePeriodSeconds:
                format: int64
                type: integer
              tolerations:
                items:
                  properties:
                    effect:
                      type: string
                    key:
                      type: string
                    operator:
                      type: string
                    tolerationSeconds:
                      format: int64
                      type: integer
                    value:
                      type: string
                  type: object
                type: array
              topologySpreadConstraints:
                items:
                  properties:
                    labelSelector:
                      properties:
                        matchExpressions:
                          items:
                            properties:
                              key:
                                type: string
                              operator:
                                type: string
                              values:
                                items:
                                  type: string
                                type: array
                                x-kubernetes-list-type: atomic
                            required:
                            - key
                            - operator
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        matchLabels:
                          additionalProperties:
                            type: string
                          type: object
                      type: object
                      x-kubernetes-map-type: atomic
                    matchLabelKeys:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    maxSkew:
                      format: int32
                      type: integer
                    minDomains:
                      format: int32
                      type: integer
                    nodeAffinityPolicy:
                      type: string
                    nodeTaintsPolicy:
                      type: string
                    topologyKey:
                      type: string
                    whenUnsatisfiable:
                      type: string
                  required:
                  - maxSkew
                  - topologyKey
                  - whenUnsatisfiable
                  type: object
                type: array
              trafficDistribution:
                type: string
              updateStrategy:
                properties:
                  rollingUpdate:
                    properties:
                      maxSurge:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                      maxUnavailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                    type: object
                  type:
                    type: string
                type: object
              upgradeStrategy:
                enum:
                - automatic
                - none
                type: string
              volumeClaimTemplates:
                items:
                  properties:
                    apiVersion:
                      type: string
                    kind:
                      type: string
                    metadata:
                      properties:
                        annotations:
                          additionalProperties:
                            type: string
                          type: object
                        finalizers:
                          items:
                            type: string
                          type: array
                        labels:
                          additionalProperties:
                            type: string
                          type: object
                        name:
                          type: string
                        namespace:
                          type: string
                      type: object
                    spec:
                      properties:
                        accessModes:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        dataSource:
                          properties:
                            apiGroup:
                              type: string
                            kind:
                              type: string
                            name:
                              type: string
                          required:
                          - kind
                          - name
                          type: object
                          x-kubernetes-map-type: atomic
                        dataSourceRef:
                          properties:
                            apiGroup:
                              type: string
                            kind:
                              type: string
                            name:
                              type: string
                            namespace:
                              type: string
                          required:
                          - kind
                          - name
                          type: object
                        resources:
                          properties:
                            limits:
                              additionalProperties:
                                anyOf:
                                - type: integer
                                - type: string
                                pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                x-kubernetes-int-or-string: true
                              type: object
                            requests:
                              additionalProperties:
                                anyOf:
                                - type: integer
                                - type: string
                                pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                x-kubernetes-int-or-string: true
                              type: object
                          type: object
                        selector:
                          properties:
                            matchExpressions:
                              items:
                                properties:
                                  key:
                                    type: string
                                  operator:
                                    type: string
                                  values:
                                    items:
                                      type: string
                                    type: array
                                    x-kubernetes-list-type: atomic
                                required:
                                - key
                                - operator
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            matchLabels:
                              additionalProperties:
                                type: string
                              type: object
                          type: object
                          x-kubernetes-map-type: atomic
                        storageClassName:
                          type: string
                        volumeAttributesClassName:
                          type: string
                        volumeMode:
                          type: string
                        volumeName:
                          type: string
                      type: object
                    status:
                      properties:
                        accessModes:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        allocatedResourceStatuses:
                          additionalProperties:
                            type: string
                          type: object
                          x-kubernetes-map-type: granular
                        allocatedResources:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        capacity:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        conditions:
                          items:
                            properties:
                              lastProbeTime:
                                format: date-time
                                type: string
                              lastTransitionTime:
                                format: date-time
                                type: string
                              message:
                                type: string
                              reason:
                                type: string
                              status:
                                type: string
                              type:
                                type: string
                            required:
                            - status
                            - type
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - type
                          x-kubernetes-list-type: map
                        currentVolumeAttributesClassName:
                          type: string
                        modifyVolumeStatus:
                          properties:
                            status:
                              type: string
                            targetVolumeAttributesClassName:
                              type: string
                          required:
                          - status
                          type: object
                        phase:
                          type: string
                      type: object
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              volumeMounts:
                items:
                  properties:
                    mountPath:
                      type: string
                    mountPropagation:
                      type: string
                    name:
                      type: string
                    readOnly:
                      type: boolean
                    recursiveReadOnly:
                      type: string
                    subPath:
                      type: string
                    subPathExpr:
                      type: string
                  required:
                  - mountPath
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              volumes:
                items:
                  properties:
                    awsElasticBlockStore:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    azureDisk:
                      properties:
                        cachingMode:
                          type: string
                        diskName:
                          type: string
                        diskURI:
                          type: string
                        fsType:
                          default: ext4
                          type: string
                        kind:
                          type: string
                        readOnly:
                          default: false
                          type: boolean
                      required:
                      - diskName
                      - diskURI
                      type: object
                    azureFile:
                      properties:
                        readOnly:
                          type: boolean
                        secretName:
                          type: string
                        shareName:
                          type: string
                      required:
                      - secretName
                      - shareName
                      type: object
                    cephfs:
                      properties:
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        secretFile:
                          type: string
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          type: string
                      required:
                      - monitors
                      type: object
                    cinder:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    configMap:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    csi:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        nodePublishSecretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        readOnly:
                          type: boolean
                        volumeAttributes:
                          additionalProperties:
                            type: string
                          type: object
                      required:
                      - driver
                      type: object
                    downwardAPI:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                            required:
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    emptyDir:
                      properties:
                        medium:
                          type: string
                        sizeLimit:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                      type: object
                    ephemeral:
                      properties:
                        volumeClaimTemplate:
                          properties:
                            metadata:
                              properties:
                                annotations:
                                  additionalProperties:
                                    type: string
                                  type: object
                                finalizers:
                                  items:
                                    type: string
                                  type: array
                                labels:
                                  additionalProperties:
                                    type: string
                                  type: object
                                name:
                                  type: string
                                namespace:
                                  type: string
                              type: object
                            spec:
                              properties:
                                accessModes:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                dataSource:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                  x-kubernetes-map-type: atomic
                                dataSourceRef:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                    namespace:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                resources:
                                  properties:
                                    limits:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                    requests:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                  type: object
                                selector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                storageClassName:
                                  type: string
                                volumeAttributesClassName:
                                  type: string
                                volumeMode:
                                  type: string
                                volumeName:
                                  type: string
                              type: object
                          required:
                          - spec
                          type: object
                      type: object
                    fc:
                      properties:
                        fsType:
                          type: string
                        lun:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        targetWWNs:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        wwids:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    flexVolume:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        options:
                          additionalProperties:
                            type: string
                          type: object
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                      required:
                      - driver
                      type: object
                    flocker:
                      properties:
                        datasetName:
                          type: string
                        datasetUUID:
                          type: string
                      type: object
                    gcePersistentDisk:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        pdName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - pdName
                      type: object
                    gitRepo:
                      properties:
                        directory:
                          type: string
                        repository:
                          type: string
                        revision:
                          type: string
                      required:
                      - repository
                      type: object
                    glusterfs:
                      properties:
                        endpoints:
                          type: string
                        path:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - endpoints
                      - path
                      type: object
                    hostPath:
                      properties:
                        path:
                          type: string
                        type:
                          type: string
                      required:
                      - path
                      type: object
                    image:
                      properties:
                        pullPolicy:
                          type: string
                        reference:
                          type: string
                      type: object
                    iscsi:
                      properties:
                        chapAuthDiscovery:
                          type: boolean
                        chapAuthSession:
                          type: boolean
                        fsType:
                          type: string
                        initiatorName:
                          type: string
                        iqn:
                          type: string
                        iscsiInterface:
                          default: default
                          type: string
                        lun:
                          format: int32
                          type: integer
                        portals:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        targetPortal:
                          type: string
                      required:
                      - iqn
                      - lun
                      - targetPortal
                      type: object
                    name:
                      type: string
                    nfs:
                      properties:
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        server:
                          type: string
                      required:
                      - path
                      - server
                      type: object
                    persistentVolumeClaim:
                      properties:
                        claimName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - claimName
                      type: object
                    photonPersistentDisk:
                      properties:
                        fsType:
                          type: string
                        pdID:
                          type: string
                      required:
                      - pdID
                      type: object
                    portworxVolume:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    projected:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        sources:
                          items:
                            properties:
                              clusterTrustBundle:
                                properties:
                                  labelSelector:
                                    properties:
                                      matchExpressions:
                                        items:
                                          properties:
                                            key:
                                              type: string
                                            operator:
                                              type: string
                                            values:
                                              items:
                                                type: string
                                              type: array
                                              x-kubernetes-list-type: atomic
                                          required:
                                          - key
                                          - operator
                                          type: object
                                        type: array
                                        x-kubernetes-list-type: atomic
                                      matchLabels:
                                        additionalProperties:
                                          type: string
                                        type: object
                                    type: object
                                    x-kubernetes-map-type: atomic
                                  name:
                                    type: string
                                  optional:
                                    type: boolean
                                  path:
                                    type: string
                                  signerName:
                                    type: string
                                required:
                                - path
                                type: object
                              configMap:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              downwardAPI:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        fieldRef:
                                          properties:
                                            apiVersion:
                                              type: string
                                            fieldPath:
                                              type: string
                                          required:
                                          - fieldPath
                                          type: object
                                          x-kubernetes-map-type: atomic
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                        resourceFieldRef:
                                          properties:
                                            containerName:
                                              type: string
                                            divisor:
                                              anyOf:
                                              - type: integer
                                              - type: string
                                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                              x-kubernetes-int-or-string: true
                                            resource:
                                              type: string
                                          required:
                                          - resource
                                          type: object
                                          x-kubernetes-map-type: atomic
                                      required:
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                type: object
                              secret:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              serviceAccountToken:
                                properties:
                                  audience:
                                    type: string
                                  expirationSeconds:
                                    format: int64
                                    type: integer
                                  path:
                                    type: string
                                required:
                                - path
                                type: object
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    quobyte:
                      properties:
                        group:
                          type: string
                        readOnly:
                          type: boolean
                        registry:
                          type: string
                        tenant:
                          type: string
                        user:
                          type: string
                        volume:
                          type: string
                      required:
                      - registry
                      - volume
                      type: object
                    rbd:
                      properties:
                        fsType:
                          type: string
                        image:
                          type: string
                        keyring:
                          default: /etc/ceph/keyring
                          type: string
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        pool:
                          default: rbd
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          default: admin
                          type: string
                      required:
                      - image
                      - monitors
                      type: object
                    scaleIO:
                      properties:
                        fsType:
                          default: xfs
                          type: string
                        gateway:
                          type: string
                        protectionDomain:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        sslEnabled:
                          type: boolean
                        storageMode:
                          default: ThinProvisioned
                          type: string
                        storagePool:
                          type: string
                        system:
                          type: string
                        volumeName:
                          type: string
                      required:
                      - gateway
                      - secretRef
                      - system
                      type: object
                    secret:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        optional:
                          type: boolean
                        secretName:
                          type: string
                      type: object
                    storageos:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeName:
                          type: string
                        volumeNamespace:
                          type: string
                      type: object
                    vsphereVolume:
                      properties:
                        fsType:
                          type: string
                        storagePolicyID:
                          type: string
                        storagePolicyName:
                          type: string
                        volumePath:
                          type: string
                      required:
                      - volumePath
                      type: object
                  required:
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
            required:
            - config
            - managementState
            type: object
          status:
            properties:
              image:
                type: string
              messages:
                items:
                  type: string
                type: array
                x-kubernetes-list-type: atomic
              replicas:
                format: int32
                type: integer
              scale:
                properties:
                  replicas:
                    format: int32
                    type: integer
                  selector:
                    type: string
                  statusReplicas:
                    type: string
                type: object
              version:
                type: string
            type: object
        type: object
    served: true
    storage: false
    subresources:
      scale:
        labelSelectorPath: .status.scale.selector
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.scale.replicas
      status: {}
  - additionalPrinterColumns:
    - description: Deployment Mode
      jsonPath: .spec.mode
      name: Mode
      type: string
    - description: OpenTelemetry Version
      jsonPath: .status.version
      name: Version
      type: string
    - jsonPath: .status.scale.statusReplicas
      name: Ready
      type: string
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    - jsonPath: .status.image
      name: Image
      type: string
    - description: Management State
      jsonPath: .spec.managementState
      name: Management
      type: string
    name: v1beta1
    schema:
      openAPIV3Schema:
        properties:
          apiVersion:
            type: string
          kind:
            type: string
          metadata:
            type: object
          spec:
            properties:
              additionalContainers:
                items:
                  properties:
                    args:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    command:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    env:
                      items:
                        properties:
                          name:
                            type: string
                          value:
                            type: string
                          valueFrom:
                            properties:
                              configMapKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                              secretKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                            type: object
                        required:
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - name
                      x-kubernetes-list-type: map
                    envFrom:
                      items:
                        properties:
                          configMapRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                          prefix:
                            type: string
                          secretRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    image:
                      type: string
                    imagePullPolicy:
                      type: string
                    lifecycle:
                      properties:
                        postStart:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                        preStop:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                      type: object
                    livenessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    name:
                      type: string
                    ports:
                      items:
                        properties:
                          containerPort:
                            format: int32
                            type: integer
                          hostIP:
                            type: string
                          hostPort:
                            format: int32
                            type: integer
                          name:
                            type: string
                          protocol:
                            default: TCP
                            type: string
                        required:
                        - containerPort
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - containerPort
                      - protocol
                      x-kubernetes-list-type: map
                    readinessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    resizePolicy:
                      items:
                        properties:
                          resourceName:
                            type: string
                          restartPolicy:
                            type: string
                        required:
                        - resourceName
                        - restartPolicy
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    resources:
                      properties:
                        claims:
                          items:
                            properties:
                              name:
                                type: string
                              request:
                                type: string
                            required:
                            - name
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - name
                          x-kubernetes-list-type: map
                        limits:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        requests:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                      type: object
                    restartPolicy:
                      type: string
                    securityContext:
                      properties:
                        allowPrivilegeEscalation:
                          type: boolean
                        appArmorProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        capabilities:
                          properties:
                            add:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            drop:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        privileged:
                          type: boolean
                        procMount:
                          type: string
                        readOnlyRootFilesystem:
                          type: boolean
                        runAsGroup:
                          format: int64
                          type: integer
                        runAsNonRoot:
                          type: boolean
                        runAsUser:
                          format: int64
                          type: integer
                        seLinuxOptions:
                          properties:
                            level:
                              type: string
                            role:
                              type: string
                            type:
                              type: string
                            user:
                              type: string
                          type: object
                        seccompProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        windowsOptions:
                          properties:
                            gmsaCredentialSpec:
                              type: string
                            gmsaCredentialSpecName:
                              type: string
                            hostProcess:
                              type: boolean
                            runAsUserName:
                              type: string
                          type: object
                      type: object
                    startupProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    stdin:
                      type: boolean
                    stdinOnce:
                      type: boolean
                    terminationMessagePath:
                      type: string
                    terminationMessagePolicy:
                      type: string
                    tty:
                      type: boolean
                    volumeDevices:
                      items:
                        properties:
                          devicePath:
                            type: string
                          name:
                            type: string
                        required:
                        - devicePath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - devicePath
                      x-kubernetes-list-type: map
                    volumeMounts:
                      items:
                        properties:
                          mountPath:
                            type: string
                          mountPropagation:
                            type: string
                          name:
                            type: string
                          readOnly:
                            type: boolean
                          recursiveReadOnly:
                            type: string
                          subPath:
                            type: string
                          subPathExpr:
                            type: string
                        required:
                        - mountPath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - mountPath
                      x-kubernetes-list-type: map
                    workingDir:
                      type: string
                  required:
                  - name
                  type: object
                type: array
              affinity:
                properties:
                  nodeAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            preference:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            weight:
                              format: int32
                              type: integer
                          required:
                          - preference
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        properties:
                          nodeSelectorTerms:
                            items:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchFields:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                              x-kubernetes-map-type: atomic
                            type: array
                            x-kubernetes-list-type: atomic
                        required:
                        - nodeSelectorTerms
                        type: object
                        x-kubernetes-map-type: atomic
                    type: object
                  podAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  podAntiAffinity:
                    properties:
                      preferredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            podAffinityTerm:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            weight:
                              format: int32
                              type: integer
                          required:
                          - podAffinityTerm
                          - weight
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      requiredDuringSchedulingIgnoredDuringExecution:
                        items:
                          properties:
                            labelSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            matchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            mismatchLabelKeys:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            namespaceSelector:
                              properties:
                                matchExpressions:
                                  items:
                                    properties:
                                      key:
                                        type: string
                                      operator:
                                        type: string
                                      values:
                                        items:
                                          type: string
                                        type: array
                                        x-kubernetes-list-type: atomic
                                    required:
                                    - key
                                    - operator
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                matchLabels:
                                  additionalProperties:
                                    type: string
                                  type: object
                              type: object
                              x-kubernetes-map-type: atomic
                            namespaces:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            topologyKey:
                              type: string
                          required:
                          - topologyKey
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                type: object
              args:
                additionalProperties:
                  type: string
                type: object
              autoscaler:
                properties:
                  behavior:
                    properties:
                      scaleDown:
                        properties:
                          policies:
                            items:
                              properties:
                                periodSeconds:
                                  format: int32
                                  type: integer
                                type:
                                  type: string
                                value:
                                  format: int32
                                  type: integer
                              required:
                              - periodSeconds
                              - type
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          selectPolicy:
                            type: string
                          stabilizationWindowSeconds:
                            format: int32
                            type: integer
                        type: object
                      scaleUp:
                        properties:
                          policies:
                            items:
                              properties:
                                periodSeconds:
                                  format: int32
                                  type: integer
                                type:
                                  type: string
                                value:
                                  format: int32
                                  type: integer
                              required:
                              - periodSeconds
                              - type
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          selectPolicy:
                            type: string
                          stabilizationWindowSeconds:
                            format: int32
                            type: integer
                        type: object
                    type: object
                  maxReplicas:
                    format: int32
                    type: integer
                  metrics:
                    items:
                      properties:
                        pods:
                          properties:
                            metric:
                              properties:
                                name:
                                  type: string
                                selector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                              required:
                              - name
                              type: object
                            target:
                              properties:
                                averageUtilization:
                                  format: int32
                                  type: integer
                                averageValue:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type:
                                  type: string
                                value:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                              required:
                              - type
                              type: object
                          required:
                          - metric
                          - target
                          type: object
                        type:
                          type: string
                      required:
                      - type
                      type: object
                    type: array
                  minReplicas:
                    format: int32
                    type: integer
                  targetCPUUtilization:
                    format: int32
                    type: integer
                  targetMemoryUtilization:
                    format: int32
                    type: integer
                type: object
              config:
                properties:
                  connectors:
                    type: object
                    x-kubernetes-preserve-unknown-fields: true
                  exporters:
                    type: object
                    x-kubernetes-preserve-unknown-fields: true
                  extensions:
                    type: object
                    x-kubernetes-preserve-unknown-fields: true
                  processors:
                    type: object
                    x-kubernetes-preserve-unknown-fields: true
                  receivers:
                    type: object
                    x-kubernetes-preserve-unknown-fields: true
                  service:
                    properties:
                      extensions:
                        items:
                          type: string
                        type: array
                      pipelines:
                        additionalProperties:
                          properties:
                            exporters:
                              items:
                                type: string
                              type: array
                            processors:
                              items:
                                type: string
                              type: array
                            receivers:
                              items:
                                type: string
                              type: array
                          required:
                          - exporters
                          - receivers
                          type: object
                        type: object
                        x-kubernetes-preserve-unknown-fields: true
                      telemetry:
                        type: object
                        x-kubernetes-preserve-unknown-fields: true
                    required:
                    - pipelines
                    type: object
                required:
                - exporters
                - receivers
                - service
                type: object
                x-kubernetes-preserve-unknown-fields: true
              configVersions:
                default: 3
                minimum: 1
                type: integer
              configmaps:
                items:
                  properties:
                    mountpath:
                      type: string
                    name:
                      type: string
                  required:
                  - mountpath
                  - name
                  type: object
                type: array
              daemonSetUpdateStrategy:
                properties:
                  rollingUpdate:
                    properties:
                      maxSurge:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                      maxUnavailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                    type: object
                  type:
                    type: string
                type: object
              deploymentUpdateStrategy:
                properties:
                  rollingUpdate:
                    properties:
                      maxSurge:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                      maxUnavailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                    type: object
                  type:
                    type: string
                type: object
              env:
                items:
                  properties:
                    name:
                      type: string
                    value:
                      type: string
                    valueFrom:
                      properties:
                        configMapKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                        fieldRef:
                          properties:
                            apiVersion:
                              type: string
                            fieldPath:
                              type: string
                          required:
                          - fieldPath
                          type: object
                          x-kubernetes-map-type: atomic
                        resourceFieldRef:
                          properties:
                            containerName:
                              type: string
                            divisor:
                              anyOf:
                              - type: integer
                              - type: string
                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                              x-kubernetes-int-or-string: true
                            resource:
                              type: string
                          required:
                          - resource
                          type: object
                          x-kubernetes-map-type: atomic
                        secretKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                      type: object
                  required:
                  - name
                  type: object
                type: array
              envFrom:
                items:
                  properties:
                    configMapRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    prefix:
                      type: string
                    secretRef:
                      properties:
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                  type: object
                type: array
              hostNetwork:
                type: boolean
              image:
                type: string
              imagePullPolicy:
                type: string
              ingress:
                properties:
                  annotations:
                    additionalProperties:
                      type: string
                    type: object
                  hostname:
                    type: string
                  ingressClassName:
                    type: string
                  route:
                    properties:
                      termination:
                        enum:
                        - insecure
                        - edge
                        - passthrough
                        - reencrypt
                        type: string
                    type: object
                  ruleType:
                    enum:
                    - path
                    - subdomain
                    type: string
                  tls:
                    items:
                      properties:
                        hosts:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        secretName:
                          type: string
                      type: object
                    type: array
                  type:
                    enum:
                    - ingress
                    - route
                    type: string
                type: object
              initContainers:
                items:
                  properties:
                    args:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    command:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    env:
                      items:
                        properties:
                          name:
                            type: string
                          value:
                            type: string
                          valueFrom:
                            properties:
                              configMapKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                              secretKeyRef:
                                properties:
                                  key:
                                    type: string
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                required:
                                - key
                                type: object
                                x-kubernetes-map-type: atomic
                            type: object
                        required:
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - name
                      x-kubernetes-list-type: map
                    envFrom:
                      items:
                        properties:
                          configMapRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                          prefix:
                            type: string
                          secretRef:
                            properties:
                              name:
                                default: ""
                                type: string
                              optional:
                                type: boolean
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    image:
                      type: string
                    imagePullPolicy:
                      type: string
                    lifecycle:
                      properties:
                        postStart:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                        preStop:
                          properties:
                            exec:
                              properties:
                                command:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              type: object
                            httpGet:
                              properties:
                                host:
                                  type: string
                                httpHeaders:
                                  items:
                                    properties:
                                      name:
                                        type: string
                                      value:
                                        type: string
                                    required:
                                    - name
                                    - value
                                    type: object
                                  type: array
                                  x-kubernetes-list-type: atomic
                                path:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                                scheme:
                                  type: string
                              required:
                              - port
                              type: object
                            sleep:
                              properties:
                                seconds:
                                  format: int64
                                  type: integer
                              required:
                              - seconds
                              type: object
                            tcpSocket:
                              properties:
                                host:
                                  type: string
                                port:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  x-kubernetes-int-or-string: true
                              required:
                              - port
                              type: object
                          type: object
                      type: object
                    livenessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    name:
                      type: string
                    ports:
                      items:
                        properties:
                          containerPort:
                            format: int32
                            type: integer
                          hostIP:
                            type: string
                          hostPort:
                            format: int32
                            type: integer
                          name:
                            type: string
                          protocol:
                            default: TCP
                            type: string
                        required:
                        - containerPort
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - containerPort
                      - protocol
                      x-kubernetes-list-type: map
                    readinessProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    resizePolicy:
                      items:
                        properties:
                          resourceName:
                            type: string
                          restartPolicy:
                            type: string
                        required:
                        - resourceName
                        - restartPolicy
                        type: object
                      type: array
                      x-kubernetes-list-type: atomic
                    resources:
                      properties:
                        claims:
                          items:
                            properties:
                              name:
                                type: string
                              request:
                                type: string
                            required:
                            - name
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - name
                          x-kubernetes-list-type: map
                        limits:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        requests:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                      type: object
                    restartPolicy:
                      type: string
                    securityContext:
                      properties:
                        allowPrivilegeEscalation:
                          type: boolean
                        appArmorProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        capabilities:
                          properties:
                            add:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                            drop:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        privileged:
                          type: boolean
                        procMount:
                          type: string
                        readOnlyRootFilesystem:
                          type: boolean
                        runAsGroup:
                          format: int64
                          type: integer
                        runAsNonRoot:
                          type: boolean
                        runAsUser:
                          format: int64
                          type: integer
                        seLinuxOptions:
                          properties:
                            level:
                              type: string
                            role:
                              type: string
                            type:
                              type: string
                            user:
                              type: string
                          type: object
                        seccompProfile:
                          properties:
                            localhostProfile:
                              type: string
                            type:
                              type: string
                          required:
                          - type
                          type: object
                        windowsOptions:
                          properties:
                            gmsaCredentialSpec:
                              type: string
                            gmsaCredentialSpecName:
                              type: string
                            hostProcess:
                              type: boolean
                            runAsUserName:
                              type: string
                          type: object
                      type: object
                    startupProbe:
                      properties:
                        exec:
                          properties:
                            command:
                              items:
                                type: string
                              type: array
                              x-kubernetes-list-type: atomic
                          type: object
                        failureThreshold:
                          format: int32
                          type: integer
                        grpc:
                          properties:
                            port:
                              format: int32
                              type: integer
                            service:
                              default: ""
                              type: string
                          required:
                          - port
                          type: object
                        httpGet:
                          properties:
                            host:
                              type: string
                            httpHeaders:
                              items:
                                properties:
                                  name:
                                    type: string
                                  value:
                                    type: string
                                required:
                                - name
                                - value
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            path:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                            scheme:
                              type: string
                          required:
                          - port
                          type: object
                        initialDelaySeconds:
                          format: int32
                          type: integer
                        periodSeconds:
                          format: int32
                          type: integer
                        successThreshold:
                          format: int32
                          type: integer
                        tcpSocket:
                          properties:
                            host:
                              type: string
                            port:
                              anyOf:
                              - type: integer
                              - type: string
                              x-kubernetes-int-or-string: true
                          required:
                          - port
                          type: object
                        terminationGracePeriodSeconds:
                          format: int64
                          type: integer
                        timeoutSeconds:
                          format: int32
                          type: integer
                      type: object
                    stdin:
                      type: boolean
                    stdinOnce:
                      type: boolean
                    terminationMessagePath:
                      type: string
                    terminationMessagePolicy:
                      type: string
                    tty:
                      type: boolean
                    volumeDevices:
                      items:
                        properties:
                          devicePath:
                            type: string
                          name:
                            type: string
                        required:
                        - devicePath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - devicePath
                      x-kubernetes-list-type: map
                    volumeMounts:
                      items:
                        properties:
                          mountPath:
                            type: string
                          mountPropagation:
                            type: string
                          name:
                            type: string
                          readOnly:
                            type: boolean
                          recursiveReadOnly:
                            type: string
                          subPath:
                            type: string
                          subPathExpr:
                            type: string
                        required:
                        - mountPath
                        - name
                        type: object
                      type: array
                      x-kubernetes-list-map-keys:
                      - mountPath
                      x-kubernetes-list-type: map
                    workingDir:
                      type: string
                  required:
                  - name
                  type: object
                type: array
              ipFamilies:
                items:
                  type: string
                type: array
              ipFamilyPolicy:
                default: SingleStack
                type: string
              lifecycle:
                properties:
                  postStart:
                    properties:
                      exec:
                        properties:
                          command:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      httpGet:
                        properties:
                          host:
                            type: string
                          httpHeaders:
                            items:
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                              required:
                              - name
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          path:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                          scheme:
                            type: string
                        required:
                        - port
                        type: object
                      sleep:
                        properties:
                          seconds:
                            format: int64
                            type: integer
                        required:
                        - seconds
                        type: object
                      tcpSocket:
                        properties:
                          host:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                        required:
                        - port
                        type: object
                    type: object
                  preStop:
                    properties:
                      exec:
                        properties:
                          command:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      httpGet:
                        properties:
                          host:
                            type: string
                          httpHeaders:
                            items:
                              properties:
                                name:
                                  type: string
                                value:
                                  type: string
                              required:
                              - name
                              - value
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          path:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                          scheme:
                            type: string
                        required:
                        - port
                        type: object
                      sleep:
                        properties:
                          seconds:
                            format: int64
                            type: integer
                        required:
                        - seconds
                        type: object
                      tcpSocket:
                        properties:
                          host:
                            type: string
                          port:
                            anyOf:
                            - type: integer
                            - type: string
                            x-kubernetes-int-or-string: true
                        required:
                        - port
                        type: object
                    type: object
                type: object
              livenessProbe:
                properties:
                  failureThreshold:
                    format: int32
                    type: integer
                  initialDelaySeconds:
                    format: int32
                    type: integer
                  periodSeconds:
                    format: int32
                    type: integer
                  successThreshold:
                    format: int32
                    type: integer
                  terminationGracePeriodSeconds:
                    format: int64
                    type: integer
                  timeoutSeconds:
                    format: int32
                    type: integer
                type: object
              managementState:
                default: managed
                enum:
                - managed
                - unmanaged
                type: string
              mode:
                enum:
                - daemonset
                - deployment
                - sidecar
                - statefulset
                type: string
              networkPolicy:
                properties:
                  enabled:
                    type: boolean
                type: object
              nodeSelector:
                additionalProperties:
                  type: string
                type: object
              observability:
                properties:
                  metrics:
                    properties:
                      disablePrometheusAnnotations:
                        type: boolean
                      enableMetrics:
                        type: boolean
                      extraLabels:
                        additionalProperties:
                          type: string
                        type: object
                    type: object
                type: object
              persistentVolumeClaimRetentionPolicy:
                properties:
                  whenDeleted:
                    type: string
                  whenScaled:
                    type: string
                type: object
              podAnnotations:
                additionalProperties:
                  type: string
                type: object
              podDisruptionBudget:
                properties:
                  maxUnavailable:
                    anyOf:
                    - type: integer
                    - type: string
                    x-kubernetes-int-or-string: true
                  minAvailable:
                    anyOf:
                    - type: integer
                    - type: string
                    x-kubernetes-int-or-string: true
                type: object
              podDnsConfig:
                properties:
                  nameservers:
                    items:
                      type: string
                    type: array
                    x-kubernetes-list-type: atomic
                  options:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  searches:
                    items:
                      type: string
                    type: array
                    x-kubernetes-list-type: atomic
                type: object
              podSecurityContext:
                properties:
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  fsGroup:
                    format: int64
                    type: integer
                  fsGroupChangePolicy:
                    type: string
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxChangePolicy:
                    type: string
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  supplementalGroups:
                    items:
                      format: int64
                      type: integer
                    type: array
                    x-kubernetes-list-type: atomic
                  supplementalGroupsPolicy:
                    type: string
                  sysctls:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                      required:
                      - name
                      - value
                      type: object
                    type: array
                    x-kubernetes-list-type: atomic
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              ports:
                items:
                  properties:
                    appProtocol:
                      type: string
                    hostPort:
                      format: int32
                      type: integer
                    name:
                      type: string
                    nodePort:
                      format: int32
                      type: integer
                    port:
                      format: int32
                      type: integer
                    protocol:
                      default: TCP
                      type: string
                    targetPort:
                      anyOf:
                      - type: integer
                      - type: string
                      x-kubernetes-int-or-string: true
                  required:
                  - port
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              priorityClassName:
                type: string
              readinessProbe:
                properties:
                  failureThreshold:
                    format: int32
                    type: integer
                  initialDelaySeconds:
                    format: int32
                    type: integer
                  periodSeconds:
                    format: int32
                    type: integer
                  successThreshold:
                    format: int32
                    type: integer
                  terminationGracePeriodSeconds:
                    format: int64
                    type: integer
                  timeoutSeconds:
                    format: int32
                    type: integer
                type: object
              replicas:
                default: 1
                format: int32
                type: integer
              resources:
                properties:
                  claims:
                    items:
                      properties:
                        name:
                          type: string
                        request:
                          type: string
                      required:
                      - name
                      type: object
                    type: array
                    x-kubernetes-list-map-keys:
                    - name
                    x-kubernetes-list-type: map
                  limits:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                  requests:
                    additionalProperties:
                      anyOf:
                      - type: integer
                      - type: string
                      pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                      x-kubernetes-int-or-string: true
                    type: object
                type: object
              securityContext:
                properties:
                  allowPrivilegeEscalation:
                    type: boolean
                  appArmorProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  capabilities:
                    properties:
                      add:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                      drop:
                        items:
                          type: string
                        type: array
                        x-kubernetes-list-type: atomic
                    type: object
                  privileged:
                    type: boolean
                  procMount:
                    type: string
                  readOnlyRootFilesystem:
                    type: boolean
                  runAsGroup:
                    format: int64
                    type: integer
                  runAsNonRoot:
                    type: boolean
                  runAsUser:
                    format: int64
                    type: integer
                  seLinuxOptions:
                    properties:
                      level:
                        type: string
                      role:
                        type: string
                      type:
                        type: string
                      user:
                        type: string
                    type: object
                  seccompProfile:
                    properties:
                      localhostProfile:
                        type: string
                      type:
                        type: string
                    required:
                    - type
                    type: object
                  windowsOptions:
                    properties:
                      gmsaCredentialSpec:
                        type: string
                      gmsaCredentialSpecName:
                        type: string
                      hostProcess:
                        type: boolean
                      runAsUserName:
                        type: string
                    type: object
                type: object
              serviceAccount:
                type: string
              serviceName:
                type: string
              shareProcessNamespace:
                type: boolean
              targetAllocator:
                properties:
                  affinity:
                    properties:
                      nodeAffinity:
                        properties:
                          preferredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                preference:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchFields:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  type: object
                                  x-kubernetes-map-type: atomic
                                weight:
                                  format: int32
                                  type: integer
                              required:
                              - preference
                              - weight
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          requiredDuringSchedulingIgnoredDuringExecution:
                            properties:
                              nodeSelectorTerms:
                                items:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchFields:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  type: object
                                  x-kubernetes-map-type: atomic
                                type: array
                                x-kubernetes-list-type: atomic
                            required:
                            - nodeSelectorTerms
                            type: object
                            x-kubernetes-map-type: atomic
                        type: object
                      podAffinity:
                        properties:
                          preferredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                podAffinityTerm:
                                  properties:
                                    labelSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    matchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    mismatchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    namespaceSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    namespaces:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    topologyKey:
                                      type: string
                                  required:
                                  - topologyKey
                                  type: object
                                weight:
                                  format: int32
                                  type: integer
                              required:
                              - podAffinityTerm
                              - weight
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          requiredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      podAntiAffinity:
                        properties:
                          preferredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                podAffinityTerm:
                                  properties:
                                    labelSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    matchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    mismatchLabelKeys:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    namespaceSelector:
                                      properties:
                                        matchExpressions:
                                          items:
                                            properties:
                                              key:
                                                type: string
                                              operator:
                                                type: string
                                              values:
                                                items:
                                                  type: string
                                                type: array
                                                x-kubernetes-list-type: atomic
                                            required:
                                            - key
                                            - operator
                                            type: object
                                          type: array
                                          x-kubernetes-list-type: atomic
                                        matchLabels:
                                          additionalProperties:
                                            type: string
                                          type: object
                                      type: object
                                      x-kubernetes-map-type: atomic
                                    namespaces:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    topologyKey:
                                      type: string
                                  required:
                                  - topologyKey
                                  type: object
                                weight:
                                  format: int32
                                  type: integer
                              required:
                              - podAffinityTerm
                              - weight
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          requiredDuringSchedulingIgnoredDuringExecution:
                            items:
                              properties:
                                labelSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                matchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                mismatchLabelKeys:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                namespaceSelector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                namespaces:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                topologyKey:
                                  type: string
                              required:
                              - topologyKey
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                    type: object
                  allocationStrategy:
                    default: consistent-hashing
                    enum:
                    - least-weighted
                    - consistent-hashing
                    - per-node
                    type: string
                  collectorNotReadyGracePeriod:
                    default: 30s
                    format: duration
                    type: string
                  collectorTargetReloadInterval:
                    default: 30s
                    format: duration
                    type: string
                  enabled:
                    type: boolean
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  filterStrategy:
                    default: relabel-config
                    enum:
                    - ""
                    - relabel-config
                    type: string
                  image:
                    type: string
                  nodeSelector:
                    additionalProperties:
                      type: string
                    type: object
                  observability:
                    properties:
                      metrics:
                        properties:
                          disablePrometheusAnnotations:
                            type: boolean
                          enableMetrics:
                            type: boolean
                          extraLabels:
                            additionalProperties:
                              type: string
                            type: object
                        type: object
                    type: object
                  podDisruptionBudget:
                    properties:
                      maxUnavailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                      minAvailable:
                        anyOf:
                        - type: integer
                        - type: string
                        x-kubernetes-int-or-string: true
                    type: object
                  podSecurityContext:
                    properties:
                      appArmorProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      fsGroup:
                        format: int64
                        type: integer
                      fsGroupChangePolicy:
                        type: string
                      runAsGroup:
                        format: int64
                        type: integer
                      runAsNonRoot:
                        type: boolean
                      runAsUser:
                        format: int64
                        type: integer
                      seLinuxChangePolicy:
                        type: string
                      seLinuxOptions:
                        properties:
                          level:
                            type: string
                          role:
                            type: string
                          type:
                            type: string
                          user:
                            type: string
                        type: object
                      seccompProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      supplementalGroups:
                        items:
                          format: int64
                          type: integer
                        type: array
                        x-kubernetes-list-type: atomic
                      supplementalGroupsPolicy:
                        type: string
                      sysctls:
                        items:
                          properties:
                            name:
                              type: string
                            value:
                              type: string
                          required:
                          - name
                          - value
                          type: object
                        type: array
                        x-kubernetes-list-type: atomic
                      windowsOptions:
                        properties:
                          gmsaCredentialSpec:
                            type: string
                          gmsaCredentialSpecName:
                            type: string
                          hostProcess:
                            type: boolean
                          runAsUserName:
                            type: string
                        type: object
                    type: object
                  prometheusCR:
                    properties:
                      allowNamespaces:
                        items:
                          type: string
                        type: array
                      denyNamespaces:
                        items:
                          type: string
                        type: array
                      enabled:
                        type: boolean
                      podMonitorSelector:
                        properties:
                          matchExpressions:
                            items:
                              properties:
                                key:
                                  type: string
                                operator:
                                  type: string
                                values:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              required:
                              - key
                              - operator
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          matchLabels:
                            additionalProperties:
                              type: string
                            type: object
                        type: object
                        x-kubernetes-map-type: atomic
                      probeSelector:
                        properties:
                          matchExpressions:
                            items:
                              properties:
                                key:
                                  type: string
                                operator:
                                  type: string
                                values:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              required:
                              - key
                              - operator
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          matchLabels:
                            additionalProperties:
                              type: string
                            type: object
                        type: object
                        x-kubernetes-map-type: atomic
                      scrapeConfigSelector:
                        properties:
                          matchExpressions:
                            items:
                              properties:
                                key:
                                  type: string
                                operator:
                                  type: string
                                values:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              required:
                              - key
                              - operator
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          matchLabels:
                            additionalProperties:
                              type: string
                            type: object
                        type: object
                        x-kubernetes-map-type: atomic
                      scrapeInterval:
                        default: 30s
                        format: duration
                        type: string
                      serviceMonitorSelector:
                        properties:
                          matchExpressions:
                            items:
                              properties:
                                key:
                                  type: string
                                operator:
                                  type: string
                                values:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                              required:
                              - key
                              - operator
                              type: object
                            type: array
                            x-kubernetes-list-type: atomic
                          matchLabels:
                            additionalProperties:
                              type: string
                            type: object
                        type: object
                        x-kubernetes-map-type: atomic
                    type: object
                  replicas:
                    format: int32
                    type: integer
                  resources:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  securityContext:
                    properties:
                      allowPrivilegeEscalation:
                        type: boolean
                      appArmorProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      capabilities:
                        properties:
                          add:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          drop:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                        type: object
                      privileged:
                        type: boolean
                      procMount:
                        type: string
                      readOnlyRootFilesystem:
                        type: boolean
                      runAsGroup:
                        format: int64
                        type: integer
                      runAsNonRoot:
                        type: boolean
                      runAsUser:
                        format: int64
                        type: integer
                      seLinuxOptions:
                        properties:
                          level:
                            type: string
                          role:
                            type: string
                          type:
                            type: string
                          user:
                            type: string
                        type: object
                      seccompProfile:
                        properties:
                          localhostProfile:
                            type: string
                          type:
                            type: string
                        required:
                        - type
                        type: object
                      windowsOptions:
                        properties:
                          gmsaCredentialSpec:
                            type: string
                          gmsaCredentialSpecName:
                            type: string
                          hostProcess:
                            type: boolean
                          runAsUserName:
                            type: string
                        type: object
                    type: object
                  serviceAccount:
                    type: string
                  tolerations:
                    items:
                      properties:
                        effect:
                          type: string
                        key:
                          type: string
                        operator:
                          type: string
                        tolerationSeconds:
                          format: int64
                          type: integer
                        value:
                          type: string
                      type: object
                    type: array
                  topologySpreadConstraints:
                    items:
                      properties:
                        labelSelector:
                          properties:
                            matchExpressions:
                              items:
                                properties:
                                  key:
                                    type: string
                                  operator:
                                    type: string
                                  values:
                                    items:
                                      type: string
                                    type: array
                                    x-kubernetes-list-type: atomic
                                required:
                                - key
                                - operator
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            matchLabels:
                              additionalProperties:
                                type: string
                              type: object
                          type: object
                          x-kubernetes-map-type: atomic
                        matchLabelKeys:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        maxSkew:
                          format: int32
                          type: integer
                        minDomains:
                          format: int32
                          type: integer
                        nodeAffinityPolicy:
                          type: string
                        nodeTaintsPolicy:
                          type: string
                        topologyKey:
                          type: string
                        whenUnsatisfiable:
                          type: string
                      required:
                      - maxSkew
                      - topologyKey
                      - whenUnsatisfiable
                      type: object
                    type: array
                type: object
              terminationGracePeriodSeconds:
                format: int64
                type: integer
              tolerations:
                items:
                  properties:
                    effect:
                      type: string
                    key:
                      type: string
                    operator:
                      type: string
                    tolerationSeconds:
                      format: int64
                      type: integer
                    value:
                      type: string
                  type: object
                type: array
              topologySpreadConstraints:
                items:
                  properties:
                    labelSelector:
                      properties:
                        matchExpressions:
                          items:
                            properties:
                              key:
                                type: string
                              operator:
                                type: string
                              values:
                                items:
                                  type: string
                                type: array
                                x-kubernetes-list-type: atomic
                            required:
                            - key
                            - operator
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        matchLabels:
                          additionalProperties:
                            type: string
                          type: object
                      type: object
                      x-kubernetes-map-type: atomic
                    matchLabelKeys:
                      items:
                        type: string
                      type: array
                      x-kubernetes-list-type: atomic
                    maxSkew:
                      format: int32
                      type: integer
                    minDomains:
                      format: int32
                      type: integer
                    nodeAffinityPolicy:
                      type: string
                    nodeTaintsPolicy:
                      type: string
                    topologyKey:
                      type: string
                    whenUnsatisfiable:
                      type: string
                  required:
                  - maxSkew
                  - topologyKey
                  - whenUnsatisfiable
                  type: object
                type: array
              trafficDistribution:
                type: string
              upgradeStrategy:
                enum:
                - automatic
                - none
                type: string
              volumeClaimTemplates:
                items:
                  properties:
                    apiVersion:
                      type: string
                    kind:
                      type: string
                    metadata:
                      properties:
                        annotations:
                          additionalProperties:
                            type: string
                          type: object
                        finalizers:
                          items:
                            type: string
                          type: array
                        labels:
                          additionalProperties:
                            type: string
                          type: object
                        name:
                          type: string
                        namespace:
                          type: string
                      type: object
                    spec:
                      properties:
                        accessModes:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        dataSource:
                          properties:
                            apiGroup:
                              type: string
                            kind:
                              type: string
                            name:
                              type: string
                          required:
                          - kind
                          - name
                          type: object
                          x-kubernetes-map-type: atomic
                        dataSourceRef:
                          properties:
                            apiGroup:
                              type: string
                            kind:
                              type: string
                            name:
                              type: string
                            namespace:
                              type: string
                          required:
                          - kind
                          - name
                          type: object
                        resources:
                          properties:
                            limits:
                              additionalProperties:
                                anyOf:
                                - type: integer
                                - type: string
                                pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                x-kubernetes-int-or-string: true
                              type: object
                            requests:
                              additionalProperties:
                                anyOf:
                                - type: integer
                                - type: string
                                pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                x-kubernetes-int-or-string: true
                              type: object
                          type: object
                        selector:
                          properties:
                            matchExpressions:
                              items:
                                properties:
                                  key:
                                    type: string
                                  operator:
                                    type: string
                                  values:
                                    items:
                                      type: string
                                    type: array
                                    x-kubernetes-list-type: atomic
                                required:
                                - key
                                - operator
                                type: object
                              type: array
                              x-kubernetes-list-type: atomic
                            matchLabels:
                              additionalProperties:
                                type: string
                              type: object
                          type: object
                          x-kubernetes-map-type: atomic
                        storageClassName:
                          type: string
                        volumeAttributesClassName:
                          type: string
                        volumeMode:
                          type: string
                        volumeName:
                          type: string
                      type: object
                    status:
                      properties:
                        accessModes:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        allocatedResourceStatuses:
                          additionalProperties:
                            type: string
                          type: object
                          x-kubernetes-map-type: granular
                        allocatedResources:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        capacity:
                          additionalProperties:
                            anyOf:
                            - type: integer
                            - type: string
                            pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                            x-kubernetes-int-or-string: true
                          type: object
                        conditions:
                          items:
                            properties:
                              lastProbeTime:
                                format: date-time
                                type: string
                              lastTransitionTime:
                                format: date-time
                                type: string
                              message:
                                type: string
                              reason:
                                type: string
                              status:
                                type: string
                              type:
                                type: string
                            required:
                            - status
                            - type
                            type: object
                          type: array
                          x-kubernetes-list-map-keys:
                          - type
                          x-kubernetes-list-type: map
                        currentVolumeAttributesClassName:
                          type: string
                        modifyVolumeStatus:
                          properties:
                            status:
                              type: string
                            targetVolumeAttributesClassName:
                              type: string
                          required:
                          - status
                          type: object
                        phase:
                          type: string
                      type: object
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              volumeMounts:
                items:
                  properties:
                    mountPath:
                      type: string
                    mountPropagation:
                      type: string
                    name:
                      type: string
                    readOnly:
                      type: boolean
                    recursiveReadOnly:
                      type: string
                    subPath:
                      type: string
                    subPathExpr:
                      type: string
                  required:
                  - mountPath
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
              volumes:
                items:
                  properties:
                    awsElasticBlockStore:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    azureDisk:
                      properties:
                        cachingMode:
                          type: string
                        diskName:
                          type: string
                        diskURI:
                          type: string
                        fsType:
                          default: ext4
                          type: string
                        kind:
                          type: string
                        readOnly:
                          default: false
                          type: boolean
                      required:
                      - diskName
                      - diskURI
                      type: object
                    azureFile:
                      properties:
                        readOnly:
                          type: boolean
                        secretName:
                          type: string
                        shareName:
                          type: string
                      required:
                      - secretName
                      - shareName
                      type: object
                    cephfs:
                      properties:
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        secretFile:
                          type: string
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          type: string
                      required:
                      - monitors
                      type: object
                    cinder:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    configMap:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        name:
                          default: ""
                          type: string
                        optional:
                          type: boolean
                      type: object
                      x-kubernetes-map-type: atomic
                    csi:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        nodePublishSecretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        readOnly:
                          type: boolean
                        volumeAttributes:
                          additionalProperties:
                            type: string
                          type: object
                      required:
                      - driver
                      type: object
                    downwardAPI:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              fieldRef:
                                properties:
                                  apiVersion:
                                    type: string
                                  fieldPath:
                                    type: string
                                required:
                                - fieldPath
                                type: object
                                x-kubernetes-map-type: atomic
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                              resourceFieldRef:
                                properties:
                                  containerName:
                                    type: string
                                  divisor:
                                    anyOf:
                                    - type: integer
                                    - type: string
                                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                    x-kubernetes-int-or-string: true
                                  resource:
                                    type: string
                                required:
                                - resource
                                type: object
                                x-kubernetes-map-type: atomic
                            required:
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    emptyDir:
                      properties:
                        medium:
                          type: string
                        sizeLimit:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                      type: object
                    ephemeral:
                      properties:
                        volumeClaimTemplate:
                          properties:
                            metadata:
                              properties:
                                annotations:
                                  additionalProperties:
                                    type: string
                                  type: object
                                finalizers:
                                  items:
                                    type: string
                                  type: array
                                labels:
                                  additionalProperties:
                                    type: string
                                  type: object
                                name:
                                  type: string
                                namespace:
                                  type: string
                              type: object
                            spec:
                              properties:
                                accessModes:
                                  items:
                                    type: string
                                  type: array
                                  x-kubernetes-list-type: atomic
                                dataSource:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                  x-kubernetes-map-type: atomic
                                dataSourceRef:
                                  properties:
                                    apiGroup:
                                      type: string
                                    kind:
                                      type: string
                                    name:
                                      type: string
                                    namespace:
                                      type: string
                                  required:
                                  - kind
                                  - name
                                  type: object
                                resources:
                                  properties:
                                    limits:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                    requests:
                                      additionalProperties:
                                        anyOf:
                                        - type: integer
                                        - type: string
                                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                        x-kubernetes-int-or-string: true
                                      type: object
                                  type: object
                                selector:
                                  properties:
                                    matchExpressions:
                                      items:
                                        properties:
                                          key:
                                            type: string
                                          operator:
                                            type: string
                                          values:
                                            items:
                                              type: string
                                            type: array
                                            x-kubernetes-list-type: atomic
                                        required:
                                        - key
                                        - operator
                                        type: object
                                      type: array
                                      x-kubernetes-list-type: atomic
                                    matchLabels:
                                      additionalProperties:
                                        type: string
                                      type: object
                                  type: object
                                  x-kubernetes-map-type: atomic
                                storageClassName:
                                  type: string
                                volumeAttributesClassName:
                                  type: string
                                volumeMode:
                                  type: string
                                volumeName:
                                  type: string
                              type: object
                          required:
                          - spec
                          type: object
                      type: object
                    fc:
                      properties:
                        fsType:
                          type: string
                        lun:
                          format: int32
                          type: integer
                        readOnly:
                          type: boolean
                        targetWWNs:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        wwids:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    flexVolume:
                      properties:
                        driver:
                          type: string
                        fsType:
                          type: string
                        options:
                          additionalProperties:
                            type: string
                          type: object
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                      required:
                      - driver
                      type: object
                    flocker:
                      properties:
                        datasetName:
                          type: string
                        datasetUUID:
                          type: string
                      type: object
                    gcePersistentDisk:
                      properties:
                        fsType:
                          type: string
                        partition:
                          format: int32
                          type: integer
                        pdName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - pdName
                      type: object
                    gitRepo:
                      properties:
                        directory:
                          type: string
                        repository:
                          type: string
                        revision:
                          type: string
                      required:
                      - repository
                      type: object
                    glusterfs:
                      properties:
                        endpoints:
                          type: string
                        path:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - endpoints
                      - path
                      type: object
                    hostPath:
                      properties:
                        path:
                          type: string
                        type:
                          type: string
                      required:
                      - path
                      type: object
                    image:
                      properties:
                        pullPolicy:
                          type: string
                        reference:
                          type: string
                      type: object
                    iscsi:
                      properties:
                        chapAuthDiscovery:
                          type: boolean
                        chapAuthSession:
                          type: boolean
                        fsType:
                          type: string
                        initiatorName:
                          type: string
                        iqn:
                          type: string
                        iscsiInterface:
                          default: default
                          type: string
                        lun:
                          format: int32
                          type: integer
                        portals:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        targetPortal:
                          type: string
                      required:
                      - iqn
                      - lun
                      - targetPortal
                      type: object
                    name:
                      type: string
                    nfs:
                      properties:
                        path:
                          type: string
                        readOnly:
                          type: boolean
                        server:
                          type: string
                      required:
                      - path
                      - server
                      type: object
                    persistentVolumeClaim:
                      properties:
                        claimName:
                          type: string
                        readOnly:
                          type: boolean
                      required:
                      - claimName
                      type: object
                    photonPersistentDisk:
                      properties:
                        fsType:
                          type: string
                        pdID:
                          type: string
                      required:
                      - pdID
                      type: object
                    portworxVolume:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        volumeID:
                          type: string
                      required:
                      - volumeID
                      type: object
                    projected:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        sources:
                          items:
                            properties:
                              clusterTrustBundle:
                                properties:
                                  labelSelector:
                                    properties:
                                      matchExpressions:
                                        items:
                                          properties:
                                            key:
                                              type: string
                                            operator:
                                              type: string
                                            values:
                                              items:
                                                type: string
                                              type: array
                                              x-kubernetes-list-type: atomic
                                          required:
                                          - key
                                          - operator
                                          type: object
                                        type: array
                                        x-kubernetes-list-type: atomic
                                      matchLabels:
                                        additionalProperties:
                                          type: string
                                        type: object
                                    type: object
                                    x-kubernetes-map-type: atomic
                                  name:
                                    type: string
                                  optional:
                                    type: boolean
                                  path:
                                    type: string
                                  signerName:
                                    type: string
                                required:
                                - path
                                type: object
                              configMap:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              downwardAPI:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        fieldRef:
                                          properties:
                                            apiVersion:
                                              type: string
                                            fieldPath:
                                              type: string
                                          required:
                                          - fieldPath
                                          type: object
                                          x-kubernetes-map-type: atomic
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                        resourceFieldRef:
                                          properties:
                                            containerName:
                                              type: string
                                            divisor:
                                              anyOf:
                                              - type: integer
                                              - type: string
                                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                              x-kubernetes-int-or-string: true
                                            resource:
                                              type: string
                                          required:
                                          - resource
                                          type: object
                                          x-kubernetes-map-type: atomic
                                      required:
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                type: object
                              secret:
                                properties:
                                  items:
                                    items:
                                      properties:
                                        key:
                                          type: string
                                        mode:
                                          format: int32
                                          type: integer
                                        path:
                                          type: string
                                      required:
                                      - key
                                      - path
                                      type: object
                                    type: array
                                    x-kubernetes-list-type: atomic
                                  name:
                                    default: ""
                                    type: string
                                  optional:
                                    type: boolean
                                type: object
                                x-kubernetes-map-type: atomic
                              serviceAccountToken:
                                properties:
                                  audience:
                                    type: string
                                  expirationSeconds:
                                    format: int64
                                    type: integer
                                  path:
                                    type: string
                                required:
                                - path
                                type: object
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                      type: object
                    quobyte:
                      properties:
                        group:
                          type: string
                        readOnly:
                          type: boolean
                        registry:
                          type: string
                        tenant:
                          type: string
                        user:
                          type: string
                        volume:
                          type: string
                      required:
                      - registry
                      - volume
                      type: object
                    rbd:
                      properties:
                        fsType:
                          type: string
                        image:
                          type: string
                        keyring:
                          default: /etc/ceph/keyring
                          type: string
                        monitors:
                          items:
                            type: string
                          type: array
                          x-kubernetes-list-type: atomic
                        pool:
                          default: rbd
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        user:
                          default: admin
                          type: string
                      required:
                      - image
                      - monitors
                      type: object
                    scaleIO:
                      properties:
                        fsType:
                          default: xfs
                          type: string
                        gateway:
                          type: string
                        protectionDomain:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        sslEnabled:
                          type: boolean
                        storageMode:
                          default: ThinProvisioned
                          type: string
                        storagePool:
                          type: string
                        system:
                          type: string
                        volumeName:
                          type: string
                      required:
                      - gateway
                      - secretRef
                      - system
                      type: object
                    secret:
                      properties:
                        defaultMode:
                          format: int32
                          type: integer
                        items:
                          items:
                            properties:
                              key:
                                type: string
                              mode:
                                format: int32
                                type: integer
                              path:
                                type: string
                            required:
                            - key
                            - path
                            type: object
                          type: array
                          x-kubernetes-list-type: atomic
                        optional:
                          type: boolean
                        secretName:
                          type: string
                      type: object
                    storageos:
                      properties:
                        fsType:
                          type: string
                        readOnly:
                          type: boolean
                        secretRef:
                          properties:
                            name:
                              default: ""
                              type: string
                          type: object
                          x-kubernetes-map-type: atomic
                        volumeName:
                          type: string
                        volumeNamespace:
                          type: string
                      type: object
                    vsphereVolume:
                      properties:
                        fsType:
                          type: string
                        storagePolicyID:
                          type: string
                        storagePolicyName:
                          type: string
                        volumePath:
                          type: string
                      required:
                      - volumePath
                      type: object
                  required:
                  - name
                  type: object
                type: array
                x-kubernetes-list-type: atomic
            required:
            - config
            type: object
            x-kubernetes-validations:
            - message: the OpenTelemetry Collector mode is set to sidecar, which does
                not support the attribute 'tolerations'
              rule: '!(self.mode == ''sidecar'' && size(self.tolerations) > 0) ||
                !has(self.tolerations)'
            - message: the OpenTelemetry Collector mode is set to sidecar, which does
                not support the attribute 'priorityClassName'
              rule: '!(self.mode == ''sidecar'' && self.priorityClassName != '''')
                || !has(self.priorityClassName)'
            - message: the OpenTelemetry Collector mode is set to sidecar, which does
                not support the attribute 'affinity'
              rule: '!(self.mode == ''sidecar'' && self.affinity != null) || !has(self.affinity)'
            - message: the OpenTelemetry Collector mode is set to sidecar, which does
                not support the attribute 'additionalContainers'
              rule: '!(self.mode == ''sidecar'' && size(self.additionalContainers)
                > 0) || !has(self.additionalContainers)'
          status:
            properties:
              image:
                type: string
              scale:
                properties:
                  replicas:
                    format: int32
                    type: integer
                  selector:
                    type: string
                  statusReplicas:
                    type: string
                type: object
              version:
                type: string
            type: object
        type: object
    served: true
    storage: true
    subresources:
      scale:
        labelSelectorPath: .status.scale.selector
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.scale.replicas
      status: {}
status:
  acceptedNames:
    kind: ""
    plural: ""
  conditions: null
  storedVersions: null
---
# Source: opentelemetry-operator/templates/admission-webhooks/operator-webhook.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
  creationTimestamp: null
  labels:
    app.kubernetes.io/name: opentelemetry-operator
  name: instrumentations.opentelemetry.io
spec:
  group: opentelemetry.io
  names:
    kind: Instrumentation
    listKind: InstrumentationList
    plural: instrumentations
    shortNames:
    - otelinst
    - otelinsts
    singular: instrumentation
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    - jsonPath: .spec.exporter.endpoint
      name: Endpoint
      type: string
    - jsonPath: .spec.sampler.type
      name: Sampler
      type: string
    - jsonPath: .spec.sampler.argument
      name: Sampler Arg
      type: string
    name: v1alpha1
    schema:
      openAPIV3Schema:
        properties:
          apiVersion:
            type: string
          kind:
            type: string
          metadata:
            type: object
          spec:
            properties:
              apacheHttpd:
                properties:
                  attrs:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  configPath:
                    type: string
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  image:
                    type: string
                  resourceRequirements:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  version:
                    type: string
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              defaults:
                properties:
                  useLabelsForResourceAttributes:
                    type: boolean
                type: object
              dotnet:
                properties:
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  image:
                    type: string
                  resourceRequirements:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              env:
                items:
                  properties:
                    name:
                      type: string
                    value:
                      type: string
                    valueFrom:
                      properties:
                        configMapKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                        fieldRef:
                          properties:
                            apiVersion:
                              type: string
                            fieldPath:
                              type: string
                          required:
                          - fieldPath
                          type: object
                          x-kubernetes-map-type: atomic
                        resourceFieldRef:
                          properties:
                            containerName:
                              type: string
                            divisor:
                              anyOf:
                              - type: integer
                              - type: string
                              pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                              x-kubernetes-int-or-string: true
                            resource:
                              type: string
                          required:
                          - resource
                          type: object
                          x-kubernetes-map-type: atomic
                        secretKeyRef:
                          properties:
                            key:
                              type: string
                            name:
                              default: ""
                              type: string
                            optional:
                              type: boolean
                          required:
                          - key
                          type: object
                          x-kubernetes-map-type: atomic
                      type: object
                  required:
                  - name
                  type: object
                type: array
              exporter:
                properties:
                  endpoint:
                    type: string
                  tls:
                    properties:
                      ca_file:
                        type: string
                      cert_file:
                        type: string
                      configMapName:
                        type: string
                      key_file:
                        type: string
                      secretName:
                        type: string
                    type: object
                type: object
              go:
                properties:
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  image:
                    type: string
                  resourceRequirements:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              imagePullPolicy:
                type: string
              java:
                properties:
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  extensions:
                    items:
                      properties:
                        dir:
                          type: string
                        image:
                          type: string
                      required:
                      - dir
                      - image
                      type: object
                    type: array
                  image:
                    type: string
                  resources:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              nginx:
                properties:
                  attrs:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  configFile:
                    type: string
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  image:
                    type: string
                  resourceRequirements:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              nodejs:
                properties:
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  image:
                    type: string
                  resourceRequirements:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              propagators:
                items:
                  enum:
                  - tracecontext
                  - baggage
                  - b3
                  - b3multi
                  - jaeger
                  - xray
                  - ottrace
                  - none
                  type: string
                type: array
              python:
                properties:
                  env:
                    items:
                      properties:
                        name:
                          type: string
                        value:
                          type: string
                        valueFrom:
                          properties:
                            configMapKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                            fieldRef:
                              properties:
                                apiVersion:
                                  type: string
                                fieldPath:
                                  type: string
                              required:
                              - fieldPath
                              type: object
                              x-kubernetes-map-type: atomic
                            resourceFieldRef:
                              properties:
                                containerName:
                                  type: string
                                divisor:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                resource:
                                  type: string
                              required:
                              - resource
                              type: object
                              x-kubernetes-map-type: atomic
                            secretKeyRef:
                              properties:
                                key:
                                  type: string
                                name:
                                  default: ""
                                  type: string
                                optional:
                                  type: boolean
                              required:
                              - key
                              type: object
                              x-kubernetes-map-type: atomic
                          type: object
                      required:
                      - name
                      type: object
                    type: array
                  image:
                    type: string
                  resourceRequirements:
                    properties:
                      claims:
                        items:
                          properties:
                            name:
                              type: string
                            request:
                              type: string
                          required:
                          - name
                          type: object
                        type: array
                        x-kubernetes-list-map-keys:
                        - name
                        x-kubernetes-list-type: map
                      limits:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                      requests:
                        additionalProperties:
                          anyOf:
                          - type: integer
                          - type: string
                          pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                          x-kubernetes-int-or-string: true
                        type: object
                    type: object
                  volumeClaimTemplate:
                    properties:
                      metadata:
                        properties:
                          annotations:
                            additionalProperties:
                              type: string
                            type: object
                          finalizers:
                            items:
                              type: string
                            type: array
                          labels:
                            additionalProperties:
                              type: string
                            type: object
                          name:
                            type: string
                          namespace:
                            type: string
                        type: object
                      spec:
                        properties:
                          accessModes:
                            items:
                              type: string
                            type: array
                            x-kubernetes-list-type: atomic
                          dataSource:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                            x-kubernetes-map-type: atomic
                          dataSourceRef:
                            properties:
                              apiGroup:
                                type: string
                              kind:
                                type: string
                              name:
                                type: string
                              namespace:
                                type: string
                            required:
                            - kind
                            - name
                            type: object
                          resources:
                            properties:
                              limits:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                              requests:
                                additionalProperties:
                                  anyOf:
                                  - type: integer
                                  - type: string
                                  pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                                  x-kubernetes-int-or-string: true
                                type: object
                            type: object
                          selector:
                            properties:
                              matchExpressions:
                                items:
                                  properties:
                                    key:
                                      type: string
                                    operator:
                                      type: string
                                    values:
                                      items:
                                        type: string
                                      type: array
                                      x-kubernetes-list-type: atomic
                                  required:
                                  - key
                                  - operator
                                  type: object
                                type: array
                                x-kubernetes-list-type: atomic
                              matchLabels:
                                additionalProperties:
                                  type: string
                                type: object
                            type: object
                            x-kubernetes-map-type: atomic
                          storageClassName:
                            type: string
                          volumeAttributesClassName:
                            type: string
                          volumeMode:
                            type: string
                          volumeName:
                            type: string
                        type: object
                    required:
                    - spec
                    type: object
                  volumeLimitSize:
                    anyOf:
                    - type: integer
                    - type: string
                    pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                    x-kubernetes-int-or-string: true
                type: object
              resource:
                properties:
                  addK8sUIDAttributes:
                    type: boolean
                  resourceAttributes:
                    additionalProperties:
                      type: string
                    type: object
                type: object
              sampler:
                properties:
                  argument:
                    type: string
                  type:
                    enum:
                    - always_on
                    - always_off
                    - traceidratio
                    - parentbased_always_on
                    - parentbased_always_off
                    - parentbased_traceidratio
                    - jaeger_remote
                    - xray
                    type: string
                type: object
            type: object
          status:
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
status:
  acceptedNames:
    kind: ""
    plural: ""
  conditions: null
  storedVersions: null
---
# Source: opentelemetry-operator/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-manager
rules:
  - apiGroups:
      - ""
    resources:
      - configmaps
      - persistentvolumeclaims
      - persistentvolumes
      - pods
      - serviceaccounts
      - services
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - get
      - list
      - patch
      - watch
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - namespaces/status
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes/spec
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - pods/status
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - replicationcontrollers
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - replicationcontrollers/status
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - resourcequotas
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - apps
    resources:
      - daemonsets
      - deployments
      - statefulsets
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - apps
      - extensions
    resources:
      - replicasets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
    resources:
      - daemonsets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
    resources:
      - deployments
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - autoscaling
    resources:
      - horizontalpodautoscalers
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - batch
    resources:
      - jobs
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - batch
    resources:
      - cronjobs
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
    verbs:
      - get
  - apiGroups:
      - ""
    resources:
      - nodes/stats
    verbs:
      - get
  - apiGroups:
      - config.openshift.io
    resources:
      - infrastructures
      - infrastructures/status
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - coordination.k8s.io
    resources:
      - leases
    verbs:
      - create
      - get
      - list
      - update
  - apiGroups:
      - events.k8s.io
    resources:
      - events
    verbs:
      - list
      - watch
  - apiGroups:
      - monitoring.coreos.com
    resources:
      - podmonitors
      - servicemonitors
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
      - networkpolicies
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - instrumentations
    verbs:
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - opampbridges
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - opampbridges/finalizers
    verbs:
      - update
  - apiGroups:
      - opentelemetry.io
    resources:
      - opampbridges/status
    verbs:
      - get
      - patch
      - update
  - apiGroups:
      - opentelemetry.io
    resources:
      - opentelemetrycollectors
    verbs:
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - opentelemetrycollectors/finalizers
    verbs:
      - get
      - patch
      - update
  - apiGroups:
      - opentelemetry.io
    resources:
      - opentelemetrycollectors/status
    verbs:
      - get
      - patch
      - update
  - apiGroups:
      - policy
    resources:
      - poddisruptionbudgets
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - route.openshift.io
    resources:
      - routes
      - routes/custom-host
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
    - opentelemetry.io
    resources:
      - targetallocators
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
    - opentelemetry.io
    resources:
    - targetallocators/status
    verbs:
    - get
    - patch
    - update
  - apiGroups:
      - cert-manager.io
    resources:
      - issuers
      - certificaterequests
      - certificates
    verbs:
      - create
      - get
      - list
      - watch
      - update
      - patch
      - delete
  - apiGroups:
      - authorization.k8s.io
    resources:
      - subjectaccessreviews
    verbs:
      - create
---
# Source: opentelemetry-operator/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-metrics
rules:
  - nonResourceURLs:
      - /metrics
    verbs:
      - get
---
# Source: opentelemetry-operator/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-proxy
rules:
  - apiGroups:
      - authentication.k8s.io
    resources:
      - tokenreviews
    verbs:
      - create
---
# Source: opentelemetry-operator/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-operator-opentelemetry-operator-manager
subjects:
  - kind: ServiceAccount
    name: opentelemetry-operator
    namespace: cpd-operators
---
# Source: opentelemetry-operator/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-operator-opentelemetry-operator-proxy
subjects:
  - kind: ServiceAccount
    name: opentelemetry-operator
    namespace: cpd-operators
---
# Source: opentelemetry-operator/templates/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-leader-election
  namespace: cpd-operators
rules:
  - apiGroups:
      - ""
    resources:
      - configmaps
      - pods
      - serviceaccounts
      - services
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
  - apiGroups:
      - ""
    resources:
      - namespaces
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - apps
    resources:
      - daemonsets
      - deployments
      - statefulsets
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - apps
    resources:
      - replicasets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - autoscaling
    resources:
      - horizontalpodautoscalers
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - batch
    resources:
      - jobs
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - config.openshift.io
    resources:
      - infrastructures
      - infrastructures/status
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - coordination.k8s.io
    resources:
      - leases
    verbs:
      - create
      - get
      - list
      - update
  - apiGroups:
      - monitoring.coreos.com
    resources:
      - podmonitors
      - servicemonitors
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - instrumentations
      - opentelemetrycollectors
    verbs:
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - opampbridges
      - targetallocators
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - opentelemetry.io
    resources:
      - opampbridges/finalizers
    verbs:
      - update
  - apiGroups:
      - opentelemetry.io
    resources:
      - opampbridges/status
      - opentelemetrycollectors/finalizers
      - opentelemetrycollectors/status
      - targetallocators/status
    verbs:
      - get
      - patch
      - update
  - apiGroups:
      - policy
    resources:
      - poddisruptionbudgets
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - route.openshift.io
    resources:
      - routes
      - routes/custom-host
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
---
# Source: opentelemetry-operator/templates/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-leader-election
  namespace: cpd-operators
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: otel-operator-opentelemetry-operator-leader-election
subjects:
  - kind: ServiceAccount
    name: opentelemetry-operator
    namespace: cpd-operators
---
# Source: opentelemetry-operator/templates/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scc-privileged-access
  namespace: cpd-operators
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: Group
    name: system:serviceaccounts:cpd-operators
    apiGroup: rbac.authorization.k8s.io
---
# Source: opentelemetry-operator/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator
  namespace: cpd-operators
spec:
  ports:
    - name: https
      port: 8443
      protocol: TCP
      targetPort: https
    - name: metrics
      port: 8080
      protocol: TCP
      targetPort: metrics
  selector:
      app.kubernetes.io/name: opentelemetry-operator
      app.kubernetes.io/component: controller-manager
---
# Source: opentelemetry-operator/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator-webhook
  namespace: cpd-operators
spec:
  ports:
    - port: 443
      protocol: TCP
      targetPort: webhook-server
  selector:
      app.kubernetes.io/name: opentelemetry-operator
      app.kubernetes.io/component: controller-manager
---
# Source: opentelemetry-operator/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: controller-manager
  name: otel-operator-opentelemetry-operator
  namespace: cpd-operators
spec:
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app.kubernetes.io/name: opentelemetry-operator
      app.kubernetes.io/component: controller-manager
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: manager
      labels:
        helm.sh/chart: opentelemetry-operator-0.97.1
        app.kubernetes.io/name: opentelemetry-operator
        app.kubernetes.io/version: "rhosdt-3.7.0"
        app.kubernetes.io/managed-by: Helm
        app.kubernetes.io/part-of: opentelemetry-operator
        app.kubernetes.io/instance: otel-operator
        app.kubernetes.io/component: controller-manager
    spec:
      automountServiceAccountToken: true
      hostNetwork: false
      containers:
        - args:
            - --metrics-addr=0.0.0.0:8080
            - --enable-leader-election
            - --health-probe-addr=:8081
            - --webhook-port=9443
            - --collector-image=registry.redhat.io/rhosdt/opentelemetry-rhel8-operator:rhosdt-3.7.0
          
          env:
            - name: SERVICE_ACCOUNT_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.serviceAccountName
            - name: ENABLE_WEBHOOKS
              value: "true"
          image: "registry.redhat.io/rhosdt/opentelemetry-rhel8-operator:rhosdt-3.7.0"
          name: manager
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
              name: metrics
              protocol: TCP
            - containerPort: 9443
              name: webhook-server
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8081
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8081
            initialDelaySeconds: 5
            periodSeconds: 10
          resources: 
            {}
          volumeMounts:
            - mountPath: /tmp/k8s-webhook-server/serving-certs
              name: cert
              readOnly: true
          securityContext: 
            allowPrivilegeEscalation: false
            capabilities:
              drop:
              - ALL
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
        
        - args:
            - --secure-listen-address=0.0.0.0:8443
            - --upstream=http://127.0.0.1:8080/
            - --v=0
          image: "quay.io/brancz/kube-rbac-proxy:v0.19.1"
          name: kube-rbac-proxy
          ports:
            - containerPort: 8443
              name: https
              protocol: TCP
          securityContext: 
            allowPrivilegeEscalation: false
            capabilities:
              drop:
              - ALL
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
      imagePullSecrets:
        - name: 15478606-opentelemetry-operator-pull-pull-secret
      nodeSelector: 
        kubernetes.io/os: linux
      serviceAccountName: opentelemetry-operator
      terminationGracePeriodSeconds: 10
      volumes:
        - name: cert
          secret:
            defaultMode: 420
            secretName: otel-operator-opentelemetry-operator-controller-manager-service-cert
      securityContext:
        fsGroup: 65532
        runAsGroup: 65532
        runAsNonRoot: true
        runAsUser: 65532
---
# Source: opentelemetry-operator/templates/certmanager.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: webhook
  name: otel-operator-opentelemetry-operator-serving-cert
  namespace: cpd-operators
spec:
  dnsNames:
    - otel-operator-opentelemetry-operator-webhook.cpd-operators.svc
    - otel-operator-opentelemetry-operator-webhook.cpd-operators.svc.cluster.local
  issuerRef:
    kind: Issuer
    name: otel-operator-opentelemetry-operator-selfsigned-issuer
  secretName: otel-operator-opentelemetry-operator-controller-manager-service-cert
  subject:
    organizationalUnits:
      - otel-operator-opentelemetry-operator
---
# Source: opentelemetry-operator/templates/certmanager.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: webhook
  name: otel-operator-opentelemetry-operator-selfsigned-issuer
  namespace: cpd-operators
spec:
  selfSigned: {}
---
# Source: opentelemetry-operator/templates/admission-webhooks/operator-webhook-with-cert-manager.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  annotations:
    cert-manager.io/inject-ca-from: cpd-operators/otel-operator-opentelemetry-operator-serving-cert
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: webhook
  name: otel-operator-opentelemetry-operator-mutation
webhooks:
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /mutate-opentelemetry-io-v1alpha1-instrumentation
        port: 443
    failurePolicy: Fail
    name: minstrumentation.kb.io
    rules:
    - apiGroups:
        - opentelemetry.io
      apiVersions:
        - v1alpha1
      operations:
        - CREATE
        - UPDATE
      resources:
        - instrumentations
      scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /mutate-opentelemetry-io-v1beta1-opentelemetrycollector
        port: 443
    failurePolicy: Fail
    name: mopentelemetrycollectorbeta.kb.io
    rules:
      - apiGroups:
          - opentelemetry.io
        apiVersions:
          - v1beta1
        operations:
          - CREATE
          - UPDATE
        resources:
          - opentelemetrycollectors
        scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /mutate-v1-pod
        port: 443
    failurePolicy: Ignore
    name: mpod.kb.io
    rules:
      - apiGroups:
          - ""
        apiVersions:
          - v1
        operations:
          - CREATE
        resources:
          - pods
        scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
---
# Source: opentelemetry-operator/templates/admission-webhooks/operator-webhook-with-cert-manager.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  annotations:
    cert-manager.io/inject-ca-from: cpd-operators/otel-operator-opentelemetry-operator-serving-cert
  labels:
    helm.sh/chart: opentelemetry-operator-0.97.1
    app.kubernetes.io/name: opentelemetry-operator
    app.kubernetes.io/version: "rhosdt-3.7.0"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: opentelemetry-operator
    app.kubernetes.io/instance: otel-operator
    app.kubernetes.io/component: webhook
  name: otel-operator-opentelemetry-operator-validation
webhooks:
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /validate-opentelemetry-io-v1alpha1-instrumentation
        port: 443
    failurePolicy: Fail
    name: vinstrumentationcreateupdate.kb.io
    rules:
    - apiGroups:
        - opentelemetry.io
      apiVersions:
        - v1alpha1
      operations:
        - CREATE
        - UPDATE
      resources:
        - instrumentations
      scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /validate-opentelemetry-io-v1alpha1-instrumentation
        port: 443
    failurePolicy: Ignore
    name: vinstrumentationdelete.kb.io
    rules:
      - apiGroups:
          - opentelemetry.io
        apiVersions:
          - v1alpha1
        operations:
          - DELETE
        resources:
          - instrumentations
        scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /validate-opentelemetry-io-v1beta1-opentelemetrycollector
        port: 443
    failurePolicy: Fail
    name: vopentelemetrycollectorcreateupdatebeta.kb.io
    rules:
      - apiGroups:
          - opentelemetry.io
        apiVersions:
          - v1beta1
        operations:
          - CREATE
          - UPDATE
        resources:
          - opentelemetrycollectors
        scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
  - admissionReviewVersions:
      - v1
    clientConfig:
      service:
        name: otel-operator-opentelemetry-operator-webhook
        namespace: cpd-operators
        path: /validate-opentelemetry-io-v1beta1-opentelemetrycollector
        port: 443
    failurePolicy: Ignore
    name: vopentelemetrycollectordeletebeta.kb.io
    rules:
      - apiGroups:
          - opentelemetry.io
        apiVersions:
          - v1beta1
        operations:
          - DELETE
        resources:
          - opentelemetrycollectors
        scope: Namespaced
    sideEffects: None
    timeoutSeconds: 10
EOF
}

InstallOtelCollectorYAML() {
  local ns="$1"
  local OS_USER="$2"
  local OS_PASS="$3"
  cat <<EOF | oc apply -f -
---
# Source: otel-collector-cr/templates/jaeger-instance.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: wo-jaeger-instance
  namespace: $ns
spec:
  ports:
    - name: jaeger
      port: 16686
      protocol: TCP
      targetPort: 0
  image: jaegertracing/jaeger
  replicas: 1
  config:
    exporters:
      jaeger_storage_exporter:
        trace_storage: some_storage
    extensions:
      jaeger_query:
        http:
          endpoint: '0.0.0.0:16686'
        storage:
          traces: some_storage
      jaeger_storage:
        backends:
          some_storage:
            opensearch: &opensearch_config
              auth:
                basic:
                  username: $OS_USER
                  password: $OS_PASS
              indices:
                dependencies:
                  date_layout: '2006-01-02'
                  replicas: 1
                  rollover_frequency: day
                  shards: 5
                index_prefix: jaeger-main
                sampling:
                  date_layout: '2006-01-02'
                  replicas: 1
                  rollover_frequency: day
                  shards: 5
                services:
                  date_layout: '2006-01-02'
                  replicas: 1
                  rollover_frequency: day
                  shards: 5
                spans:
                  date_layout: '2006-01-02'
                  replicas: 1
                  rollover_frequency: day
                  shards: 5
              server_urls:
                - https://wo-opensearch-cluster.$ns.svc.cluster.local:9200
              tls:
                insecure_skip_verify: false
                ca_file: /certs/ca.crt
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: '0.0.0.0:4317'
          http:
            endpoint: '0.0.0.0:4318'
    service:
      extensions:
        - jaeger_storage
        - jaeger_query
      pipelines:
        traces:
          exporters:
            - jaeger_storage_exporter
          receivers:
            - otlp
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
  volumeMounts:
    - name: opensearch-tls
      mountPath: /certs
      readOnly: true
  volumes:
    - name: opensearch-tls
      secret:
        secretName: wo-opensearch-ca-secret
EOF
}

InstallAgentOpsYAML() {
  local ns="$1"
  local JWT_SECRET="$2"
  local IMAGE_PREFIX="$3"
  local IMAGE_SECRET="$4"
  local OS_USER="$5"
  local OS_PASS="$6"
  cat <<EOF | oc apply -f -
---
# Source: agentops/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wo-agentops
  namespace: $ns
  labels:
    helm.sh/chart: agentops-0.1.0
    app.kubernetes.io/name: agentops
    app.kubernetes.io/instance: wo-agentops
    app.kubernetes.io/version: "1.16.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: agentops/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: wo-agentops-pull-secret
  namespace: $ns
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $IMAGE_SECRET
---
# Source: agentops/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: wo-agentops-app-secret
  namespace: $ns
type: kubernetes.io/opaque
stringData:
  TEST: "true"
  STORE_TYPE: "opensearch"
  API_KEY_AUTH_ENABLED: "true"
  OS_USERNAME: "$OS_USER"
  OS_PASSWORD: "$OS_PASS"
  OS_HOST: "https://wo-opensearch-cluster.$ns.svc.cluster.local:9200"
  JWT_SECRET_KEY: "$JWT_SECRET"
  JAEGER_URL: "http://wo-jaeger-instance-collector.$ns.svc.cluster.local:16686"
  JAEGER_COLLECT_URL: "http://wo-jaeger-instance-collector.$ns.svc.cluster.local"
  WATSONX_PROJECT_ID: ""
  WATSONX_SPACE_ID: ""
  WATSONX_APIKEY: ""
  WATSONX_URL: ""
  PROXY_SERVER_URL: 
  DEFAULT_TENANT_ID: "default"
  TENANT_CONFIG_FILE: "/app/config/proxy-config.yaml"
  TENANT_CONFIG_URL: "http://wo-archer-server.cpd-instance-1.svc.cluster.local:4321"
  TENANT_DEFAULT_HOSTNAME: "https://wo-opensearch-cluster.$ns.svc.cluster.local:9200"
  FORCE_SINGLE_TENANT: "true"
  PROJECT_ROOT: "/app"
  INBOUND_API_KEY: "$JWT_SECRET"
  TENANT_API_KEY: "$JWT_SECRET"
  TENANT_DEFAULT_PASSWORD: "$OS_PASS"
  TENANT_DEFAULT_USERNAME: "$OS_USER"
---
# Source: agentops/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: wo-agentops-proxy-config
  namespace: $ns
data:
  proxy-config.yaml: |
    default_tenant: "default"
    # Tenant configurations
    tenants:
      # Default tenant on ES instance 1
      default:
        store_type: opensearch
        hostname: "https://wo-opensearch-cluster.$ns.svc.cluster.local:9200"
        username: "$OS_USER"
        password: "$OS_PASS"
        index_prefix: "default"
---
# Source: agentops/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: wo-agentops
  namespace: $ns
  labels:
    helm.sh/chart: agentops-0.1.0
    app.kubernetes.io/name: agentops
    app.kubernetes.io/instance: wo-agentops
    app.kubernetes.io/version: "1.16.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 8765
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: agentops
    app.kubernetes.io/instance: wo-agentops
---
# Source: agentops/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wo-agentops
  namespace: $ns
  labels:
    helm.sh/chart: agentops-0.1.0
    app.kubernetes.io/name: agentops
    app.kubernetes.io/instance: wo-agentops
    app.kubernetes.io/version: "1.16.0"
    app.kubernetes.io/managed-by: Helm
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: agentops
      app.kubernetes.io/instance: wo-agentops
  template:
    metadata:
      labels:
        helm.sh/chart: agentops-0.1.0
        app.kubernetes.io/name: agentops
        app.kubernetes.io/instance: wo-agentops
        app.kubernetes.io/version: "1.16.0"
        app.kubernetes.io/managed-by: Helm
    spec:
      imagePullSecrets:
        - name: wo-agentops-pull-secret
      serviceAccountName: wo-agentops
      securityContext:
        {}
      containers:
        - name: agentops
          securityContext:
            {}
          image: "${IMAGE_PREFIX}/cp/watsonx-orchestrate/agent-analytics:v5.3.0-20251014.164252@sha256:8cdd7eea47a5e389eb8cda49ae6676782ea4eb94d6d3ec3fb1fe4c4b737b08c7"
          imagePullPolicy: IfNotPresent
          envFrom:
          - secretRef:
              name: wo-agentops-app-secret
          ports:
            - name: http
              containerPort: 8765
              protocol: TCP
          livenessProbe:
            null
          readinessProbe:
            null
          resources:
            {}
          volumeMounts:
            - mountPath: /app/config/proxy-config.yaml
              name: wo-agentops-proxy-config
              readOnly: true
              subPath: proxy-config.yaml
      volumes:
        - configMap:
            name: wo-agentops-proxy-config
          name: wo-agentops-proxy-config
EOF
}

########################################
# Main script
#######################################
DEMO_MODE=false
CPD_INSTANCE_NS="cpd-instance-1"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CHART_DIR="${SCRIPT_DIR}/../../charts/non-olm"
MODE="install"
EXTRA_OPTS=""
JWT_SECRET=$(openssl rand -base64 32)
IMAGE_PREFIX="cp.icr.io"
OS_USER="admin"
OS_PASS=$(openssl rand -base64 16)
OC_PULL_SECRET=$(oc get secret pull-secret -n openshift-config -o jsonpath="{.data.\.dockerconfigjson}")
RH_TOKEN=$OC_PULL_SECRET
IMAGE_SECRET=$OC_PULL_SECRET
IMAGE_KEY=""
AUTH_JSON_PREFIX='{ "auths": { "'
AUTH_JSON_MID='": { "auth": "'
AUTH_ISON_END='" } } }'

while (($# > 0)); do
  case "$1" in
  -h | --help) # display Help
    Help
    ;;
  --cpd_instance_ns=*) # Namespace where observability resources are installed
    CPD_INSTANCE_NS="${1#*=}"
    ;;
  --redhat_token=*) # RedHat Customer portal token for operators
    RH_TOKEN="${1#*=}"
    ;;
  --image_pull_prefix=*) # Image repo for IBM images, default 'cp.icr.io'
    IMAGE_PREFIX="${1#*=}"
    ;;
  --image_pull_secret=*) # Pull secret token for icr.io images
    IMAGE_KEY="${1#*=}"
    ;;
  --os_user=*) # Configure username for Opensearch
    OS_USER="${1#*=}"
    ;;
  --os_pass=*) # Configure password for Opensearch
    OS_PASS="${1#*=}"
    ;;
  --trace)
    set -o xtrace
    ;;
  *) # incorrect option
    echo "Error: ${*} is not a valid option."
    Help
    ;;
  esac
  shift
done

if ! command -v oc &> /dev/null
then
    echo "The installation script has a dependency on OpenShift tool oc. Install oc to continue."
    exit
fi

if [ $IMAGE_KEY != "" ]; then
  AUTH_JSON_BLOCK="$AUTH_JSON_PREFIX$IMAGE_PREFIX$AUTH_JSON_MID$IMAGE_KEY$AUTH_ISON_END"
  IMAGE_SECRET=$(echo $AUTH_JSON_BLOCK | base64)
fi

InstallIBMOpenSearchClusterYAML $CPD_INSTANCE_NS $OS_USER $OS_PASS $IMAGE_PREFIX
InstallOtelOperatorYAML $RH_TOKEN
if [ "${MODE}" == "install" ]; then
  oc rollout status deployment/otel-operator-opentelemetry-operator -n cpd-operators --timeout=180s
  wait_for_endpoints "cpd-operators" "otel-operator-opentelemetry-operator-webhook"
  wait_for_cluster $CPD_INSTANCE_NS "wo-opensearch-cluster"
  oc wait --for=condition=Ready pod -l cluster.opensearch.cloudpackopen.ibm.com=wo-opensearch-cluster -n $CPD_INSTANCE_NS --timeout=300s
fi
InstallOtelCollectorYAML $CPD_INSTANCE_NS $OS_USER $OS_PASS
InstallAgentOpsYAML $CPD_INSTANCE_NS $JWT_SECRET $IMAGE_PREFIX $IMAGE_SECRET $OS_USER $OS_PASS