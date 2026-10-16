// スケーリング検証用の擬似 LLM。指定した時間だけ待って返す（CPU はほとんど使わない I/O 待ち）
import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { randomUUID } from 'node:crypto'

// 実行環境（プロセス）の識別子。起動時に 1 回だけ作るので、同じ環境で処理されたリクエストは同じ値になる
const ENV_ID = randomUUID().slice(0, 8)
// この環境が今処理中のリクエスト数（1 環境に何件入っているかをアプリ側からも見る）
let inflight = 0
let peak = 0

const app = new Hono()

// rateLimit の試験用。待たずに返す
app.get('/', (c) => c.json({ env: ENV_ID, inflight }))

// GET /wait?ms=5000 → 5 秒待って返す
app.get('/wait', async (c) => {
  const ms = Number(c.req.query('ms') ?? 0)
  inflight++
  peak = Math.max(peak, inflight)
  try {
    await new Promise((r) => setTimeout(r, ms))
    return c.json({ ms, env: ENV_ID, inflight, peak })
  } finally {
    inflight--
  }
})

// Web Functions は AWS_LAMBDA_HTTP_ENDPOINT（host:port）で待ち受け先を渡してくる。ローカルは PORT（既定 8080）
const endpoint = process.env.AWS_LAMBDA_HTTP_ENDPOINT
const [hostname, port] = endpoint ? endpoint.split(':') : ['0.0.0.0', process.env.PORT ?? '8080']
serve({ fetch: app.fetch, hostname, port: Number(port) }, () => console.log(`listening on ${hostname}:${port} env=${ENV_ID}`))
