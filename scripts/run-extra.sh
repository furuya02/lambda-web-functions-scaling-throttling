#!/bin/bash
# 追加検証: 小さな負荷での環境数。環境ゼロからの一斉到着と、環境 1 つがある状態からの違いを見る
# 使い方: caffeinate -i scripts/run-extra.sh cdk/outputs.json
set -eu
OUT=${1:-cdk/outputs.json}
URL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['LambdaWebFunctionsScalingThrottling']['UrlC64prod'])" "$OUT")
GAP=${GAP:-420}
wait_gap() { echo "--- $(date -u +%H:%M:%SZ) wait ${GAP}s ---"; sleep "$GAP"; }

# 前の負荷の環境が消えるのを待つ
wait_gap
# A. 環境ゼロから同時 10 件（昨日の再現）
node scripts/load.mjs --url "$URL" --name "c64-n10-cold" --concurrency 10 --ms 5000 --rounds 20
wait_gap
# B. 環境 1 つを作ってから同時 10 件
curl -s "$URL" > /dev/null; sleep 3
node scripts/load.mjs --url "$URL" --name "c64-n10-warm" --concurrency 10 --ms 5000 --rounds 20
wait_gap
# C. 環境ゼロから同時 2 件を 3 分
node scripts/load.mjs --url "$URL" --name "c64-n2-cold" --concurrency 2 --ms 5000 --rounds 36
wait_gap
# D. 環境ゼロから同時 4 件を 3 分
node scripts/load.mjs --url "$URL" --name "c64-n4-cold" --concurrency 4 --ms 5000 --rounds 36
echo "--- $(date -u +%H:%M:%SZ) done ---"
