# observability-workshop-light — task runner
# Run `just` or `just --list` to see all recipes.

# --- config (override on the command line, e.g. `just stack=my-stack deploy`) ---
stack := "test-sam-deploy"
region := "us-east-1"
table := "CustomerPurchase"
canary := "process-endpoint"

# default: show the task list
default:
    @just --list

# ---- environment ----

# Create the python3.12 venv with pip that `sam build` needs
venv:
    python3.12 -m venv .venv
    .venv/bin/python -m pip --version

# ---- build & deploy ----

# Build the SAM app (needs .venv active for a pip-enabled python3.12)
build:
    sam build

# First deploy (interactive; saves answers to samconfig.toml)
deploy-guided:
    sam deploy --guided

# Redeploy using saved samconfig.toml
deploy:
    sam deploy

# Build then deploy in one step
ship: build deploy

# ---- discovery ----

# Print the full API URL from the stack outputs
url:
    @aws cloudformation describe-stacks --stack-name {{stack}} --region {{region}} \
      --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text

# Print just the api-id (subdomain of the API URL)
api-id:
    @aws cloudformation describe-stacks --stack-name {{stack}} --region {{region}} \
      --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text \
      | sed -E 's#https://([^.]+)\..*#\1#'

# Show all stack outputs (ApiUrl, FunctionName, TableName, TopicArn, canary, bucket)
outputs:
    @aws cloudformation describe-stacks --stack-name {{stack}} --region {{region}} \
      --query "Stacks[0].Outputs" --output table

# Show the stack status
status:
    @aws cloudformation describe-stacks --stack-name {{stack}} --region {{region}} \
      --query "Stacks[0].StackStatus" --output text

# Print CloudWatch/X-Ray/Synthetics console URLs for the deployed stack
console-urls:
    #!/usr/bin/env bash
    set -euo pipefail
    r="{{region}}"
    fn=$(aws cloudformation describe-stacks --stack-name {{stack}} --region "$r" \
      --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue" --output text 2>/dev/null || true)
    if [ -z "${fn:-}" ] || [ "$fn" = "None" ]; then
        echo "Stack '{{stack}}' not found in $r — deploy it first (just ship)." >&2
        exit 1
    fi
    lg="/aws/lambda/${fn}"
    # URL-encode the log group ($ -> $25xx) for the Logs console deep link
    lg_enc=$(printf '%s' "$lg" | sed 's#/#$252F#g')
    base="https://${r}.console.aws.amazon.com/cloudwatch/home?region=${r}"
    echo "Observability consoles for {{stack}} ($r):"
    echo ""
    echo "  X-Ray trace map:    ${base}#xray:traces/map"
    echo "  X-Ray faults:       ${base}#xray:traces/query \\"
    echo "                      (filter: fault = true)"
    echo "  Synthetics canary:  ${base}#synthetics:canary/detail/{{canary}}"
    echo "  Lambda logs:        ${base}#logsV2:log-groups/log-group/${lg_enc}"
    echo "  Lambda monitoring:  https://${r}.console.aws.amazon.com/lambda/home?region=${r}#/functions/${fn}?tab=monitoring"

# ---- data seeding ----

# Seed a high-value purchase (Amount 150 >= threshold -> triggers SNS publish)
seed-high:
    aws dynamodb put-item --table-name {{table}} --region {{region}} \
      --item '{"CustomerId":{"S":"1"},"PurchaseId":{"S":"p-high"},"Amount":{"N":"150"},"Product":{"S":"Keyboard"}}'

# Seed a low-value purchase (Amount 20 < threshold -> filtered out, no SNS)
seed-low:
    aws dynamodb put-item --table-name {{table}} --region {{region}} \
      --item '{"CustomerId":{"S":"1"},"PurchaseId":{"S":"p-low"},"Amount":{"N":"20"},"Product":{"S":"Pen"}}'

# Seed both a high- and low-value row
seed: seed-high seed-low

# Count rows in the table
count:
    @aws dynamodb scan --table-name {{table}} --region {{region}} --select COUNT --output json

# Delete the seeded rows
unseed:
    -aws dynamodb delete-item --table-name {{table}} --region {{region}} \
      --key '{"CustomerId":{"S":"1"},"PurchaseId":{"S":"p-high"}}'
    -aws dynamodb delete-item --table-name {{table}} --region {{region}} \
      --key '{"CustomerId":{"S":"1"},"PurchaseId":{"S":"p-low"}}'

# ---- testing the endpoint ----

# Call the /process endpoint once (customerId defaults to 1)
call customerId="1":
    curl -s "$(just url)?customerId={{customerId}}" && echo

# Hammer the endpoint N times (default 10) to generate traces
load n="10":
    #!/usr/bin/env bash
    set -euo pipefail
    api="$(just url)"
    for i in $(seq 1 {{n}}); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "${api}?customerId=1")
        echo "request $i -> HTTP $code"
    done

