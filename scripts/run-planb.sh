#!/bin/bash
# 同じ 6 つの負荷を 2 つの状態でかける
#   fresh   … 作った直後。学習した値は同じ関数のエンドポイント間で共有されるので、負荷 1 つごとにスタックを作り直す
#   learned … 一度動かした後。prod に同時 10 件を約 3 分流してから、負荷ごとに 7 分空けて実行環境がゼロに戻ってから流す
# 使い方: caffeinate -i scripts/run-planb.sh [fresh|learned|all]
set -eu
STATE=${1:-all}
OUT=cdk/outputs.json
GAP=${GAP:-420}
LOADS=${LOADS:-"n10 n50 n100 n200 maxenv2 rate100"}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
url() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['LambdaWebFunctionsScalingThrottling'][sys.argv[2]])" "$OUT" "$1"; }
load() { # $1=負荷 $2=名前の接頭辞
  case $1 in
    n*)      node scripts/load.mjs --url "$(url Urlprod)" --name "$2-$1" --concurrency "${1#n}" --ms 5000 --rounds 36 ;;
    maxenv2) node scripts/load.mjs --url "$(url Urlmaxenv2)" --name "$2-maxenv2-n200" --concurrency 200 --ms 5000 --rounds 36 ;;
    rate100) node scripts/load.mjs --url "$(url Urlrate100)" --name "$2-rate100-300rps" --rps 300 --duration 30 --path / ;;
  esac
}

if [ "$STATE" = fresh ] || [ "$STATE" = all ]; then
  for L in $LOADS; do
    echo "--- $(now) fresh $L: destroy ---"
    pnpm -C cdk exec cdk destroy -f > /dev/null
    # destroy の直後も旧環境がログを書き、Lambda が .local ロググループを作り直すことがある（deploy が already exists で失敗する）ので消しておく
    sleep 30
    for G in /aws/lambda/web/lambda-web-functions-scaling-throttling /aws/lambda/web/lambda-web-functions-scaling-throttling.local; do
      aws logs delete-log-group --log-group-name "$G" 2>/dev/null || true
    done
    echo "--- $(now) fresh $L: deploy ---"
    pnpm -C cdk exec cdk deploy --require-approval never --outputs-file outputs.json > /dev/null
    S=$(now)
    echo "--- $S fresh $L: load ---"
    load "$L" fresh
    sleep 90 # ログが出そろうのを待ってから、destroy で消える前に保存する
    scripts/logs.sh "$S" "$(now)" > "results/fresh-$L.log" || true
  done
fi

if [ "$STATE" = learned ] || [ "$STATE" = all ]; then
  LOADS=${LEARNED_LOADS:-"n10 n50 n100 n200 maxenv2 rate100"}
  LS=$(now)
  echo "--- $LS learned: warm-up ---"
  load n10 warmup
  for L in $LOADS; do
    echo "--- $(now) wait ${GAP}s ---"; sleep "$GAP"
    echo "--- $(now) learned $L: load ---"
    load "$L" learned
  done
  sleep 90
  scripts/logs.sh "$LS" "$(now)" > results/learned.log || true
fi

echo "--- $(now) disable ---"
pnpm -C cdk exec cdk deploy -c disabled=true --require-approval never --outputs-file outputs.json > /dev/null
echo "--- $(now) done ---"
