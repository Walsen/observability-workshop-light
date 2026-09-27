---
name: console-links
description: Print the AWS console URLs (X-Ray trace map, X-Ray faults, Synthetics canary, Lambda logs, Lambda monitoring) for the deployed observability-workshop-light stack. Use when the user asks where to view failures/traces/logs in the console, wants the console links, or asks to "show me in X-Ray / Synthetics".
---

# Print observability console links

Give the user direct AWS console URLs for the `observability-workshop-light`
stack so they can view failures, traces, canary runs, and logs.

## How to produce the links

Run the justfile recipe, which resolves the account/region/function/canary from
the live stack so the links are always correct for the current deployment:

```sh
just console-urls
```

Present its output as a tidy list of clickable links. If the recipe reports the
stack isn't deployed, tell the user to deploy first (`just ship`) and stop —
don't hand-build URLs against a stack that doesn't exist.

## What the links are

- **X-Ray trace map** — the service map; failing nodes show ringed in red
- **X-Ray faults** — trace list; apply the filter `fault = true` to see only faults
- **Synthetics canary** — the `process-endpoint` canary detail (runs, screenshots, success rate)
- **Lambda logs** — the function's CloudWatch log group (exceptions + stack traces)
- **Lambda monitoring** — the function's Errors/Duration/Invocations graphs

## Notes

- Region defaults to `us-east-1`; the recipe reads the real function name from
  the stack outputs, so links stay valid across redeploys even though the
  function's physical name changes.
- If Transaction Search isn't enabled, the X-Ray console still shows sampled
  (≈5%) faulted traces — the links are valid regardless.
- Report only the links the recipe returns; don't invent console paths.
