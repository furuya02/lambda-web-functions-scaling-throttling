#!/bin/bash
# 検証を順番に流す。条件の間は実行環境がゼロに戻るまで 7 分待つ（EndpointActiveEnvironments が混ざらないように）
# 使い方: caffeinate -i scripts/run-all.sh cdk/outputs.json
#   PHASE=first  … デプロイ直後（関数を一度も動かしていない状態）の 4 条件
#   PHASE=steady … 一度動かした後の 4 条件 + maxenv2 + rate100
set -eu
OUT=${1:-cdk/outputs.json}
PHASE=${PHASE:-first}
url() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['LambdaWebFunctionsScalingThrottling'][sys.argv[2]])" "$OUT" "$1"; }
GAP=${GAP:-420}
wait_gap() { echo "--- $(date -u +%H:%M:%SZ) wait ${GAP}s (環境がゼロに戻るまで) ---"; sleep "$GAP"; }

echo "--- $(date -u +%H:%M:%SZ) start PHASE=$PHASE ---"
# 1. 同時数ランプ（prod、待ち 5 秒、36 ラウンド = 約 3 分）
for N in 10 50 100 200; do
  node scripts/load.mjs --url "$(url Urlprod)" --name "n$N-$PHASE" --concurrency $N --ms 5000 --rounds 36
  wait_gap
done
if [ "$PHASE" = steady ]; then
  # 2. maxEnvironments 2 に同時 200
  node scripts/load.mjs --url "$(url Urlmaxenv2)" --name "maxenv2-n200" --concurrency 200 --ms 5000 --rounds 10
  wait_gap
  # 3. rateLimit 100 に 300 rps（待ち 0）
  node scripts/load.mjs --url "$(url Urlrate100)" --name "rate100-300rps" --rps 300 --duration 30 --path /
fi
echo "--- $(date -u +%H:%M:%SZ) done ---"
