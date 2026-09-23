import json,os,sys,glob,re
D=sys.argv[1]; OUT=sys.argv[2]
dec=json.JSONDecoder()
def sweep(text):
    i=0
    while True:
        j=text.find('{"',i)
        if j<0: return
        try:
            obj,end=dec.raw_decode(text,j); yield obj; i=end
        except Exception: i=j+2

# map agentId -> label/phase from journal started events
label={}
jtext=open(os.path.join(D,"journal.jsonl"),errors='replace').read()
for o in sweep(jtext):
    if o.get("type")=="started": label[o.get("agentId")]=o.get("label")

rows=[]
for f in sorted(glob.glob(os.path.join(D,"agent-*.jsonl"))):
    aid=os.path.basename(f)[6:-6]
    text=open(f,errors='replace').read()
    prompt=None; verdict=None
    for o in sweep(text):
        msg=o.get("message")
        if isinstance(msg,dict) and msg.get("role")=="user" and prompt is None:
            c=msg.get("content")
            s=c if isinstance(c,str) else " ".join(b.get("text","") for b in c if isinstance(b,dict) and b.get("type")=="text")
            if "Try to REFUTE this claim" in s: prompt=s
        if isinstance(msg,dict) and isinstance(msg.get("content"),list):
            for b in msg["content"]:
                if isinstance(b,dict) and b.get("type")=="tool_use" and b.get("name")=="StructuredOutput":
                    inp=b.get("input") or {}
                    if isinstance(inp.get("input"),dict): inp=inp["input"]
                    if "verdict" in inp: verdict=inp
    if prompt:
        m=re.search(r'\(topic: (.*?)\)\s*Claim: "(.*)"\s*Claimed source: (.*?)(?:\. If the claim|$)', prompt, re.S)
        topic=m.group(1).strip() if m else "?"
        claim=m.group(2).strip() if m else "?"
        src=m.group(3).strip() if m else "?"
        rows.append({"agent":aid,"label":label.get(aid),"topic":topic,"claim":claim,"source":src,"verdict":verdict})
print("verify prompts recovered:",len(rows))
from collections import Counter
print(Counter(r["topic"][:60] for r in rows))
print("with verdict:",sum(1 for r in rows if r["verdict"]))
json.dump(rows,open(OUT,"w"),indent=1)
print("wrote",OUT)
