import json,os,sys,re
SP=sys.argv[1]; D=sys.argv[2]
rec=json.load(open(os.path.join(SP,"research/recovered.json")))
rows=json.load(open(os.path.join(SP,"research/verify_rows.json")))
out=[]
out.append("# Recovered research digest\n\nSource: workflow wf_9c11d8d4-0ab, run 2026-09-11. Recovered 2026-09-18 after the run died.\n")
out.append("## Part 1: full research notes (3 of 5 topics survived intact)\n")
for r in rec["research"]:
    out.append(f"### TOPIC: {r['topic']}\n")
    out.append("**Findings**\n")
    for i,f in enumerate(r.get("findings") or [],1):
        out.append(f"{i}. [{f.get('confidence','?')}] {f.get('claim','')}")
        if f.get("why_it_matters"): out.append(f"   - why: {f['why_it_matters']}")
        out.append(f"   - src: {f.get('source','')}")
    if r.get("code_snippets"):
        out.append("\n**Code snippets**\n")
        for c in r["code_snippets"]:
            out.append(f"- purpose: {c.get('purpose')}  (src: {c.get('source','')})\n```\n{c.get('code','')}\n```")
    out.append("\n**Pitfalls**\n")
    for p in r.get("pitfalls") or []: out.append(f"- {p}")
    out.append("\n**Open questions**\n")
    for q in r.get("open_questions") or []: out.append(f"- {q}")
    out.append("")

# truncated background-webrequest partial
line=open(os.path.join(D,"journal.jsonl"),errors='replace').read().splitlines()[5]
part=line[:2856]
out.append("## Part 2: background-webrequest topic (TRUNCATED by an interleaved write)\n")
out.append("Raw partial JSON below. Only the first findings survived.\n")
out.append("```\n"+part[part.find('{"topic"'):]+"\n```\n")

out.append("## Part 3: the 30 load-bearing claims, adversarially verified\n")
conf=[r for r in rows if r["verdict"] and r["verdict"]["verdict"]=="confirmed"]
ref=[r for r in rows if r["verdict"] and r["verdict"]["verdict"]=="refuted"]
unv=[r for r in rows if r["verdict"] and r["verdict"]["verdict"] not in ("confirmed","refuted")]
out.append(f"Confirmed {len(conf)}, refuted {len(ref)}, other {len(unv)}.\n")
out.append("### REFUTED / CORRECTED claims (read these first)\n")
for r in ref:
    v=r["verdict"]
    out.append(f"- **claim:** {v['claim']}")
    if v.get("correction"): out.append(f"  - **CORRECTION:** {v['correction']}")
    ev=(v.get('evidence') or '')
    out.append(f"  - evidence: {ev[:1200]}")
    out.append("")
out.append("### CONFIRMED claims\n")
for r in conf:
    v=r["verdict"]
    out.append(f"- {v['claim']}")
    if v.get("correction"): out.append(f"  - note: {v['correction']}")
    out.append(f"  - evidence: {(v.get('evidence') or '')[:600]}")
    out.append("")
if unv:
    out.append("### UNVERIFIABLE\n")
    for r in unv:
        v=r["verdict"]; out.append(f"- [{v['verdict']}] {v['claim']}\n  - evidence: {(v.get('evidence') or '')[:500]}\n")
txt="\n".join(out)
p=os.path.join(SP,"research/DIGEST.md")
open(p,"w").write(txt)
print("wrote",p,len(txt),"chars ~",len(txt)//4,"tokens")
