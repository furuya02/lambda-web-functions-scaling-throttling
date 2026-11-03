#!/bin/bash
# 再計測: 一度動かした（受け入れ数を学習済みの）c64 に同時 10 / 50 / 100 / 200 件を各 36 ラウンド（約 3 分）。条件間は環境がゼロに戻るまで待つ
# 使い方: caffeinate -i scripts/run-steady.sh cdk/outputs.json
set -eu
OUT=${1:-cdk/outputs.json}
URL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['LambdaWebFunctionsScalingThrottling']['UrlC64prod'])" "$OUT")
GAP=${GAP:-420}
for N in 10 50 100 200; do
  node scripts/load.mjs --url "$URL" --name "c64-n$N-steady" --concurrency $N --ms 5000 --rounds 36
  echo "--- $(date -u +%H:%M:%SZ) wait ${GAP}s ---"; sleep "$GAP"
done
echo "--- $(date -u +%H:%M:%SZ) done ---"
