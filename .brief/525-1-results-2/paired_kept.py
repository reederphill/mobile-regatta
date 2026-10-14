import json,sys,math,statistics as st
exec(open('threeway.py').read().split("print(f'### {name}")[0])
def p90(x): x=sorted(x); return x[min(len(x)-1,int(math.ceil(0.9*len(x)))-1)] if x else float('nan')
nearmark=lambda L: 0 if L['offset']<0 else (1 if L['offset']>0 else None)
print(f'### {name}: boats rounding the same mark on base and on W, stats on the same boats')
for w in ['r1','head']:
  for lab,sel in [('near (mark under the pack, offset +-6)',lambda L,m:nearmark(L)==m),('far (offset +-6)',lambda L,m:nearmark(L) is not None and nearmark(L)!=m),('offset 0',lambda L,m:L['offset']==0)]:
    pb=[];pw=[]
    for k in ks:
      L=json.loads(k[0])
      for bb,bw in zip(T['base'][k]['boats'],T[w][k]['boats']):
        if bb.get('deepest') is None or bw.get('deepest') is None: continue
        if bb.get('markUsed') is None or bb.get('markUsed')!=bw.get('markUsed'): continue
        if sel(L,bb['markUsed']): pb.append(bb); pw.append(bw)
    def s(bs): 
      ex=[b['extraMetres'] for b in bs if b.get('extraMetres') is not None]; dp=[b['deepest'] for b in bs]
      return f"extra {st.mean(ex):.1f} deepest {st.mean(dp):.2f} p90 {p90(dp):.1f} still {sum(b['stillBelow'] for b in bs)} overshoot {sum(b['overshoot'] for b in bs)}"
    dd=[y['deepest']-x['deepest'] for x,y in zip(pb,pw)]
    print(f'  {w:4s} {lab:40s} n={len(pb)} | base {s(pb)} | {w} {s(pw)} | deepest diff {st.mean(dd):+.2f} (SE {st.stdev(dd)/math.sqrt(len(dd)):.2f})')
