# LLM cleanup bench (fine-tune prompt format, sentence chunking, batched generation, fallback guard).
# usage: .venv/bin/python llm.py <hf-model> [--adapter DIR] [--chunk 60] [--n ROWS]
import argparse, json, os, re, time
from mlx_lm import load, batch_generate
import score
from make_train import SYSTEM, category, user_msg

D = os.path.dirname(os.path.abspath(__file__))
CUE_START = re.compile(r"^(actually|no|sorry|i mean|wait|scratch that|or rather|não|quer dizer|ou melhor|aliás|na verdade|pera|digo)\b", re.I)


def chunks(text, limit):
    out = []
    for s in re.split(r"(?<=[.!?])\s+", text.strip()):
        if out and (CUE_START.match(s) or len(out[-1].split()) + len(s.split()) <= limit): out[-1] += " " + s
        else: out.append(s)
    return out


CUE = re.compile(r"\b(actually|i mean|i meant|don't mean|sorry|scratch that|wait|or rather|correction|make that|rephrase|start over|quer dizer|ou melhor|aliás|na verdade|na real|pera|digo|esquece|corrigindo|melhor dizendo|errei|falei errado)\b|\b(no|não)\s*,", re.I)


def guard(raw, out):  # reject outputs that answered, looped or dropped content (shrinking is fine after a correction cue)
    a, b = len(raw.split()), len(out.split())
    if b == 0 or b > 1.5 * a + 10 or (b < 0.5 * a and a > 8 and not CUE.search(raw)): return raw, True
    if not nums(out) <= nums(raw): return raw, True  # never invent a number
    if looped(raw, out): return raw, True
    return out, False


def looped(raw, out, n=5):  # some 5-word phrase appears more often than the speaker said it
    grams = lambda s: (lambda w: [tuple(w[i:i + n]) for i in range(len(w) - n + 1)])(re.findall(r"\w+", s.lower()))
    r, o = grams(raw), grams(out)
    return any(o.count(g) > max(1, r.count(g)) for g in set(o))


def nums(s):  # digit groups, "1,500" -> "1500"; list numbering ("1. ") doesn't count
    s = re.sub(r"(?m)^\s*\d+[.)]\s", "", s)
    return set(re.findall(r"\d+", re.sub(r"(?<=\d),(?=\d{3})", "", s)))


class Cleaner:
    def __init__(self, name, adapter=None, limit=60, fix_model=None):
        self.model, self.tok = load(name, adapter_path=adapter)
        self.fix = load(fix_model) if fix_model else None  # (model, tok) used for chunks with a correction cue
        self.limit = limit

    def prompt(self, cat, text, vocab):
        m = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user_msg(cat, text, vocab)}]
        kw = dict(tokenize=False, add_generation_prompt=True)
        try: s = self.tok.apply_chat_template(m, enable_thinking=False, **kw)
        except TypeError: s = self.tok.apply_chat_template(m, **kw)
        return self.tok.encode(s, add_special_tokens=False)

    def __call__(self, app, text, vocab=""):
        if not text.strip(): return "", False
        parts = chunks(text, self.limit)
        outs = [None] * len(parts)
        groups = [(self.model, [i for i, p in enumerate(parts) if not (self.fix and CUE.search(p))])]
        if self.fix: groups.append((self.fix[0], [i for i, p in enumerate(parts) if CUE.search(p)]))
        for model, idx in groups:
            if not idx: continue
            prompts = [self.prompt(category(app), parts[i], vocab) for i in idx]
            maxt = [int(len(self.tok.encode(parts[i])) * 1.6) + 30 for i in idx]
            for i, o in zip(idx, batch_generate(model, self.tok, prompts, max_tokens=maxt).texts): outs[i] = o
        outs = [re.sub(r"<think>.*?</think>", "", o, flags=re.S).strip() for o in outs]
        res = [guard(p, o) for p, o in zip(parts, outs)]
        return " ".join(r[0] for r in res), any(r[1] for r in res)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("model"); ap.add_argument("--adapter"); ap.add_argument("--chunk", type=int, default=60)
    ap.add_argument("--n", type=int, default=10**9); ap.add_argument("--tag"); ap.add_argument("--cases", default="cases_holdout.jsonl"); ap.add_argument("--fix")
    a = ap.parse_args()
    t = time.time(); c = Cleaner(a.model, a.adapter, a.chunk, a.fix)
    print(f"{a.model} adapter={a.adapter} chunk={a.chunk}: load {time.time()-t:.1f}s")
    c("Claude", "warm up please")
    cases = [json.loads(l) for l in open(os.path.join(D, a.cases))]
    passed, cms = 0, []
    for k in cases:
        t = time.time(); o, _ = c(k["app"], k["in"], k.get("vocab", "")); cms.append((time.time() - t) * 1000)
        e, nw = score.wer(k["out"], o); ok = e / nw <= 0.15; passed += ok
        if not ok: print(f"  FAIL {k['in'][:75]!r}\n    -> {o[:130]!r}")
    print(f"  cases passed {passed}/{len(cases)}  median {sorted(cms)[len(cms)//2]:.0f}ms")
    rows = [json.loads(l) for l in open(os.path.join(D, "out/asr-ultra.jsonl"))]
    rows = [r for r in rows if score.norm(score.pairs[r["id"]]["formatted"])][:a.n]
    res, fb = [], 0
    for r in rows:
        t = time.time(); o, f = c(score.pairs[r["id"]]["app"], r["hyp"]); fb += f
        res.append(dict(id=r["id"], hyp=o, ms=(time.time() - t) * 1000, raw=r["hyp"]))
    tag = a.tag or a.model.split("/")[-1] + ("-ft" if a.adapter else "")
    with open(os.path.join(D, f"out/llm-{tag}.jsonl"), "w") as f:
        for r in res: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"  guard fallbacks: {fb}/{len(rows)}")
    os.system(f"{os.sys.executable} -I {D}/score.py llm out/llm-{tag}.jsonl")
