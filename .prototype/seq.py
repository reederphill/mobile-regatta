#!/usr/bin/env python3
"""python3 .prototype/seq.py name: per seat and gate leg, the sequence of chosen candidates in a REGATTA_ONLY trace (PT lines) with PK outcome."""
import sys,re,collections
n=sys.argv[1]; D='/Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525/.prototype/results/'
seqs=collections.defaultdict(list); pk={}
last={}
for l in open(D+n+'.err'):
    if l.startswith('PT '):
        f=l.split(); t=float(f[1][2:]); seat=int(f[2][5:]); ch=f[-1]
        # new leg if time gap > 20
        key=(seat, 1 if t>last.get(seat,-99)+20 else 0)
        if key[1]: last[seat]=t; seqs[seat].append([])
        last[seat]=t
        s=seqs[seat][-1]
        if not s or s[-1][1]!=ch: s.append((t,ch))
    elif l.startswith('PK '):
        f=l.split(); kv=dict(x.split('=',1) for x in f[2:]); pk.setdefault(int(kv['seat']),[]).append((kv['mark'],kv['e2eX'],kv['below']))
for seat in sorted(seqs):
    for i,s in enumerate(seqs[seat]):
        o=pk.get(seat,[]); o=o[i] if i<len(o) else None
        print(seat,i,'sw=%d'%(len(s)-1),' '.join('%.0f:%s'%(t,c) for t,c in s), '| mark,e2eX,below=',o)
