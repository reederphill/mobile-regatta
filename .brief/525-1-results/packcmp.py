import json,sys,math,statistics as st
S=sys.argv[1]; name=sys.argv[2]
def load(w):
    d=json.load(open(f'{S}/out/{name}-{w}.json'))
    out={}
    for r in d['races']:
        k=(json.dumps(r['layout'],sort_keys=True),r['seed'],r['tierMix'])
        out[k]=r
    return out
B=load('base');N=load('branch')
def metrics(r):
    bs=r['boats']
    ex=[b['extraMetres'] for b in bs if b.get('extraMetres') is not None]
    return dict(
      extra=sum(ex)/len(ex) if ex else float('nan'),
      pack=sum(b['extraMetres'] for b in bs if b['inPack'] and b.get('extraMetres') is not None) if any(b['inPack'] for b in bs) else float('nan'),
      contacts=sum(b['boatContacts'] for b in bs)/2,
      touches=sum(b['markTouches'] for b in bs),
      calls=sum(b['calls'] for b in bs),
      deepest=st.mean([b['deepest'] for b in bs if b.get('deepest') is not None]),
      below=st.mean([b['belowSeconds'] for b in bs if b.get('belowSeconds') is not None]),
      stillbelow=sum(1 for b in bs if b.get('stillBelow'))/len(bs),
      held=1.0 if any(b['inPack'] for b in bs) else 0.0,
      both=1.0 if len({b['markUsed'] for b in bs if b.get('markUsed') is not None})>=2 else 0.0,
    )
def rule(r,ru): return sum(b['callsByRule'].get(ru,0) for b in r['boats'])
rules=['10','11','12','13','15','16.1','17','18.2','21.2']
def agg(keys,f):
    xs=[f(B[k]) for k in keys],[f(N[k]) for k in keys]
    return xs
def rep(label,keys):
    print(f'-- {label}: {len(keys)} races')
    mets={k:(metrics(B[k]),metrics(N[k])) for k in keys}
    for m in ['extra','pack','held','both','contacts','touches','calls','deepest','below','stillbelow']:
        pairs=[(a[m],b[m]) for a,b in mets.values() if not(math.isnan(a[m]) or math.isnan(b[m]))]
        diffs=[b-a for a,b in pairs]
        mb=st.mean(a for a,b in pairs); mn=st.mean(b for a,b in pairs)
        se=st.stdev(diffs)/math.sqrt(len(diffs)) if len(diffs)>1 else float('nan')
        print(f'  {m:10s} base {mb:8.3f} branch {mn:8.3f} diff {mn-mb:+8.3f} (paired SE {se:.3f}, z {((mn-mb)/se if se else 0):+.1f})')
    for ru in rules:
        a=st.mean(rule(B[k],ru) for k in keys);b=st.mean(rule(N[k],ru) for k in keys)
        if a or b: print(f'  rule {ru:5s} base {a:.3f} branch {b:.3f} diff {b-a:+.3f}')
keys=sorted(B.keys()&N.keys())
assert len(keys)==len(B)==len(N), (len(keys),len(B),len(N))
rep('all',keys)
rep('seeds 1-8',[k for k in keys if k[1]<=8])
rep('seeds 9-16',[k for k in keys if k[1]>=9])
for size in [4,5,6]:
    rep(f'size {size}',[k for k in keys if json.loads(k[0])['size']==size])
for ky,vals in [('offset',[-6,0,6]),('gybes',['same','mixed']),('current',[True,False])]:
    for v in vals:
        rep(f'{ky} {v}',[k for k in keys if json.loads(k[0])[ky]==v])
