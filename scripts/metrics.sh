#!/bin/bash
# CloudWatch からスケーリングとスロットリングのメトリクスを取る（読み取りのみ）
# 使い方: scripts/metrics.sh <関数の同時数 1|16|64|128> <エンドポイント名> <開始 ISO8601 UTC> <終了 ISO8601 UTC>
#   例: scripts/metrics.sh 64 prod 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z
set -eu
C=$1; EP=$2; START=$3; END=$4
REGION=${AWS_REGION:-ap-northeast-1}
FN=lambda-web-functions-scaling-throttling-c$C
PERIOD=60

get() { # namespace metric stat dimensions...
  local ns=$1 metric=$2 stat=$3; shift 3
  aws cloudwatch get-metric-statistics --region "$REGION" --namespace "$ns" --metric-name "$metric" \
    --start-time "$START" --end-time "$END" --period $PERIOD --statistics "$stat" --dimensions "$@" \
    --query "sort_by(Datapoints,&Timestamp)[].[Timestamp,$stat]" --output text
}
show() { awk '{printf "    %s %s\n", substr($1,12,8), $2}'; }

FD=Name=FunctionName,Value=$FN
ED="$FD Name=EndpointName,Value=$EP"
UD="$ED Name=ExecutionRegion,Value=$REGION"

echo "== $FN / $EP  $START .. $END =="
echo "EndpointActiveEnvironments (Max, 毎分)";            get AWS/Lambda/Web/Usage EndpointActiveEnvironments Maximum $UD | show
echo "EnvironmentConcurrentRequests (Max, 毎分, 関数全体)"; get AWS/Lambda/Web EnvironmentConcurrentRequests Maximum $FD | show
echo "ExecutedRequests (Sum)";                            get AWS/Lambda/Web ExecutedRequests Sum $ED | show
echo "HTTPResponseStatusClass4XX (Sum)";                  get AWS/Lambda/Web HTTPResponseStatusClass4XX Sum $ED | show
echo "HTTPResponseStatusClass5XX (Sum)";                  get AWS/Lambda/Web HTTPResponseStatusClass5XX Sum $ED | show
for M in EndpointRequestThrottles EndpointActiveEnvironmentThrottles AccountRequestThrottles AccountActiveVCPUArm64Throttles; do
  echo "$M (Sum)"; get AWS/Lambda/Web/Usage $M Sum $UD | show
done
echo "EnvironmentActiveTime (Sum ms)"; get AWS/Lambda/Web EnvironmentActiveTime Sum $FD | awk '{s+=$2} END {printf "    %.0f\n", s}'
