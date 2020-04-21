# Copyright 2020 IBM All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: Simon O'Doherty
# Contact: Simon.O.Doherty1@ibm.com
#
# Note: The code below is a sample provided to illustrate one way 
# to approach this issue and is used as is and at your own risk. In order 
# for this example to perform as intended, the script must be laid out exactly 
# as indicated below. Product Support cannot customize this script for specific 
# environments or applications.

""" Notes on running.
Just run the program for the command line options.

* No longer backward compatible. Only apikey authentication supported.
* apikey + url you can get from your service credentials page in IBM Cloud.
* Default is to read your workspace. Use --logtype to change if you want assistant or deployment.
* All log types require an ID that relates to the log you are trying to pull.
* Using the filter option will negate the following settings and you have to set yourself
    * language, logtype, id.
* If you scroll down you can hard code your defaults easily.
* built using python 3.8.

Example command lines:
* python export_logs.py apikey workspace_id test.json
* python export_logs.py apikey assistant_id test.xlsx --logtype ASSISTANT --filetype XLSX --url service_url
* python export_logs.py apikey deployment_id test.csv --logtype DEPLOYMENT --filetype CSV --strip --url service_url

"""


import pandas as pd
import argparse
import json
from ibm_watson import AssistantV1 as WatsonAssistant
from ibm_cloud_sdk_core.authenticators import IAMAuthenticator
from urllib.parse import urlparse, parse_qs

C_DEPLOYMENT = 'DEPLOYMENT'
C_ASSISTANT = 'ASSISTANT'
C_WORKSPACE = 'WORKSPACE'
C_CSV = 'CSV'
C_TSV = 'TSV'
C_XLSX = 'XLSX'
C_JSON = 'JSON'

c_RESPONSE = 'response'
c_CONTEXT = 'context'
c_SYSTEM = 'system'
c_INPUT = 'input'
c_OUTPUT = 'output'
c_INTENTS = 'intents'
c_INTENT = 'intent'
c_TEXT = 'text'
c_BRANCH_EXITED_REASON = 'branch_exited_reason'
c_LOG_MESSAGING = 'log_messaging'
c_CONFIDENCE = 'confidence'
c_LOGS = 'logs'
c_PAGINATION = 'pagination'
c_NEXT_URL = 'next_url'
c_CURSOR = 'cursor'

# If you want to hard code your main defaults.
default_version = '2020-04-01'
default_url = 'https://gateway.watsonplatform.net/assistant/api'
default_logtype = C_WORKSPACE
default_language = 'en'

parser = argparse.ArgumentParser()
parser.add_argument('apikey', help='Watson Assistant API Key.', type=str)
parser.add_argument('id', help=f'identifier for logtype. For example workspace_id if {C_WORKSPACE} was specified.', type=str)
parser.add_argument('filename', help='Output file name.',type=str)
parser.add_argument('--logtype', help=f'What logs to pull. Options are Default is {default_logtype}.',
                    type=str, default=default_logtype, choices=[C_ASSISTANT, C_WORKSPACE, C_DEPLOYMENT])
parser.add_argument('--language', help=f'Default is {default_language}.', type=str, default=default_language)
parser.add_argument('--filetype', help=f'Output file type. Can be: {C_CSV}, {C_TSV}, {C_XLSX}, {C_JSON} (default)',
                    type=str, default='JSON', choices=[C_CSV, C_TSV, C_XLSX, C_JSON])
parser.add_argument('--url', help=f'Default is {default_url}.', type=str, default=default_url)
parser.add_argument('--version', help=f'Default is {default_version}.', type=str, default=default_version)
parser.add_argument('--totalpages', help='Maximum number of pages to pull. Default is 999', type=int, default=999)
parser.add_argument('--pagelimit', help='Maximum number of records to a page. Default is 200.', type=int, default=200)
parser.add_argument('--filter', help='Search filter to use. This overrides logtype, so you will need to manually set.',
                    type=str, default=None)
parser.add_argument('--strip', help='Strip newlines from output text. Default is false.', type=bool, default=False)

args = parser.parse_args()

f_conversation_id = 'conversation_id'
f_request_timestamp = 'request_timestamp'
f_response_timestamp = 'response_timestamp'
f_user_input = 'User Input'
f_output = 'Output'
f_intent = 'Intent'
f_confidence = 'Confidence'
f_exit_reason = 'Exit Reason'
f_logging = 'Logging'
f_context = 'Context'

columns = [
    f_conversation_id, f_request_timestamp, f_response_timestamp, 
    f_user_input, f_output, f_intent, f_confidence, f_exit_reason, f_logging, f_context
]


# Saving methods.
def save_json(data=None,file_name=None):
    with open(file_name, 'w') as out:
        json.dump(data,out)


