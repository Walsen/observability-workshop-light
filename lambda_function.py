import json
import sys
import os
import boto3

from boto3.dynamodb.conditions import Key, Attr

from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all
# Enable X-Ray instrumentation
patch_all()

from decimal import Decimal

# Setup SNS Client
sns_client = boto3.client('sns')
# Setup DynamoDB Client + Table Reference
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('CustomerPurchase')

# Topic to publish filtered purchases to (set as a Lambda env var)
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
# Only purchases at/above this amount are forwarded to SNS
PURCHASE_THRESHOLD = Decimal(os.environ.get('PURCHASE_THRESHOLD', '100'))


def lambda_handler(event, context):
    # Query DynamoDB
    items = query_dynamo("1")
    # Filter Items
    filtered_items = filter_items(items)
    # Publish filtered items to SNS
    publish_to_sns(filtered_items)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'processed_items': len(filtered_items)
        })
    }


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

