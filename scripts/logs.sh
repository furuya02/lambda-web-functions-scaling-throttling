#!/bin/bash
# .local ロググループから platform.* のシステムログを取り、環境ごとの初期化・毎分サマリ・終了を時系列で出す（読み取りのみ）
# 使い方: scripts/logs.sh <関数の同時数 1|16|64|128> <開始 ISO8601 UTC> <終了 ISO8601 UTC> [initStart|invokeSummary|invokeReport|spinDownStart|requestComplete]
set -eu
C=$1; START=$2; END=$3; TYPE=${4:-}
REGION=${AWS_REGION:-ap-northeast-1}
LG=/aws/lambda/web/lambda-web-functions-scaling-throttling-c$C.local
S=$(python3 -c "import datetime,sys;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()*1000))" "$START")
E=$(python3 -c "import datetime,sys;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()*1000))" "$END")
FILTER='{ $.type = "platform.*" }'
[ -n "$TYPE" ] && FILTER="{ \$.type = \"platform.$TYPE\" }"
aws logs filter-log-events --region "$REGION" --log-group-name "$LG" --start-time "$S" --end-time "$E" \
  --filter-pattern "$FILTER" --query 'events[].message' --output text \
  | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    r = e.get("record", {})
    print(e["timestamp"][11:23], e["type"].replace("platform.", ""), r.get("instanceId", "")[:8], json.dumps(r.get("metrics", r.get("result", "")), ensure_ascii=False), r.get("errorType", ""))
'