# Invoke the Lambda directly (bypasses the API)
invoke:
    sam remote invoke ProcessPurchasesFn --region {{region}}

# ---- observability ----

# Show the canary's current state and last run
canary-status:
    @aws synthetics get-canary --name {{canary}} --region {{region}} \
      --query "Canary.{State:Status.State,LastRun:Timeline.LastStarted}" --output table

# List recent Lambda log events (last 10 min)
logs:
    sam logs --stack-name {{stack}} --region {{region}} --start-time '10min ago'

# ---- failure scenarios ----
# Each `break-*` redeploys the function with a fault toggle; `fix` restores
# safe defaults. After breaking, drive traffic (`just load`) or wait for the
# canary, then inspect with the show-traces / check-canary skills.
# These use --parameter-overrides + --no-confirm-changeset for a hands-off deploy.

_deploy-params params:
    sam deploy --stack-name {{stack}} --region {{region}} \
      --no-confirm-changeset --no-fail-on-empty-changeset \
      --parameter-overrides {{params}}

# Break DynamoDB: point the function at a non-existent table (X-Ray fault on the DDB subsegment)
break-table:
    @just _deploy-params "TableNameOverride=NoSuchTable-{{stack}}"
    @echo "Broken: function now reads a non-existent table. Run `just load` then check traces."

# Break with a forced exception on every call (clean 500 fault, red canary)
break-exception:
    @just _deploy-params "FailMode=exception"
    @echo "Broken: function raises on every call. Run `just load` then check traces / canary."

# Inject latency (default 20s > 15s Lambda timeout -> timeout errors)
break-latency seconds="20":
    @just _deploy-params "InjectLatencySeconds={{seconds}}"
    @echo "Broken: {{seconds}}s latency injected. Run `just load` then check traces / canary."

# Restore safe defaults (clears all failure toggles)
fix:
    sam deploy --stack-name {{stack}} --region {{region}} \
      --no-confirm-changeset --no-fail-on-empty-changeset \
      --parameter-overrides 'TableNameOverride=""' 'FailMode=""' 'InjectLatencySeconds=0'
    @echo "Fixed: failure toggles cleared. Give the canary a few minutes to go green."

# ---- teardown ----

# Empty the canary artifact S3 bucket (required before stack delete)
empty-bucket:
    #!/usr/bin/env bash
    set -euo pipefail
    bucket=$(aws cloudformation describe-stack-resources --stack-name {{stack}} --region {{region}} \
      --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" --output text)
    if [ -n "$bucket" ]; then
        echo "Emptying s3://$bucket ..."
        aws s3 rm "s3://$bucket" --recursive
    else
        echo "No bucket found in stack."
    fi

# Empty the bucket, then delete the whole stack
teardown: empty-bucket
    sam delete --stack-name {{stack}} --region {{region}}

# Remove local build/venv artifacts
clean:
    -chmod -R u+w .aws-sam 2>/dev/null || true
    rm -rf .aws-sam .venv
