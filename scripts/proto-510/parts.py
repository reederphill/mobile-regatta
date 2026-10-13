import sys,re,statistics as st
def load(f):
    rows=[]
    for l in open(f):
        if not l.startswith('GD'): continue
        d=dict(x.split('=') for x in l.split()[2:] if '=' in x and not x.startswith('gate#'))
        d={k:(v if k=='tier' else float(v)) for k,v in d.items()}
        d['race']=l.split()[1]
        rows.append(d)
    return rows
def q(v,p):
    v=sorted(v); return v[int(p*(len(v)-1))]
def line(name,rows):
    n=len(rows)
    ds=[r['legs']-r['ideals'] for r in rows]          # seconds over the ideal approach, entry to leg end
    dm=[r['legm']-r['idealm']+r['exit'] for r in rows] # metres over the ideal approach, entry to leg end, plus the exit's extra
    up=[r['exitup']+r['doneabove'] for r in rows]   # metres above the gate's line 15 s after the leg's end
    VMG=2.4
    cs=[r['legs']-r['ideals']-(r['exitup']+r['doneabove'])/VMG for r in rows]  # composite seconds: time over ideal less the height she has 15 s on, at 2.4 m/s made good
    ex=[r['extra'] for r in rows]
    ov=sum(1 for r in rows if r['below']>=90); anyb=sum(1 for r in rows if r['below']>0)
    return (f"{name:9s} n={n} | probe extra m: mean {st.mean(ex):5.1f} med {q(ex,.5):5.1f} | path m over ideal (entry->leg end, + exit): mean {st.mean(dm):5.1f} med {q(dm,.5):5.1f} p90 {q(dm,.9):5.1f} | s over ideal: mean {st.mean(ds):5.1f} med {q(ds,.5):5.1f} p90 {q(ds,.9):5.1f} >=20s {sum(1 for x in ds if x>=20)/n:.3f} >=40s {sum(1 for x in ds if x>=40)/n:.3f} | above line 15 s after: mean {st.mean(up):5.1f} med {q(up,.5):5.1f} | composite s: mean {st.mean(cs):5.1f} med {q(cs,.5):5.1f} p90 {q(cs,.9):5.1f} | overshoot {ov} ({ov/n:.3f}) below at all {anyb}"
            f" | parts mean a/r/e {st.mean(r['approach'] for r in rows):.1f}/{st.mean(r['round'] for r in rows):.1f}/{st.mean(r['exit'] for r in rows):.1f}")
if __name__=='__main__':
    import os
    d=os.path.dirname(os.path.abspath(__file__))
    for n in sys.argv[1:]:
        rows=load(os.path.join(d,n+'.err'))
        print(line(n,rows))
        if os.environ.get('TIERS'):
            for t in ('club','regional','national'):
                print('   ',line(t,[r for r in rows if r['tier']==t]))
