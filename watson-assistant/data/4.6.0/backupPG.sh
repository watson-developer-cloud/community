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
# Version: 1.5.0
#
# This script can be used to run pg_dump on the WA Postgres instance.
#
# It is provided as is.
#
# It should be run from a machine that has kubernetes access to your CPD environment.
# The script requires jq to be on your PATH.
# You should be logged into your CP4D cluster and be switched to the correct project / namespace.
#
# Usage: backupPG.sh [--instance INSTANCE]
#
# Specify --instance The instance of the WA deployment you want to backup
#
# The contents of the database will be sent to stdout. 
# You should redirect the output of the script to the location of your choice i.e. ./backupPG.sh > pg.dump
#
#################################################################

set -o nounset
set +e
#set -x

WA_POSTGRES_POD=
VCAP_SECRET_NAME=
PASSWORD=
DATABASE=
USERNAME=
INSTANCE=
CLI=oc
SHORT_INSTANCE=wa

#Change this var to pass extra arguments to the pg_dump command
PGDUMP_ARGS="-Fc"
SHORT_INSTANCE="$( cut -d '-' -f 1 <<< "$SHORT_INSTANCE" )"

function die() {
  echo "$@" 1>&2

  exit 99
}

function showHelp() {
  echo "Usage backupPG.sh [--instance INSTANCE]"
  echo "Script runs pg_dump command against store db."
  echo ""
  echo "--instance: The instance of the WA deployment you want to backup. The default is wa."
  echo
}

#############################
# Processing command-line parameters
#############################
if [ "$#" -eq 0 ]; then
 echo "Instance not specified, defaulting to ‘wa’" 1>&2
fi
if [ "$#" -eq 2 ]; then
    if [[ $1 == -c ]] || [[ $1 == --c ]] || [[ $1 == --cli ]]; then
        echo "Instance not specified, defaulting to ‘wa’" 1>&2
    fi
fi

while (( $# > 0 )); do
  case "$1" in
    -i | --i | --instance )
      option=${2:-}
      if [[ $option == -* ]] || [[ $option == "" ]]; then
        die "ERROR: --instance argument has no value"
      fi
      shift
      INSTANCE=",app.kubernetes.io/instance=$option"
      SHORT_INSTANCE=$option
      ;;
    -h | --h | --help )
      showHelp
      exit 2
      ;;
    * | -* )
      echo "Unknown option: $1"
      showHelp
      exit 99
      ;;
  esac
  shift
done

##################
# Checking for jq
##################
if ! which jq >/dev/null; then
  die "ERROR: jq command not found. Ensure that you have jq installed and on your PATH."
fi
	
#################
# Test connection
#################
if ! oc whoami >/dev/null 2>&1 ; then
  die "ERROR: Can't connect to Cluster. Please log into your Cluster and switch to the correct project."
fi

#################
# Fetch secrets 
#################
#Fetch a running Postgres Keeper Pod
WA_POSTGRES_POD=$($CLI get pods --field-selector=status.phase=Running -l postgresql=$SHORT_INSTANCE-postgres -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
rc=$?; [[ $rc != 0 ]] || [ -z "$WA_POSTGRES_POD" ] && die "ERROR: No postgres keeper pod found running. Please check the instance parameter value."

#Fetch the store vcap secret name
VCAP_SECRET_NAME=$($CLI get secrets -l component=store${INSTANCE} -o=custom-columns=NAME:.metadata.name | grep store-vcap 2>/dev/null)
rc=$?; [[ $rc != 0 ]] || [ -z "$VCAP_SECRET_NAME" ] && die "ERROR: Couldn't find store vcap secret."


#Fetch Postgres secret values
USERNAME=$($CLI get secret $VCAP_SECRET_NAME -o jsonpath="{.data.vcap_services}" | base64 --decode | jq --raw-output '.["user-provided"][]|.credentials|.username')
rc=$?; [[ $rc != 0 ]] || [ -z "$USERNAME" ] && die "ERROR: Couldn't find postgres username in store vcap secret."
PASSWORD=$($CLI get secret $VCAP_SECRET_NAME -o jsonpath="{.data.vcap_services}" | base64 --decode | jq --raw-output '.["user-provided"][]|.credentials|.password')
rc=$?; [[ $rc != 0 ]] || [ -z "$PASSWORD" ] && die "ERROR: Couldn't find postgres password in store vcap secret."
DATABASE=$($CLI get secret $VCAP_SECRET_NAME -o jsonpath="{.data.vcap_services}" | base64 --decode | jq --raw-output '.["user-provided"][]|.credentials|.database')
rc=$?; [[ $rc != 0 ]] || [ -z "$DATABASE" ] && die "ERROR: Couldn't find postgres database name in store vcap secret."
HOSTNAME=$($CLI get secret $VCAP_SECRET_NAME -o jsonpath="{.data.vcap_services}" | base64 --decode | jq --raw-output '.["user-provided"][]|.credentials|.host')
rc=$?; [[ $rc != 0 ]] || [ -z "$HOSTNAME" ] && die "ERROR: Couldn't find postgres host name in store vcap secret."

#################
# Run pg_dump 
#################
$CLI exec $WA_POSTGRES_POD -c postgres -- bash -c "export PGPASSWORD='$PASSWORD' && pg_dump $PGDUMP_ARGS -h $HOSTNAME -d $DATABASE -U $USERNAME"
