# usage: inspect_llm.py out/llm-X.jsonl  → worst outputs + failure counts
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import score
rows = [json.loads(l) for l in open(sys.argv[1])]
def r(x): e, n = score.wer(score.pairs[x['id']]['formatted'], x['hyp']); return e / n
rows.sort(key=lambda x: -r(x))
for x in rows[:int(sys.argv[2]) if len(sys.argv) > 2 else 5]:
    print(f"{r(x):.2f} {x['ms']:.0f}ms\n RAW: {x['raw'][:220]}\n OUT: {x['hyp'][:220]}\n WSP: {score.pairs[x['id']]['formatted'][:220]}\n")
lw = lambda s: len(s.split())
print("expanded(answered?):", sum(lw(x['hyp']) > 1.5 * lw(x['raw']) + 5 for x in rows),
      "shortened<60%:", sum(lw(x['hyp']) < 0.6 * lw(x['raw']) for x in rows), "of", len(rows))
