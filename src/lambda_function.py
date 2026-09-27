import json
import os
import time
import boto3

from boto3.dynamodb.conditions import Key

from aws_xray_sdk.core import patch_all
# Enable X-Ray instrumentation
patch_all()

from decimal import Decimal

# Setup SNS Client
sns_client = boto3.client('sns')
# Setup DynamoDB Client
dynamodb = boto3.resource('dynamodb')

# Topic to publish filtered purchases to (set as a Lambda env var)
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
# Only purchases at/above this amount are forwarded to SNS
PURCHASE_THRESHOLD = Decimal(os.environ.get('PURCHASE_THRESHOLD', '100'))
# Table name (env-driven so a bad value can be injected to demo a failure)
TABLE_NAME = os.environ.get('TABLE_NAME', 'CustomerPurchase')

# ---- Failure-injection toggles (all default to "off" / safe) ----
# Raise an exception unconditionally -> 500 fault in X-Ray, red canary
FAIL_MODE = os.environ.get('FAIL_MODE', '').lower()
# Sleep this many seconds before work -> injects latency / can force a timeout
INJECT_LATENCY_SECONDS = float(os.environ.get('INJECT_LATENCY_SECONDS', '0') or '0')

table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    # Optional injected latency (demonstrates slow requests / timeouts)
    if INJECT_LATENCY_SECONDS > 0:
        time.sleep(INJECT_LATENCY_SECONDS)

    # Optional forced exception (demonstrates a clean 500 fault)
    if FAIL_MODE == 'exception':
        raise RuntimeError('Injected failure: FAIL_MODE=exception')

    # customerId comes from the query string, default "1"
    customer_id = _customer_id_from_event(event)

    # Query DynamoDB
    items = query_dynamo(customer_id)
    # Filter Items
    filtered_items = filter_items(items)
    # Publish filtered items to SNS
    publish_to_sns(filtered_items)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'customerId': customer_id,
            'processed_items': len(filtered_items)
        })
    }


def _customer_id_from_event(event) -> str:
    """Read customerId from the HTTP API query string, defaulting to '1'."""
    params = (event or {}).get('queryStringParameters') or {}
    return params.get('customerId', '1')


def query_dynamo(customerId: str) -> list:
    response = table.query(
        KeyConditionExpression=Key('CustomerId').eq(customerId)
    )
    return response['Items']


def filter_items(items: list) -> list:
    """Keep only purchases at or above the configured threshold."""
    return [
        item for item in items
        if Decimal(str(item.get('Amount', 0))) >= PURCHASE_THRESHOLD
    ]


def publish_to_sns(items: list) -> None:
    """Publish each filtered purchase to the SNS topic."""
    if not items:
        return
    if not SNS_TOPIC_ARN:
        raise RuntimeError('SNS_TOPIC_ARN environment variable is not set')

    for item in items:
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject='High-value purchase',
            Message=json.dumps(item, default=_json_default),
        )


def _json_default(value):
    """Make DynamoDB Decimal values JSON-serializable."""
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
    raise TypeError(f'Object of type {type(value).__name__} is not JSON serializable')
