---
name: check-canary
description: Check the CloudWatch Synthetics canary that probes this workshop's /process endpoint. Use when the user asks about the canary, synthetics, endpoint monitoring, uptime, probe/heartbeat health, canary failures, or whether the site is up.
---

# Check the Synthetics canary

Report the health of the `process-endpoint` CloudWatch Synthetics canary that
probes the `observability-workshop-light` HTTP API (`/process`) every 5 minutes,
and diagnose any failures.

## Prerequisites

- The `awslabs.cloudwatch-applicationsignals-mcp-server` MCP server must be connected
  (configured in `.kiro/settings/mcp.json`, profile `Walsen`, region `us-east-1`).
  If its tools aren't available, tell the user to enable/reconnect that server and stop.
- The stack must be deployed. Stack name: `test-sam-deploy`. Region: `us-east-1`.
  The canary of interest is `process-endpoint`.

## Workflow

1. **List canaries.** Call `list_canaries` to confirm `process-endpoint` exists
   and read its current state (RUNNING / STOPPED / ERROR), schedule, runtime, and
   last-started time. If it isn't there, tell the user the canary isn't deployed
   and stop.

2. **Report status.** State plainly whether the canary is running and when it
   last ran. A canary probing every 5 minutes should have a recent last-run time;
   if the last run is stale (well over 5 minutes ago), call that out.

3. **Analyze failures.** Call `analyze_canary_failures(canary_name="process-endpoint")`
   to get pass/fail history and root-cause detail. Summarize:
   - recent success rate / whether it's currently passing or failing
   - for any failures: the root cause (HTTP status, exception, timeout, DNS, etc.)
     and the failing run's timestamp
   - artifacts (screenshots / HAR / logs) the analysis surfaced

4. **Correlate when it's failing.** If the canary is failing, the endpoint or the
   Lambda behind it is likely the cause. Cross-check the backing service
   (`test-sam-deploy-ProcessPurchasesFn-*`) with `audit_services` or the
   `show-traces` skill to see whether the Lambda is erroring or slow. Tie the
   canary failure to the underlying fault when you can.

5. **Summarize.** Give a short verdict: is monitoring green, and if not, what
   broke and where. Include the endpoint being probed
   (`/process?customerId=1`) for context.

## Notes

- The canary uses `urllib.request` against the public `/process` route and fails
  the run if the endpoint returns non-200 or the JSON body doesn't parse.
- Runtime is `syn-python-selenium-12.0`; canary `ActiveTracing` is `false`
  (newer Selenium runtimes don't support it), so don't expect canary spans in X-Ray.
- Report only what the tools return. If a value isn't available, say so rather
  than estimating.
