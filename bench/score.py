# Score outputs against Wispr. usage: score.py asr out/asr-ultra.jsonl | score.py llm out/llm-<name>.jsonl
import json, re, sys, os, statistics as st
D = os.path.dirname(__file__)
pairs = {p["id"]: p for p in map(json.loads, open(os.path.join(D, "data/pairs.jsonl")))}
FILLERS = {"um", "uh", "uhm", "hmm", "mm", "ah", "eh", "er", "erm", "hm", "ahn", "éh", "hum"}

def norm(s):
    s = re.sub(r"[^\w\s']", " ", (s or "").lower().replace("’", "'"))
    return [w for w in s.split() if w not in FILLERS]

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)], max(len(r), 1)

def pct(xs, q): xs = sorted(xs); return xs[min(len(xs) - 1, int(q * len(xs)))]

def report(rows, ref_key, label):
    by = {}
    for r in rows:
        p = pairs[r["id"]]; e, n = wer(p[ref_key], r["hyp"])
        for k in ("all", p["lang"] or "?"): by.setdefault(k, [0, 0, 0]); by[k][0] += e; by[k][1] += n; by[k][2] += 1
    for k, (e, n, c) in by.items(): print(f"  {label:<26} {k:<4} n={c:<4} WER={100*e/n:5.1f}%")

if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    rows = [json.loads(l) for l in open(os.path.join(D, path))]
    ms = [r["ms"] for r in rows]
    print(f"{path}: n={len(rows)} latency p50={pct(ms,.5):.0f}ms p90={pct(ms,.9):.0f}ms max={max(ms):.0f}ms",
          f"avg audio={st.mean(r.get('secs', 0) for r in rows):.1f}s" if mode == "asr" else "")
    report(rows, "asr", "vs Wispr raw ASR")
    report(rows, "formatted", "vs Wispr final text")
