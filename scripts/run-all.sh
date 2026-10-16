#!/bin/bash
# 検証 1〜6 を順番に流す。条件の間は実行環境がゼロに戻るまで 10 分待つ（EndpointActiveEnvironments が混ざらないように）
# 使い方: caffeinate -i scripts/run-all.sh cdk/outputs.json
set -eu
OUT=${1:-cdk/outputs.json}
url() { python3 -c "import json,sys;print([v for k,v in json.load(open(sys.argv[1]))['LambdaWebFunctionsScalingThrottling'].items() if k.startswith(sys.argv[2])][0])" "$OUT" "$1"; }
GAP=${GAP:-600}
wait_gap() { echo "--- wait ${GAP}s (環境がゼロに戻るまで) ---"; sleep "$GAP"; }

# 1. 同時数ランプ（c64 / prod）
for N in 10 50 100 200; do
  node scripts/load.mjs --url "$(url UrlC64prod)" --name "c64-n$N" --concurrency $N --ms 5000 --rounds 10
  wait_gap
done
# 2. 環境あたり上限の比較（同時 50）
for C in 1 16 128; do
  node scripts/load.mjs --url "$(url UrlC${C}prod)" --name "c$C-n50" --concurrency 50 --ms 5000 --rounds 10
  wait_gap
done
# 3. maxEnvironments 2 に同時 200
node scripts/load.mjs --url "$(url UrlC64maxenv2)" --name "maxenv2-n200" --concurrency 200 --ms 5000 --rounds 10
wait_gap
# 4. rateLimit 100 に 300 rps（待ち 0）
node scripts/load.mjs --url "$(url UrlC64rate100)" --name "rate100-300rps" --rps 300 --duration 30 --path /
wait_gap
# 5. 動的上限の頭打ち（c128 に同時 200、待ち 20 秒）
node scripts/load.mjs --url "$(url UrlC128prod)" --name "c128-n200-20s" --concurrency 200 --ms 20000 --rounds 5
wait_gap
# 6. 同時初期化（c1 に同時 200、待ち 1 秒）
node scripts/load.mjs --url "$(url UrlC1prod)" --name "c1-n200-1s" --concurrency 200 --ms 1000 --rounds 3
