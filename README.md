# A simple example of trying AWS CloudWatch X-Ray + Synthetics

## Setup for the Workshop

Project layout:

```txt
ecommerce-app/
├── template.yaml # the SAM template
└──src
  ├── lambda_function.py # your handler
  └── requirements.txt # the X-Ray SDK dependency
```

lambda_function.py:

```python
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
```

Install SAM:

```sh
brew install aws-sam-cli
```

SAM Template:

```yaml
WSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: >
  E-commerce purchase demo: DynamoDB (CustomerPurchase) + SNS topic + a Lambda
  that queries a customer's purchases, filters by amount, and publishes the
  high-value ones to SNS. Exposed over an HTTP API. X-Ray tracing enabled.

Parameters:
  PurchaseThreshold:
    Type: String
    Default: '100'
    Description: Minimum purchase Amount forwarded to SNS.

Globals:
  Function:
    Runtime: python3.12
    Timeout: 15
    MemorySize: 128
    Tracing: Active          # X-Ray, matching patch_all() in the handler

Resources:
  CustomerPurchaseTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: CustomerPurchase
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: CustomerId
          AttributeType: S
        - AttributeName: PurchaseId
          AttributeType: S
      KeySchema:
        - AttributeName: CustomerId
          KeyType: HASH
        - AttributeName: PurchaseId
          KeyType: RANGE

  PurchaseTopic:
    Type: AWS::SNS::Topic

  ProcessPurchasesFn:
    Type: AWS::Serverless::Function
    Properties:
      Handler: lambda_function.lambda_handler
      CodeUri: ./
      Environment:
        Variables:
          SNS_TOPIC_ARN: !Ref PurchaseTopic
          PURCHASE_THRESHOLD: !Ref PurchaseThreshold
      Policies:
        - DynamoDBReadPolicy:
            TableName: !Ref CustomerPurchaseTable
        - SNSPublishMessagePolicy:
            TopicName: !GetAtt PurchaseTopic.TopicName
      Events:
        Api:
          Type: HttpApi
          Properties:
            Path: /process
            Method: get

  # ---- CloudWatch Synthetics canary probing the endpoint ----

  # S3 bucket the canary writes screenshots / HAR / logs to
  CanaryArtifactBucket:
    Type: AWS::S3::Bucket
    Properties:
      LifecycleConfiguration:
        Rules:
          - Id: expire-canary-artifacts
            Status: Enabled
            ExpirationInDays: 7
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true

  # The canary runs its OWN Lambda under this role — separate from the app function's role
  CanaryRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: canary-run
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow                       # write artifacts to the bucket
                Action: [s3:PutObject]
                Resource: !Sub "${CanaryArtifactBucket.Arn}/*"
              - Effect: Allow                       # discover the bucket location
                Action: [s3:GetBucketLocation]
                Resource: !GetAtt CanaryArtifactBucket.Arn
              - Effect: Allow                       # canary logs
                Action: [logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents]
                Resource: !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/cwsyn-*"
              - Effect: Allow                       # publish the CloudWatch metrics Synthetics emits
                Action: [cloudwatch:PutMetricData]
                Resource: '*'
                Condition:
                  StringEquals:
                    cloudwatch:namespace: CloudWatchSynthetics
              - Effect: Allow                       # X-Ray so the canary shows as Client::Synthetic
                Action: [xray:PutTraceSegments]
                Resource: '*'

  ProcessEndpointCanary:
    Type: AWS::Synthetics::Canary
    Properties:
      Name: process-endpoint
      RuntimeVersion: syn-python-selenium-4.1
      ArtifactS3Location: !Sub "s3://${CanaryArtifactBucket}"
      ExecutionRoleArn: !GetAtt CanaryRole.Arn
      StartCanaryAfterCreation: true
      Schedule:
        Expression: rate(5 minutes)
        DurationInSeconds: '0'          # run indefinitely on the schedule
      RunConfig:
        TimeoutInSeconds: 60
        ActiveTracing: true             # feeds the X-Ray service map
      Code:
        Handler: canary.handler
        Script: !Sub |
          import json
          from aws_synthetics.selenium import synthetics_webdriver as syn_webdriver
          from aws_synthetics.common import synthetics_logger as logger
          import urllib.request

          URL = "https://${ServerlessHttpApi}.execute-api.${AWS::Region}.amazonaws.com/process?customerId=1"

          def handler(event, context):
              logger.info("Probing %s", URL)
              req = urllib.request.Request(URL, method="GET")
              with urllib.request.urlopen(req, timeout=30) as resp:
                  status = resp.getcode()
                  body = resp.read().decode("utf-8")
              logger.info("status=%s body=%s", status, body)
              if status != 200:
                  raise Exception(f"Endpoint returned {status}")
              # confirm the JSON shape the function returns
              json.loads(body)
              return "ok"

Outputs:
  ApiUrl:
    Description: Public URL — call with ?customerId=<id>
    Value: !Sub "https://${ServerlessHttpApi}.execute-api.${AWS::Region}.amazonaws.com/process"
  FunctionName:
    Description: Lambda function name (for aws lambda invoke / logs)
    Value: !Ref ProcessPurchasesFn
  TableName:
    Value: !Ref CustomerPurchaseTable
  TopicArn:
    Description: SNS topic — subscribe an endpoint to actually receive notifications
    Value: !Ref PurchaseTopic
  CanaryName:
    Description: Synthetics canary probing /process every 5 min (view in CloudWatch → Synthetics)
    Value: !Ref ProcessEndpointCanary
  CanaryArtifacts:
    Value: !Ref CanaryArtifactBucket
```

requirements.txt

```txt
aws-xray-sdk==2.14.0
```

Deploy:

```sh
sam build --profile Walsen-Admin
sam deploy --guided --profile Walsen-Admin --region us-east-1
```

```sh
# seed a row
aws dynamodb put-item --table-name CustomerPurchase --profile Walsen-Admin --region us-east-1 \
  --item '{"CustomerId":{"S":"1"},"PurchaseId":{"S":"p-001"},"Amount":{"N":"150"},"Product":{"S":"Keyboard"}}'

# call the web endpoint
curl "https://<id>.execute-api.us-east-1.amazonaws.com/process?customerId=1"
```

Invoke:

```sh
sam remote invoke ProcessPurchasesFn --profile Walsen-Admin --region us-east-1
# or: aws lambda invoke --function-name <name-from-stack-output> out.json --profile Walsen-Admin --region us-east-1
```

To tear down everything:

```sh
sam delete --profile Walsen-Admin --region us-east-1
```

