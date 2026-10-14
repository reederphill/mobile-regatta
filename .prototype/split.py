#!/usr/bin/env python3
"""python3 .prototype/split.py main-run P-run: packs (>=3 boats within 20 m at her entry) at a race's first gate, marks used in each run.
Before the first gate leg's pick the runs are identical, so the pack is the same pack; a split = the P run uses both marks, main one."""
import sys,collections
sys.path.insert(0,'/Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525/.prototype')
import pk
a=pk.load(sys.argv[1]); b=pk.load(sys.argv[2])
def idx(rows): return {(r['race'],r['leg'],r['seat']):r for r in rows}
A=idx(a); B=idx(b)
out=[]; n=0; seen=set()
for (race,leg,seat),r in A.items():
    first=min(l for (rc,l,s) in A if rc==race)
    if leg!=first or not r['pack']: continue
    members=frozenset([seat]+[s for s,m in r['nb'] if m<20])
    if (race,members) in seen: continue
    seen.add((race,members)); n+=1
    ma=[A[(race,leg,s)]['mark'] for s in members if (race,leg,s) in A]
    mb=[B[(race,leg,s)]['mark'] for s in members if (race,leg,s) in B]
    ea=sum(A[(race,leg,s)]['e2eX'] for s in members if (race,leg,s) in A); eb=sum(B[(race,leg,s)]['e2eX'] for s in members if (race,leg,s) in B)
    out.append((race,sorted(members),ma,mb,ea,eb))
print('first-gate packs',n)
for o in out: print(o[0],o[1],'main marks',o[2],'P marks',o[3],'sum e2eX main %.0f P %.0f'%(o[4],o[5]))
print('main split',sum(1 for o in out if len(set(o[2]))>1),'P split',sum(1 for o in out if len(set(o[3]))>1))
