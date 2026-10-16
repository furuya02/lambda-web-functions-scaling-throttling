#!/usr/bin/env python3
# results/*.json をラウンドごとに集計して表示する（環境ごとの件数、最大 inflight、status、p50/p95）
import json, sys, glob
from collections import Counter
files = sys.argv[1:] or sorted(glob.glob('results/*.json'))
for f in files:
    d = json.load(open(f)); s = d['summary']
    print(f"== {s['name']}  conc={s['concurrency']} rps={s['rps']} ms={s['ms']}  requests={s['requests']} status={s['status']} errorType={s['errorType']} envs={len(s['envs'])} p50={s['latencyMs']['p50']} p95={s['latencyMs']['p95']}")
    rounds = sorted(set(x['round'] for x in d['results']))
    for r in rounds:
        rr = [x for x in d['results'] if x['round'] == r]
        c = Counter(x.get('env') or x.get('status') for x in rr)
        lat = sorted(x['end'] - x['start'] for x in rr if x['status'] == 200)
        p50 = lat[len(lat) // 2] if lat else 0
        st = Counter(x['status'] for x in rr)
        print(f"  r{r+1:<3} envs={len([k for k in c if isinstance(k, str)]):<2} per-env={sorted(c.values(), reverse=True)} maxInflight={max((x.get('inflight') or 0) for x in rr)} status={dict(st)} p50={p50} max={lat[-1] if lat else 0}")