def save_xsv(data=None, sep=',', file_name=None):
    df = convert_json_to_dataframe(data)
    if df is not None:
        df.to_csv(args.filename,encoding='utf8',sep=sep,index=False)


def save_xlsx(data=None, file_name=None):
    df = convert_json_to_dataframe(data)
    if df is not None:
        df.to_excel(args.filename,index=False)


def convert_json_to_dataframe(data=None):
    rows = []

    if data == [[]]:
        print('No Logs found. :(')
        return None

    for data_records in data:
        for o in data_records:
            row = {}
            
            # Let's shorthand the response and system object.
            r = o[c_RESPONSE]
            s = r[c_CONTEXT][c_SYSTEM]
                
            row[f_conversation_id] = r[c_CONTEXT][f_conversation_id]
            row[f_request_timestamp] = o[f_request_timestamp]
            row[f_response_timestamp] = o[f_response_timestamp]
            
            if c_TEXT in r[c_INPUT]:
                row[f_user_input] = r[c_INPUT][c_TEXT]

            if c_TEXT in r[c_OUTPUT]:
                row[f_output] = ' '.join(r[c_OUTPUT][c_TEXT])
                if args.strip:
                    row[f_output] = row[f_output].replace('\l','').replace('\n','').replace('\r','')
                
            if len(r[c_INTENTS]) > 0:
                row[f_confidence] = r[c_INTENTS][0][c_CONFIDENCE]
                row[f_intent] = r[c_INTENTS][0][c_INTENT]

            if c_BRANCH_EXITED_REASON in s:
                row[f_exit_reason] = s[c_BRANCH_EXITED_REASON]
            
            if c_LOG_MESSAGING in r[c_OUTPUT]:
                row[f_logging] = r[c_OUTPUT][c_LOG_MESSAGING]
            
            row[f_context] = json.dumps(r[c_CONTEXT])
            
            rows.append(row)

    # Build the dataframe. 
    df = pd.DataFrame(rows,columns=columns)

    # cleaning up dataframe. Removing NaN and converting date fields. 
    df = df.fillna('')

    # Prevent timezone limitation in to_excel call.
    if args.filetype != C_XLSX:
        df[f_request_timestamp] = pd.to_datetime(df[f_request_timestamp])
        df[f_response_timestamp] = pd.to_datetime(df[f_response_timestamp])

    # Lastly sort by conversation ID, and then request, so that the logs become readable. 
    df = df.sort_values([f_conversation_id, f_request_timestamp], ascending=[True, True])

    return df


# Make connection to Watson Assistant.
authenticator = IAMAuthenticator(args.apikey)
c = WatsonAssistant(version=args.version, authenticator=authenticator)
c.set_service_url(args.url)

# Determine how logs will be pulled.
logtype = None
pull_filter = None

if args.filter is None:
    args.logtype = args.logtype.upper()
    if args.logtype == C_WORKSPACE:
        logtype = 'workspace_id'
    elif args.logtype == C_ASSISTANT:
        logtype = 'request.context.system.assistant_id'
    elif args.logtype == C_DEPLOYMENT:
        logtype = 'request.context.metadata.deployment'
    else:
        print("Error: I don't understand logtype {}. Exiting.".format(args.logtype))
        exit(1)

    print(f'Reading {args.logtype} using ID {args.id}.')
    pull_filter = 'language::{},{}::{}'.format(args.language, logtype, args.id)
else:
    print(f'Reading using filter: {args.filter}')
    pull_filter = args.filter

# Download the logs.
j = []
page_count = 1
cursor = None
count = 0

x = { c_PAGINATION: 'DUMMY' }
while x[c_PAGINATION]:
    if page_count > args.totalpages: 
        break

    print('Reading page {}.'.format(page_count))
    x = c.list_all_logs(filter=pull_filter,cursor=cursor,page_limit=args.pagelimit).result
    
    j.append(x[c_LOGS])
    count = count + len(x[c_LOGS])

    page_count = page_count + 1

    if c_PAGINATION in x and c_NEXT_URL in x[c_PAGINATION]:
        p = x[c_PAGINATION][c_NEXT_URL]
        u = urlparse(p)
        query = parse_qs(u.query)
        cursor = query[c_CURSOR][0]
    
# Determine how the file should be saved.
args.filetype = args.filetype.upper()
if args.filetype == C_CSV:
    save_xsv(data=j, sep=',',file_name=args.filename)
elif args.filetype == C_TSV:
    save_xsv(data=j, sep='\t',file_name=args.filename)
elif args.filetype == C_XLSX:
    save_xlsx(data=j, file_name=args.filename)
else:
    save_json(data=j, file_name=args.filename),
 
print('Writing {} records to: {} as file type: {}'.format(count, args.filename, args.filetype))
