#!/usr/local/bin/python3
#
# Given a CSV file containing utterances to simulate a user's questions, and a set of
# input parameters, this script will call the Watson Conversation /message API and 
# simulate an interaction between a user and the Conversation service. The result will
# include data in the Improve tab of the Watson Conversation Service UI.
#
# The CSV file format allows you to include a sequence of utterances 
# in the same conversation. Place each utterance on a separate line.
# To start a new conversation, you should include a line with the string :init:
#
# For example, a CSV to simulate two conversations with the Car Dashboard Demo
# sample application # could be as simple as these four lines:
# question,answer_regex,"intents"
# turn lights on
# :init:
# hit the brake
#

import sys
import json
import time
import urllib.request
import urllib.error
import base64
import datetime
import re
import ssl
import csv
import requests
import argparse

test_result = True
preProvisionedInstance = False

parser = argparse.ArgumentParser()
parser.add_argument("endpoint")
parser.add_argument("service_creds")
parser.add_argument("workspace_id")
parser.add_argument("question_csv_file")
parser.add_argument("-c", "--customer_id")
parser.add_argument("-d", "--deployment_id")
args = parser.parse_args()

endpoint = args.endpoint
service_creds = args.service_creds
workspace_id = args.workspace_id
auth_header = 'Basic ' + base64.b64encode(bytes(service_creds,"utf-8")).decode("ascii")[:-1]
version = "?version=2017-05-03"
gcontext = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)

if True:
    csv_reader = csv.DictReader(open(args.question_csv_file),escapechar="\\")
    context = { "metadata": { "deployment": args.deployment_id }} if args.deployment_id is not None else None
    prevContext = None
    turnCount = 0

    for turn in csv_reader:
        turnCount = turnCount + 1
        if turn["question"][0] == ";":
            continue
        if turn["question"] == ":init:":
            context = { "metadata": { "deployment": args.deployment_id }} if args.deployment_id is not None else None
            turnCount = 0
            continue

        message = { "input": { "text": turn["question"] } ,"alternate_intents": True}
        if "intents" in turn and turn["intents"]:
            message["intents"] = json.loads(turn["intents"])
        if context is not None:
            message["context"] = context
        turn_data = bytes(json.dumps(message),"utf-8")
        turn_data_len = len(turn_data)
        url = endpoint + "/v1/workspaces/" + workspace_id + "/message" + version
        if args.customer_id is not None:
            req = urllib.request.Request(url, turn_data, {'Content-Type': 'application/json', 'X-Watson-Metadata' : 'customer_id=' + args.customer_id, 'Content-Length': turn_data_len, 'Authorization': auth_header})
        else:
            req = urllib.request.Request(url, turn_data, {'Content-Type': 'application/json', 'Content-Length': turn_data_len, 'Authorization': auth_header})
        response = response_data = None

        try:
            response = urllib.request.urlopen(req, context=gcontext)
        except urllib.error.HTTPError as e:
            print("For URL: %s" % (url))
            print("Error asking question: %s %s" % (e.code, e.reason))
            sys.exit(1)

        response_data = response.read()
        response.close()
        response_json = json.loads(response_data)
        prevContext = context
        context = response_json["context"]
                 
        output = " ".join(map(lambda x: str(x), response_json["output"]["text"]))

        #if prevContext is None:
        if turnCount == 1:
            print()
            print("Conversation ID: %s (%s)" % (context["conversation_id"], datetime.datetime.now().strftime("%Y%m%d-%H:%M:%S")))

        print()
        print("Input : %s" % turn["question"])

        if turn["answer_regex"] and not re.match(turn["answer_regex"], output):
            print("ERROR ERROR ERROR")
            print("Expected output: %s" % turn["answer_regex"])
            print("Actual output  : %s" % output)
            test_result = False
        else:
            print("Output: %s" % output)

if not test_result:
    sys.exit(2)
else:
    sys.exit(0)