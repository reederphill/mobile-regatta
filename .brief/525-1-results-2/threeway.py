import json,sys,math,statistics as st
P='/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad'
name=sys.argv[1]
def load(p):
    d=json.load(open(p)); return {(json.dumps(r['layout'],sort_keys=True),r['seed'],r['tierMix']):r for r in d['races']}
T={'base':load(f'{P}/525-1/out/{name}-base.json'),'r1':load(f'{P}/525-1/out/{name}-branch.json'),'head':load(f'{P}/525-1r2/out/{name}-branch.json')}
ks=sorted(T['base'])
assert set(ks)==set(T['r1'])==set(T['head'])
print(f'### {name}: {len(ks)} races')
def rf(r,f): return f(r)
F={'contacts/race':lambda r:sum(b['boatContacts'] for b in r['boats'])/2,'calls/race':lambda r:sum(b['calls'] for b in r['boats']),
   **{f'rule {x}/race':(lambda x: lambda r:sum(b['callsByRule'].get(x,0) for b in r['boats']))(x) for x in ['10','11','12','18.2']}}
print('metric | base | r1 | head | head-base (paired SE, z) | head-r1 (z) | 18.2/11/12 counts')
for m,f in F.items():
    v={w:[f(T[w][k]) for k in ks] for w in T}
    def pz(a,b):
        d=[y-x for x,y in zip(v[a],v[b])]; se=st.stdev(d)/math.sqrt(len(d)); mu=st.mean(d); return mu,se,(mu/se if se else 0)
    hb=pz('base','head'); hr=pz('r1','head')
    print(f'{m} | {st.mean(v["base"]):.3f} | {st.mean(v["r1"]):.3f} | {st.mean(v["head"]):.3f} | {hb[0]:+.3f} ({hb[1]:.3f}, {hb[2]:+.1f}) | {hr[0]:+.3f} ({hr[2]:+.1f}) | {sum(v["base"]):.0f}/{sum(v["r1"]):.0f}/{sum(v["head"]):.0f}')
# per boat splits
def p90(x): x=sorted(x); return x[min(len(x)-1,int(math.ceil(0.9*len(x)))-1)] if x else float('nan')
def boats(w,sel):
    out=[]
    for k in ks:
        L=json.loads(k[0]); rb=T['base'][k]['boats']; rw=T[w][k]['boats']
        for bb,bw in zip(rb,rw):
            if bw.get('deepest') is None: continue
            if sel(L,bb,bw): out.append(bw)
    return out
def summ(bs):
    if not bs: return 'n=0'
    ex=[b['extraMetres'] for b in bs if b.get('extraMetres') is not None]; dp=[b['deepest'] for b in bs]
    return f"n={len(bs)} extra {st.mean(ex):.1f} deepest {st.mean(dp):.2f} p90 {p90(dp):.1f} still {sum(b['stillBelow'] for b in bs)} ({sum(b['stillBelow'] for b in bs)/len(bs)*100:.1f}%) overshoot {sum(b['overshoot'] for b in bs)}"
nearmark=lambda L: 0 if L['offset']<0 else (1 if L['offset']>0 else None)
S={'all boats':lambda L,bb,bw:True,
   'kept base mark':lambda L,bb,bw:bb.get('markUsed') is not None and bb.get('markUsed')==bw.get('markUsed'),
   'switched from base mark':lambda L,bb,bw:bb.get('markUsed') is not None and bw.get('markUsed') is not None and bb.get('markUsed')!=bw.get('markUsed'),
   'offset +-6, rounded the mark under the pack (near)':lambda L,bb,bw:nearmark(L) is not None and bw.get('markUsed')==nearmark(L),
   'offset +-6, rounded the far mark':lambda L,bb,bw:nearmark(L) is not None and bw.get('markUsed') is not None and bw.get('markUsed')!=nearmark(L),
   'offset 0':lambda L,bb,bw:L['offset']==0}
for s,f in S.items():
    print(f'-- {s}')
    for w in T: print(f'   {w:5s} {summ(boats(w,f))}')
