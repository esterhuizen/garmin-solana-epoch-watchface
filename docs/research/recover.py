import json,os,sys,glob,re
D=sys.argv[1]; OUT=sys.argv[2]
dec=json.JSONDecoder()

def sweep(text):
    """Yield every JSON object recoverable from text, tolerating interleaved garbage."""
    i=0; n=len(text)
    while True:
        j=text.find('{"',i)
        if j<0: return
        try:
            obj,end=dec.raw_decode(text,j)
            yield obj
            i=end
        except Exception:
            i=j+2

research={}   # topic -> result dict
verdicts=[]
seen=set()

def take_research(r):
    if not isinstance(r,dict): return
    if "topic" in r and "findings" in r:
        t=r["topic"]
        # keep the richest version of each topic
        if t not in research or len(json.dumps(r))>len(json.dumps(research[t])):
            research[t]=r

def take_verdict(r):
    if isinstance(r,dict) and "verdict" in r and "claim" in r:
        k=(r["claim"][:120],r["verdict"])
        if k not in seen:
            seen.add(k); verdicts.append(r)

files=[os.path.join(D,"journal.jsonl")]+sorted(glob.glob(os.path.join(D,"agent-*.jsonl")))
stats={}
for f in files:
    text=open(f,errors='replace').read()
    nr=len(research); nv=len(verdicts)
    for obj in sweep(text):
        # journal result envelopes
        if obj.get("type")=="result" and isinstance(obj.get("result"),dict):
            take_research(obj["result"]); take_verdict(obj["result"])
        # StructuredOutput tool_use blocks inside transcripts
        msg=obj.get("message")
        if isinstance(msg,dict) and isinstance(msg.get("content"),list):
            for b in msg["content"]:
                if isinstance(b,dict) and b.get("type")=="tool_use" and b.get("name")=="StructuredOutput":
                    inp=b.get("input") or {}
                    if isinstance(inp.get("input"),dict): inp=inp["input"]
                    take_research(inp); take_verdict(inp)
        # bare tool_use object
        if obj.get("type")=="tool_use" and obj.get("name")=="StructuredOutput":
            inp=obj.get("input") or {}
            if isinstance(inp.get("input"),dict): inp=inp["input"]
            take_research(inp); take_verdict(inp)
    stats[os.path.basename(f)]=(len(research)-nr,len(verdicts)-nv)

print("=== recovered ===")
print("research topics:",len(research))
for t,r in research.items():
    print(f"  - {t[:75]}")
    print(f"      findings={len(r.get('findings') or [])} snippets={len(r.get('code_snippets') or [])} pitfalls={len(r.get('pitfalls') or [])} open_q={len(r.get('open_questions') or [])}")
print("verdicts:",len(verdicts))
from collections import Counter
print(" ",Counter(v["verdict"] for v in verdicts))
print("=== per-file contribution (new_research,new_verdicts) ===")
for k,v in stats.items():
    if v!=(0,0): print("  ",k,v)

json.dump({"research":list(research.values()),"verdicts":verdicts},open(OUT,"w"),indent=1)
print("wrote",OUT)
