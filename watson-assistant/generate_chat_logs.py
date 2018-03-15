#!/usr/bin/env python
# -*- coding: utf-8 -*-

from __future__ import print_function  # Python 3 support

import sys
import json
import datetime
import re
import csv
import argparse
from watson_developer_cloud import ConversationV1, WatsonApiException


def build_metadata(arguments):
    """
    Builds the context metadata if deployment or user_id are specified as arguments
    """
    deploy_tag = { "deployment": arguments.deployment_id} if arguments.deployment_id is not None else None
    user_id = { "user_id": arguments.user_id} if arguments.user_id is not None else None
    metadata = None
    if deploy_tag is not None:
        if user_id is not None:
            metadata = deploy_tag.copy()
            metadata.update(user_id)
        else:
            metadata = deploy_tag
    else:
        if user_id is not None:
            metadata = user_id
    return metadata


def parse_arguments():
    """
    Build the argparse and parses the program arguments
    """
    parser = argparse.ArgumentParser()
    
    parser.add_argument("username", help="Conversation username")
    parser.add_argument("password", help="Conversation password")
    parser.add_argument("workspace_id", help="Conversation Workspace id")
    parser.add_argument("question_csv_file", help="Input set of questions in a CSV file.")
    parser.add_argument("--url", help="Conversation url. Default is https://gateway.watsonplatform.net/conversation/api",
                        default="https://gateway.watsonplatform.net/conversation/api")
    parser.add_argument("--customer_id")
    parser.add_argument("--deployment_id")
    parser.add_argument("--user_id")
    return parser.parse_args()



def main():
    """Given a CSV file containing utterances to simulate a user's questions, and a set of
    input parameters, this script will call the Watson Conversation /message API and
    simulate an interaction between a user and the Conversation service. The result will
    include data in the Improve tab of the Watson Conversation Service UI.
    The CSV file format allows you to include a sequence of utterances
    in the same conversation. Place each utterance on a separate line.
    To start a new conversation, you should include a line with the string :init:
    For example, a CSV to simulate two conversations with the Car Dashboard Demo
    sample application # could be as simple as these six lines:
    question
    hi
    turn lights on
    :init:
    hi
    hit the brake
    """
    # 1. Parse the arguments
    args = parse_arguments()

    # 2. Create the conversation instance
    conversation = ConversationV1(
        url=args.url,
        username=args.username,
        password=args.password,
        version='2017-05-03')
        
    if args.customer_id is not None:
        conversation.set_default_headers({'X-Watson-Metadata': 'customer_id=' + args.customer_id})
	
	# 2. Built the message metadata and context if provided
    metadata = build_metadata(args)
    context = {'metadata': metadata} if metadata is not None else None

    # 3. Read the CSV file
    csv_reader = csv.DictReader(open(args.question_csv_file), escapechar='\\')
    test_result = True
    turn_count = 0

    # 4. Process the csv file
    for turn in csv_reader:
        turn_count += 1
        if turn['question'][0] == ';':
            continue
        if turn['question'] == ':init:':
            context = {'metadata': metadata} if metadata is not None else None
            turn_count = 0
            continue

        response = None
        try:
            response = conversation.message(workspace_id=args.workspace_id, input={'text': turn["question"]}, context=context)
        except WatsonApiException as error:
            print(error)
            sys.exit(1)

        context = response['context']
        output = ' '.join(str(x) for x in response['output']['text'])

        if turn_count == 1:
            print('Conversation ID: %s (%s)' % (context['conversation_id'], str(datetime.datetime.now())))

        print('Input : %s' % turn['question'])
        print('Output: %s\n' % output)

    return


if main():
    sys.exit(0)
else:
    sys.exit(2)
