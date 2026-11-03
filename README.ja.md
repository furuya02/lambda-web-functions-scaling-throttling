# lambda-web-functions-scaling-throttling

AWS Lambda Web Functions に I/O 待ち主体の負荷をかけ、実行環境がいくつ立つか・どこで 429 になるかを実測するサンプル

[English](README.md)

## 概要

指定した時間だけ待って返す擬似 LLM（`GET /wait?ms=N`）を Hono で 1 本書き、1 つの Web Function（maxConcurrencyPerEnvironment は既定の 64）に載せて、3 つのエンドポイントを付けます。

```
負荷スクリプト（手元の PC）
  └─ Web Function（maxConcurrencyPerEnvironment 64）
       ├─ prod    … maxEnvironments 10（環境がいくつ立つかを見る）
       ├─ maxenv2 … maxEnvironments 2（環境数の上限で 429 を出す）
       └─ rate100 … rateLimit 100 rps（毎秒のリクエスト数の上限で 429 を出す）
```

- maxEnvironments と rateLimit はエンドポイントの設定なので、同じ関数にエンドポイントを追加して上限に当てます
- systemLogLevel を DEBUG にして、リクエストごとの platform.requestComplete（result / errorType）をログに出しています

## 構成

| ディレクトリ | 内容 |
|---|---|
| app/ | Hono アプリ（app/src/index.ts）。esbuild で app/dist/index.js にまとめる |
| cdk/ | CDK（S3 バケット、ロググループ × 2、Web Function、リビジョン、エンドポイント × 3） |
| scripts/ | load.mjs（負荷）、run-all.sh（検証を順番に）、summarize.py（結果の集計）、metrics.sh（CloudWatch）、logs.sh（platform.* ログ） |

## 必要要件

- Node.js 22 以上 / pnpm
- AWS 認証情報（東京リージョン ap-northeast-1。CDK のブートストラップ済み）
- aws-cdk-lib 2.273.0 以上（Web Functions の L1 が含まれるバージョン）

## 構築手順

```bash
git clone https://github.com/furuya02/lambda-web-functions-scaling-throttling.git
cd lambda-web-functions-scaling-throttling

# アプリをビルド（app/dist/index.js が作られる）
pnpm -C app install
pnpm -C app build

# デプロイ（URL を cdk/outputs.json に保存する）
pnpm -C cdk install
pnpm -C cdk cdk deploy --outputs-file outputs.json
```

出力の Urlprod / Urlmaxenv2 / Urlrate100 を控えます。

- S3 バケット名のサフィックスは既定でアカウント ID です（`-c bucket_suffix=xxx` で変更）
- cdk synth で `Unknown resource type 'AWS::Lambda::WebFunction'` の警告が出ますが、デプロイには影響しません
- デプロイ前に `aws lambda-web get-web-account-settings` でアカウントの vCPU クォータを確認してください（新規アカウントは低く設定されています。maxEnvironments 10 = 20 vCPU）
- 関数を初めて動かしたときの挙動（環境あたり 2 件から始めて横に広がる）を見たい場合は、デプロイ後に動作確認の curl をせず、そのまま負荷をかけてください

## 動作確認

```bash
curl -i "<Urlprod>wait?ms=1000"
# {"ms":1000,"env":"6b4bbf51","inflight":1,"peak":1}
```

- env は実行環境（プロセス）ごとの識別子です。同じ値なら同じ実行環境で処理されています
- inflight はその環境が今処理中のリクエスト数、peak はその環境での最大値です
- 応答ヘッダーの lambda-web-logstream でも環境を特定できます。429 のときは lambda-web-error-type に原因が入ります

## 負荷のかけ方

```bash
# 同時 50 件、待ち 5 秒、36 ラウンド（closed-loop）
node scripts/load.mjs --url <Urlprod> --name n50 --concurrency 50 --ms 5000 --rounds 36

# 毎秒 300 件を 30 秒間、待ち 0（open-loop。rateLimit 100 に当てる）
node scripts/load.mjs --url <Urlrate100> --name rate100 --rps 300 --duration 30 --path /

# 初回実行: デプロイ直後の関数に同時 10 / 50 / 100 / 200 件を各 36 ラウンド（条件の間は 7 分待つ。Mac の sleep を防ぐため caffeinate 下で）
PHASE=first caffeinate -i scripts/run-all.sh cdk/outputs.json

# 定常: 一度動かした関数に同じ 4 条件 + maxenv2 に同時 200 件 + rate100 に毎秒 300 件
PHASE=steady caffeinate -i scripts/run-all.sh cdk/outputs.json

# 結果の集計（ラウンドごとの環境数、環境あたりの件数、status）
python3 scripts/summarize.py results/*.json

# 全エンドポイントを rateLimit 0 で遮断する（検証の合間に置いておくとき。503 Platform.EndpointDisabled になる）
cd cdk && pnpm exec cdk deploy -c disabled=true
```

結果は results/<name>_<開始時刻>.json に保存されます。summary に status / lambda-web-error-type / 環境ごとの件数 / 応答時間 p50・p95 が入ります。

## メトリクスとログの確認（読み取りのみ）

```bash
# EndpointActiveEnvironments、EnvironmentConcurrentRequests、各 Throttles を毎分で表示
scripts/metrics.sh prod 2026-11-03T12:00:00Z 2026-11-03T12:10:00Z

# .local ロググループから platform.* を時系列で表示（種類で絞り込み可）
scripts/logs.sh 2026-11-03T12:00:00Z 2026-11-03T12:10:00Z
scripts/logs.sh 2026-11-03T12:00:00Z 2026-11-03T12:10:00Z invokeSummary
```

## 後片付け

```bash
pnpm -C cdk cdk destroy
```

S3 バケット、ロググループ（.local を含む 2 つ）、Web Function、エンドポイントがすべて削除されます。
Web Functions はトラフィックが無いと実行環境が 0 になるので、放置しても環境の課金は発生しませんが、検証が終わったら destroy してください。

## ライセンス

MIT
