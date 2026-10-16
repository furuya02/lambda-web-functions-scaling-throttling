# lambda-web-functions-scaling-throttling

Sample to measure how many execution environments AWS Lambda Web Functions start under I/O-bound load, and where HTTP 429 begins

[日本語](README.ja.md)

## Overview

A single Hono app that waits for the requested time and returns (`GET /wait?ms=N`, a pseudo LLM) is deployed to four Web Functions that differ only in maxConcurrencyPerEnvironment.

```
Load script (your PC)
  ├─ c1   … maxConcurrencyPerEnvironment 1   / prod    (maxEnvironments 10)
  ├─ c16  … maxConcurrencyPerEnvironment 16  / prod    (maxEnvironments 10)
  ├─ c64  … maxConcurrencyPerEnvironment 64  / prod    (maxEnvironments 10)
  │                                           / maxenv2 (maxEnvironments 2)
  │                                           / rate100 (rateLimit 100 rps)
  └─ c128 … maxConcurrencyPerEnvironment 128 / prod    (maxEnvironments 10)
```

- maxConcurrencyPerEnvironment is a revision setting and environment metrics are per function, so each condition gets its own Web Function
- maxEnvironments and rateLimit are endpoint settings, so c64 gets extra endpoints to hit those limits
- systemLogLevel is DEBUG so that platform.requestComplete (result / errorType) is logged per request

## Layout

| Directory | Contents |
|---|---|
| app/ | Hono app (app/src/index.ts), bundled by esbuild into app/dist/index.js |
| cdk/ | CDK (S3 bucket, 8 log groups, 4 Web Functions, 4 revisions, 6 endpoints) |
| scripts/ | load.mjs (load), run-all.sh (all experiments in order), summarize.py (aggregate results), metrics.sh (CloudWatch), logs.sh (platform.* logs) |

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

Note the outputs UrlC1prod / UrlC16prod / UrlC64prod / UrlC64maxenv2 / UrlC64rate100 / UrlC128prod.

- The S3 bucket name suffix defaults to the account ID (override with `-c bucket_suffix=xxx`)
- cdk synth prints `Unknown resource type 'AWS::Lambda::WebFunction'` warnings; they do not affect the deployment
- Before deploying, check your account vCPU quota with `aws lambda-web get-web-account-settings` (new accounts have reduced quotas; maxEnvironments 10 = 20 vCPUs)

## Verify

```bash
curl -i "<UrlC64prod>wait?ms=1000"
# {"ms":1000,"env":"6b4bbf51","inflight":1,"peak":1}
```

- env identifies the execution environment (process); the same value means the same environment
- inflight is the number of requests that environment is serving right now, peak is its maximum so far
- The lambda-web-logstream response header also identifies the environment; on 429 the lambda-web-error-type header names the limit

## Load

```bash
# 50 concurrent, 5 s wait, 10 rounds (closed-loop)
node scripts/load.mjs --url <UrlC64prod> --name c64-n50 --concurrency 50 --ms 5000 --rounds 10

# 300 requests per second for 30 s, no wait (open-loop, hits rateLimit 100)
node scripts/load.mjs --url <UrlC64rate100> --name rate100 --rps 300 --duration 30 --path /

# Run experiments 1-6 in order (10 min gap between conditions; caffeinate keeps the Mac awake)
caffeinate -i scripts/run-all.sh cdk/outputs.json
```

Results are saved to results/<name>_<start>.json. The summary holds status counts, lambda-web-error-type counts, requests per environment and p50 / p95 latency.

## Metrics and logs (read-only)

```bash
# EndpointActiveEnvironments, EnvironmentConcurrentRequests and the throttle metrics per minute
scripts/metrics.sh 64 prod 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z

# platform.* system logs from the .local log group, in order (optionally filtered by type)
scripts/logs.sh 64 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z
scripts/logs.sh 64 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z invokeSummary
```

## Clean up

```bash
pnpm -C cdk cdk destroy
```

This removes the S3 bucket, all 8 log groups (including .local), the Web Functions and the endpoints.
Web Functions scale to zero environments without traffic, so nothing accrues while idle, but destroy the stack once you are done.

## License

MIT
