# Copyright 2018 IBM All Rights Reserved.
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

import pandas as pd
import argparse
import json
from watson_developer_cloud import AssistantV1 as WatsonAssistant
from urllib.parse import urlparse, parse_qs

# Set up arguments. 
parser = argparse.ArgumentParser()
parser.add_argument('workspace_id', help='Watson Assistant workspace ID', type=str)
parser.add_argument('--userpass', help='Watson Assistant service username:password. Cannot be used with --apikey', type=str, default=None)
parser.add_argument('--apikey', help='Watson Assistant API Key. Cannot be used with --userpass', type=str, default=None)
parser.add_argument('filename', help='Output file name.',type=str)
parser.add_argument('--filetype', help='Output file type. Can be: CSV, TSV, XLSX, JSON (default)', type=str, default='JSON', choices=['CSV','TSV','XLSX','JSON'])
parser.add_argument('--url', help='Default is https://gateway-fra.watsonplatform.net/assistant/api', type=str, default='https://gateway-fra.watsonplatform.net/assistant/api')
parser.add_argument('--version', help='Default = 2018-09-20', type=str, default='2018-09-20')
parser.add_argument('--totalpages', help='Maximum number of pages to pull. Default is 999', type=int, default=999)
parser.add_argument('--pagelimit', help='Maximum number of records to a page. Default is 200.', type=int, default=200)
parser.add_argument('--filter', help='Search filter to use.', type=str, default='')

args = parser.parse_args()

## This part is used for saving dataframes. 
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

## Saving methods. 
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
            r = o['response']
            s = r['context']['system']
                
            row[f_conversation_id] = r['context'][f_conversation_id]
            row[f_request_timestamp] = o[f_request_timestamp]
            row[f_response_timestamp] = o[f_response_timestamp]
            
            if 'text' in r['input']: row[f_user_input] = r['input']['text']
            if 'text' in r['output']:row[f_output] = ' '.join(r['output']['text'])
                
            if len(r['intents']) > 0:
                row[f_confidence] = r['intents'][0]['confidence']
                row[f_intent] = r['intents'][0]['intent']

           
            if 'branch_exited_reason' in s: row[f_exit_reason] = s['branch_exited_reason']
            
            if 'log_messaging' in r['output']: row[f_logging] = r['output']['log_messaging']
            
            row[f_context] = json.dumps(r['context'])
            
            rows.append(row)

    # Build the dataframe. 
    df = pd.DataFrame(rows,columns=columns)

    # cleaning up dataframe. Removing NaN and converting date fields. 
    df = df.fillna('')
    df[f_request_timestamp] = pd.to_datetime(df[f_request_timestamp])
    df[f_response_timestamp] = pd.to_datetime(df[f_response_timestamp])

    # Lastly sort by conversation ID, and then request, so that the logs become readable. 
    df = df.sort_values([f_conversation_id, f_request_timestamp], ascending=[True, True])

    return df

## Make connection to conversation. 
if args.userpass != None and args.apikey == None:
    up = args.userpass.split(':')
    username = up[0]
    password = up[1]
    c = WatsonAssistant(url=args.url, version=args.version, username=username, password=password)

elif args.apikey != None and args.userpass == None:
    c = WatsonAssistant(url=args.url, version=args.version, iam_apikey=args.apikey)
else:
    print('You must set --userpass or --apikey to run. Exiting.')
    exit(1)



## Download the logs.
j = []
page_count = 1
cursor = None
count = 0

x = { 'pagination': 'DUMMY' }
while x['pagination']:
    if page_count > args.totalpages: 
        break

    print('Reading page {}.'.format(page_count))
    x = c.list_logs(workspace_id=args.workspace_id,cursor=cursor,page_limit=args.pagelimit, filter=args.filter)
    x = x.result  # Assistant V2 update.
    
    j.append(x['logs'])
    count = count + len(x['logs'])

    page_count = page_count + 1

    if 'pagination' in x and 'next_url' in x['pagination']:
        p = x['pagination']['next_url']
        u = urlparse(p)
        query = parse_qs(u.query)
        cursor = query['cursor'][0]
    
## Determine how the file should be saved. 
args.filetype = args.filetype.upper()
if args.filetype == 'CSV':
    save_xsv(data=j,sep=',',file_name=args.filename)
elif args.filetype == 'TSV':
    save_xsv(data=j,sep='\t',file_name=args.filename)
elif args.filetype == 'XLSX':
    save_xlsx(data=j, file_name=args.filename)
else:
    save_json(data=j,file_name=args.filename),
 
print('Writing {} records to: {} as file type: {}'.format(count, args.filename, args.filetype))