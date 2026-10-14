import json,sys,math,statistics as st
S=sys.argv[1]
def key(r): c=r['cell']; return (c['seed'],c['venue'],c['conditions'],c['fleetSize'],c['tierMix'])
def tot(xs): return sum(xs)
print(f"{'set':6s} {'metric':14s} {'base':>8s} {'branch':>8s} {'diff':>7s} {'pairedSE':>8s} z")
for n in sys.argv[2:]:
    B={key(r):r for r in json.load(open(f'{S}/out/{n}-base.json'))['races']}
    N={key(r):r for r in json.load(open(f'{S}/out/{n}-branch.json'))['races']}
    ks=sorted(B.keys()&N.keys()); assert len(ks)==len(B)==len(N)
    def m(r,f): return f(r)
    mets={'finished':lambda r:r['fleet']['finished'],
          'ruleCalls':lambda r:r['fleet']['ruleCalls'],
          'contacts':lambda r:r['fleet']['boatContacts'],
          'markContacts':lambda r:r['fleet']['markContacts'],
          'racingFouls':lambda r:sum(s['foulsAsOffender'] for s in r['seats'])-sum(sum(s['preStartCallsByRule'].values()) for s in r['seats']),
          'rule18.2':lambda r:sum(s['callsByRule'].get('18.2',0) for s in r['seats']),
          'runGybes':lambda r:sum(g['gybes'] for s in r['seats'] for g in s['runs']),
    }
    for name,f in mets.items():
        a=[f(B[k]) for k in ks]; b=[f(N[k]) for k in ks]; d=[y-x for x,y in zip(a,b)]
        se=st.stdev(d)*math.sqrt(len(d))
        print(f"{n:6s} {name:14s} {sum(a):8d} {sum(b):8d} {sum(d):+7d} {se:8.1f} {sum(d)/se if se else 0:+.1f}")
