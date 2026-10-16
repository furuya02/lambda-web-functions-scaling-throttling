// 負荷スクリプト。同時数を固定して待ち（closed-loop）か、毎秒 N 件を発射（open-loop）する
//   closed-loop: node scripts/load.mjs --url https://xxx/ --name c64-n50 --concurrency 50 --ms 5000 --rounds 10
//   open-loop:   node scripts/load.mjs --url https://xxx/ --name rate100 --rps 300 --duration 30 --path /
// 結果は results/<name>_<開始時刻>.json。status / lambda-web-error-type / 環境ごとの件数と応答時間 p50 / p95 を集計する
import { mkdirSync, writeFileSync } from 'node:fs'

const arg = (k, d) => {
  const i = process.argv.indexOf(`--${k}`)
  return i >= 0 ? process.argv[i + 1] : d
}
const url = arg('url')
const name = arg('name', 'run')
const ms = Number(arg('ms', 5000))
const concurrency = Number(arg('concurrency', 1))
const rounds = Number(arg('rounds', 1))
const interval = Number(arg('interval', 0)) // ラウンド開始の間隔（ms）。0 なら前のラウンドが終わり次第
const rps = Number(arg('rps', 0)) // 0 より大きければ open-loop
const duration = Number(arg('duration', 30)) // open-loop の秒数
const path = arg('path', `/wait?ms=${ms}`)
if (!url) throw new Error('--url が必要です')

const sleep = (t) => new Promise((r) => setTimeout(r, t))
const results = []

const one = async (round, i) => {
  const start = Date.now()
  try {
    const res = await fetch(`${url.replace(/\/$/, '')}${path}`)
    const text = await res.text()
    let body = {}
    try { body = JSON.parse(text) } catch { body = { text: text.slice(0, 200) } }
    results.push({
      round, i, start, end: Date.now(), status: res.status,
      env: body.env, inflight: body.inflight,
      logstream: res.headers.get('lambda-web-logstream'),
      errorType: res.headers.get('lambda-web-error-type'),
      requestId: res.headers.get('lambda-web-request-id'),
    })
  } catch (e) {
    results.push({ round, i, start, end: Date.now(), status: 0, error: String(e) })
  }
}

const began = Date.now()
if (rps > 0) {
  // open-loop: 応答を待たず、1 秒を rps 等分して発射し続ける
  const pending = []
  const gap = 1000 / rps
  const until = began + duration * 1000
  let n = 0
  while (Date.now() < until) {
    const due = began + n * gap
    const wait = due - Date.now()
    if (wait > 0) await sleep(wait)
    pending.push(one(Math.floor((Date.now() - began) / 1000), n++))
    if (n % rps === 0) {
      const sec = results.filter((x) => x.round === Math.floor((Date.now() - began) / 1000) - 1)
      const codes = sec.reduce((a, x) => ((a[x.status] = (a[x.status] ?? 0) + 1), a), {})
      console.log(`[${name}] t=${Math.floor((Date.now() - began) / 1000)}s sent=${n} done=${results.length} status=${JSON.stringify(codes)}`)
    }
  }
  await Promise.all(pending)
} else {
  for (let r = 0; r < rounds; r++) {
    const roundStart = Date.now()
    await Promise.all(Array.from({ length: concurrency }, (_, i) => one(r, i)))
    const rr = results.filter((x) => x.round === r)
    const envs = new Set(rr.map((x) => x.env).filter(Boolean))
    const codes = rr.reduce((a, x) => ((a[x.status] = (a[x.status] ?? 0) + 1), a), {})
    const lat = rr.map((x) => x.end - x.start).sort((a, b) => a - b)
    console.log(`[${name}] round ${r + 1}/${rounds} ${Date.now() - roundStart} ms envs=${envs.size} status=${JSON.stringify(codes)} p50=${pct(lat, 50)} p95=${pct(lat, 95)} max=${lat.at(-1)}`)
    if (interval > 0 && r < rounds - 1) await sleep(Math.max(0, interval - (Date.now() - roundStart)))
  }
}

function pct(sorted, p) {
  if (!sorted.length) return 0
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)]
}
const count = (key) => results.reduce((a, x) => { const k = x[key] ?? '-'; a[k] = (a[k] ?? 0) + 1; return a }, {})
const okLat = results.filter((x) => x.status === 200).map((x) => x.end - x.start).sort((a, b) => a - b)

const summary = {
  name, url, path, ms, concurrency, rounds, interval, rps, duration,
  began: new Date(began).toISOString(), ended: new Date().toISOString(),
  requests: results.length,
  status: count('status'),
  errorType: count('errorType'),
  envs: count('env'), // 環境ごとの処理件数
  latencyMs: { p50: pct(okLat, 50), p95: pct(okLat, 95), max: okLat.at(-1) ?? 0 },
}
mkdirSync('results', { recursive: true })
const file = `results/${name}_${summary.began.replace(/[:.]/g, '-')}.json`
writeFileSync(file, JSON.stringify({ summary, results }, null, 2))
console.log(JSON.stringify(summary, null, 2))
console.log(`saved: ${file}`)
