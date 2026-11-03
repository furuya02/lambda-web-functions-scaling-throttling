# lambda-web-functions-scaling-throttling

Sample to measure how many execution environments AWS Lambda Web Functions start under I/O-bound load, and where HTTP 429 begins

[日本語](README.ja.md)

## Overview

A single Hono app that waits for the requested time and returns (`GET /wait?ms=N`, a pseudo LLM) is deployed to one Web Function (maxConcurrencyPerEnvironment left at the default 64) with three endpoints.

```
Load script (your PC)
  └─ Web Function (maxConcurrencyPerEnvironment 64)
       ├─ prod    … maxEnvironments 10 (how many environments start)
       ├─ maxenv2 … maxEnvironments 2  (429 from the environment limit)
       └─ rate100 … rateLimit 100 rps  (429 from the request-rate limit)
```

- maxEnvironments and rateLimit are endpoint settings, so extra endpoints on the same function are used to hit those limits
- systemLogLevel is DEBUG so that platform.requestComplete (result / errorType) is logged per request

## Layout

| Directory | Contents |
|---|---|
| app/ | Hono app (app/src/index.ts), bundled by esbuild into app/dist/index.js |
| cdk/ | CDK (S3 bucket, 2 log groups, 1 Web Function, 1 revision, 3 endpoints) |
| scripts/ | load.mjs (load), run-all.sh (experiments in order), summarize.py (aggregate results), metrics.sh (CloudWatch), logs.sh (platform.* logs) |

## Requirements

- Node.js 22+ / pnpm
- AWS credentials (Tokyo region ap-northeast-1, CDK bootstrapped)
- aws-cdk-lib 2.273.0 or later (includes the Web Functions L1 constructs)

## Deploy

```bash
git clone https://github.com/furuya02/lambda-web-functions-scaling-throttling.git
cd lambda-web-functions-scaling-throttling

# Build the app (creates app/dist/index.js)
pnpm -C app install
pnpm -C app build

# Deploy (saves the URLs to cdk/outputs.json)
pnpm -C cdk install
pnpm -C cdk cdk deploy --outputs-file outputs.json
```

Note the outputs Urlprod / Urlmaxenv2 / Urlrate100.

- The S3 bucket name suffix defaults to the account ID (override with `-c bucket_suffix=xxx`)
- cdk synth prints `Unknown resource type 'AWS::Lambda::WebFunction'` warnings; they do not affect the deployment
- Before deploying, check your account vCPU quota with `aws lambda-web get-web-account-settings` (new accounts have reduced quotas; maxEnvironments 10 = 20 vCPUs)
- To observe the first-run behavior of a function (environments start at 2 requests each and spread out), do not curl the endpoint after deploying; start the load directly

## Verify

```bash
curl -i "<Urlprod>wait?ms=1000"
# {"ms":1000,"env":"6b4bbf51","inflight":1,"peak":1}
```

- env identifies the execution environment (process); the same value means the same environment
- inflight is the number of requests that environment is serving right now, peak is its maximum so far
- The lambda-web-logstream response header also identifies the environment; on 429 the lambda-web-error-type header names the limit

## Load

```bash
# 50 concurrent, 5 s wait, 36 rounds (closed-loop)
node scripts/load.mjs --url <Urlprod> --name n50 --concurrency 50 --ms 5000 --rounds 36

# 300 requests per second for 30 s, no wait (open-loop, hits rateLimit 100)
node scripts/load.mjs --url <Urlrate100> --name rate100 --rps 300 --duration 30 --path /

# First run: 10 / 50 / 100 / 200 concurrent for 36 rounds each on the freshly deployed function (7 min gap between conditions; caffeinate keeps the Mac awake)
PHASE=first caffeinate -i scripts/run-all.sh cdk/outputs.json

# Steady: the same 4 conditions on the exercised function, then 200 concurrent on maxenv2 and 300 rps on rate100
PHASE=steady caffeinate -i scripts/run-all.sh cdk/outputs.json

# Aggregate (environments per round, requests per environment, status)
python3 scripts/summarize.py results/*.json

# Disable all endpoints with rateLimit 0 between experiments (returns 503 Platform.EndpointDisabled)
cd cdk && pnpm exec cdk deploy -c disabled=true
```

Results are saved to results/<name>_<start>.json. The summary holds status counts, lambda-web-error-type counts, requests per environment and p50 / p95 latency.

## Metrics and logs (read-only)

```bash
# EndpointActiveEnvironments, EnvironmentConcurrentRequests and the throttle metrics per minute
scripts/metrics.sh prod 2026-11-03T12:00:00Z 2026-11-03T12:10:00Z

# platform.* system logs from the .local log group, in order (optionally filtered by type)
scripts/logs.sh 2026-11-03T12:00:00Z 2026-11-03T12:10:00Z
scripts/logs.sh 2026-11-03T12:00:00Z 2026-11-03T12:10:00Z invokeSummary
```

## Clean up

```bash
pnpm -C cdk cdk destroy
```

This removes the S3 bucket, both log groups (including .local), the Web Function and the endpoints.
Web Functions scale to zero environments without traffic, so nothing accrues while idle, but destroy the stack once you are done.

## License

MIT
