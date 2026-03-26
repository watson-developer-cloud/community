# Restart WA pods. Run this script after changing to the project where WA is installed.
# Author - Manu Thapar
# Copyright 2021 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

INSTANCE="$(oc get wa -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"

if [ -z "$INSTANCE" ]; then
  echo "# Unable to determine Watson Assistant instance name from 'oc get wa'."
  exit 1
fi

echo "# Detected Watson Assistant instance name: $INSTANCE"

restart_and_wait() {
  DEPLOYMENT_NAME="$1"

  echo "# Starting rolling restart of ${DEPLOYMENT_NAME}."
  if oc rollout restart "deployment/${DEPLOYMENT_NAME}" 2>/dev/null; then
    if oc rollout status "deployment/${DEPLOYMENT_NAME}" --watch=true; then
      echo "# Rolling restart of ${DEPLOYMENT_NAME} completed successfully."
    else
      echo "# Rolling restart of ${DEPLOYMENT_NAME} started, but rollout status check failed."
    fi
  else
    echo "# Deployment ${DEPLOYMENT_NAME} not found, skipping."
  fi
}

restart_only() {
  DEPLOYMENT_NAME="$1"

  echo "# Starting rolling restart of ${DEPLOYMENT_NAME}."
  if oc rollout restart "deployment/${DEPLOYMENT_NAME}" 2>/dev/null; then
    return 0
  fi

  echo "# Deployment ${DEPLOYMENT_NAME} not found, skipping."
  return 1
}

wait_for_rollout() {
  DEPLOYMENT_NAME="$1"

  if oc rollout status "deployment/${DEPLOYMENT_NAME}" --watch=true 2>/dev/null; then
    echo "# Rolling restart of ${DEPLOYMENT_NAME} completed successfully."
  else
    echo "# Rolling restart of ${DEPLOYMENT_NAME} started, but rollout status check failed."
  fi
}

restart_and_wait "${INSTANCE}-ed"
restart_and_wait "${INSTANCE}-dragonfly-clu-mm"
restart_and_wait "${INSTANCE}-tfmm"
restart_and_wait "tf"
restart_and_wait "${INSTANCE}-clu-serving"
restart_and_wait "${INSTANCE}-master"
restart_and_wait "${INSTANCE}-nlu"
restart_and_wait "${INSTANCE}-dialog"
restart_and_wait "${INSTANCE}-store"

STARTED_DEPLOYMENTS=""

for DEPLOYMENT in \
  dragonfly-clu-dms \
  ed-dms \
  clu-serving-dms \
  clu-training \
  clu-triton-serving \
  analytics \
  clu-embedding \
  incoming-webhooks \
  integrations \
  recommends \
  spellchecker-mm \
  spellchecker \
  store-sync \
  system-entities \
  ui \
  webhooks-connector \
  gw-instance \
  gw-provisioner \
  store-admin \
  dms-controller \
  redis-clu-haproxy \
  redis-haproxy \
  knative-wa-clu-dlq
do
  if restart_only "${INSTANCE}-${DEPLOYMENT}"; then
    STARTED_DEPLOYMENTS="${STARTED_DEPLOYMENTS} ${INSTANCE}-${DEPLOYMENT}"
  fi
done

for DEPLOYMENT_NAME in $STARTED_DEPLOYMENTS
do
  wait_for_rollout "${DEPLOYMENT_NAME}"
done

echo "# Watson Assistant deployment restart flow completed."
