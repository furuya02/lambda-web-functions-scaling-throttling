# lambda-web-functions-scaling-throttling

AWS Lambda Web Functions に I/O 待ち主体の負荷をかけ、実行環境がいくつ立つか・どこで 429 になるかを実測するサンプル

[English](README.md)

## 概要

指定した時間だけ待って返す擬似 LLM（`GET /wait?ms=N`）を Hono で 1 本書き、maxConcurrencyPerEnvironment の異なる 4 つの Web Function に同じコードを載せます。

```
負荷スクリプト（手元の PC）
  ├─ c1   … maxConcurrencyPerEnvironment 1   / prod（maxEnvironments 10）
  ├─ c16  … maxConcurrencyPerEnvironment 16  / prod（maxEnvironments 10）
  ├─ c64  … maxConcurrencyPerEnvironment 64  / prod（maxEnvironments 10）
  │                                           / maxenv2（maxEnvironments 2）
  │                                           / rate100（rateLimit 100 rps）
  └─ c128 … maxConcurrencyPerEnvironment 128 / prod（maxEnvironments 10）
```

- maxConcurrencyPerEnvironment はリビジョンの設定で、環境メトリクスは関数単位なので、条件ごとに Web Function を分けています
- maxEnvironments と rateLimit はエンドポイントの設定なので、c64 にエンドポイントを追加して上限に当てます
- systemLogLevel を DEBUG にして、リクエストごとの platform.requestComplete（result / errorType）をログに出しています

## 構成

| ディレクトリ | 内容 |
|---|---|
| app/ | Hono アプリ（app/src/index.ts）。esbuild で app/dist/index.js にまとめる |
| cdk/ | CDK（S3 バケット、ロググループ × 8、Web Function × 4、リビジョン × 4、エンドポイント × 6） |
| scripts/ | load.mjs（負荷）、run-all.sh（全検証を順番に）、run-extra.sh（小さな負荷の追加検証）、run-steady.sh（学習済み関数での再計測）、summarize.py（結果の集計）、metrics.sh（CloudWatch）、logs.sh（platform.* ログ） |

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

出力の UrlC1prod / UrlC16prod / UrlC64prod / UrlC64maxenv2 / UrlC64rate100 / UrlC128prod を控えます。

- S3 バケット名のサフィックスは既定でアカウント ID です（`-c bucket_suffix=xxx` で変更）
- cdk synth で `Unknown resource type 'AWS::Lambda::WebFunction'` の警告が出ますが、デプロイには影響しません
- デプロイ前に `aws lambda-web get-web-account-settings` でアカウントの vCPU クォータを確認してください（新規アカウントは低く設定されています。maxEnvironments 10 = 20 vCPU）

## 動作確認

```bash
curl -i "<UrlC64prod>wait?ms=1000"
# {"ms":1000,"env":"6b4bbf51","inflight":1,"peak":1}
```

- env は実行環境（プロセス）ごとの識別子です。同じ値なら同じ実行環境で処理されています
- inflight はその環境が今処理中のリクエスト数、peak はその環境での最大値です
- 応答ヘッダーの lambda-web-logstream でも環境を特定できます。429 のときは lambda-web-error-type に原因が入ります

## 負荷のかけ方

```bash
# 同時 50 件、待ち 5 秒、10 ラウンド（closed-loop）
node scripts/load.mjs --url <UrlC64prod> --name c64-n50 --concurrency 50 --ms 5000 --rounds 10

# 毎秒 300 件を 30 秒間、待ち 0（open-loop。rateLimit 100 に当てる）
node scripts/load.mjs --url <UrlC64rate100> --name rate100 --rps 300 --duration 30 --path /

# 検証 1〜6 を順番に流す（条件の間は 10 分待つ。Mac の sleep を防ぐため caffeinate 下で）
caffeinate -i scripts/run-all.sh cdk/outputs.json

# 追加検証: 小さな負荷での環境数（同時 10 件を 5 分、環境ゼロからの同時 2 / 4 / 10 件）
caffeinate -i scripts/run-extra.sh cdk/outputs.json

# 再計測: 一度動かした c64 に同時 10 / 50 / 100 / 200 件を各 36 ラウンド（約 3 分）
caffeinate -i scripts/run-steady.sh cdk/outputs.json

# 全エンドポイントを rateLimit 0 で遮断する（検証の合間に置いておくとき。503 Platform.EndpointDisabled になる）
cd cdk && pnpm exec cdk deploy -c disabled=true
```

結果は results/<name>_<開始時刻>.json に保存されます。summary に status / lambda-web-error-type / 環境ごとの件数 / 応答時間 p50・p95 が入ります。

## メトリクスとログの確認（読み取りのみ）

```bash
# EndpointActiveEnvironments、EnvironmentConcurrentRequests、各 Throttles を毎分で表示
scripts/metrics.sh 64 prod 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z

# .local ロググループから platform.* を時系列で表示（種類で絞り込み可）
scripts/logs.sh 64 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z
scripts/logs.sh 64 2026-10-17T03:00:00Z 2026-10-17T03:10:00Z invokeSummary
```

## 後片付け

```bash
pnpm -C cdk cdk destroy
```

S3 バケット、ロググループ（.local を含む 8 つ）、Web Function、エンドポイントがすべて削除されます。
Web Functions はトラフィックが無いと実行環境が 0 になるので、放置しても環境の課金は発生しませんが、検証が終わったら destroy してください。

## ライセンス

MIT
