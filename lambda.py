import sys
import datetime
from io import StringIO
import json
# https://boto3.amazonaws.com/v1/documentation/api/latest/guide/secrets-manager.html
import boto3
from botocore.exceptions import ClientError
import logging

# If we already have a logger, set its level. This will be true on Lambda.
if logging.getLogger().hasHandlers():
    logging.getLogger().setLevel(logging.INFO)
# Otherwise, make a logger and set its level.
else:
    logging.basicConfig(level=logging.INFO)

# https://boto3.amazonaws.com/v1/documentation/api/latest/guide/secrets-manager.html
# I've extended this to return values for ease of debugging. This isn't production code.
def get_secret(secret_name = "example_secret"):
    logging.info("getting secret")
    # we could be checking the AWS_REGION env var here.
    region_name = "us-east-2"

    session = boto3.session.Session()
    client = session.client(
        service_name='secretsmanager',
        region_name=region_name,
    )

    try:
        get_secret_value_response = client.get_secret_value(
            SecretId=secret_name
        )
        logging.info("successfully got secret")
    except ClientError as e:
        logging.info("did not get secret")
        logging.info(f"{e}")
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            print("The requested secret " + secret_name + " was not found")
            return "-1"
        elif e.response['Error']['Code'] == 'InvalidRequestException':
            print("The request was invalid due to:", e)
            return "-2"
        elif e.response['Error']['Code'] == 'InvalidParameterException':
            print("The request had invalid params:", e)
            return "-3"
        elif e.response['Error']['Code'] == 'DecryptionFailure':
            print("The requested secret can't be decrypted using the provided KMS key:", e)
            return "-4"
        elif e.response['Error']['Code'] == 'InternalServiceError':
            print("An error occurred on service side:", e)
            return "-5"
    else:
        if 'SecretString' in get_secret_value_response:
            text_secret_data = get_secret_value_response['SecretString']
            return text_secret_data
        else:
            logging.info("no secret string")
            return "-6"

def simulated_query(x):
    logging.info(f"simulated query argument was {json.dumps(x)}")
    fake_credentials = json.loads(get_secret())
    # we'd use those credentials to do a query of some sort.
    if x is not None and x != '':
        argument_description = f"Query argument was {x}"
    else:
        argument_description = "No query argument"
    # return fake_credentials["username"]
    return "Successfully retrieved credentials for username {}. {}".format(fake_credentials["username"], argument_description)

def lambda_handler(event, context):
    logging.info(f"Starting lambda at {datetime.datetime.utcnow()}")
    query_arg = None if event is None else str(event)
    data = simulated_query(query_arg)
    # This return type is specific to making API gateway work.
    x = {
        "statusCode": 200,
        "headers": {
            'Content-Type': 'text/html; charset=utf-8',
        },
        "body": json.dumps(data),
    }
    return x
