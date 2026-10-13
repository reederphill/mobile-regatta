import re,sys
def summ(path):
    L=open(path).read().split('\n')
    o={}
    o['races']=L[0].split(',')[0]
    fin={}; off=0; touches_marks={}
    for l in L:
        m=re.match(r'^(club|regional|national): (\d+)/(\d+) finished.*marks ([\d.]+)/boat.*racing (\d+)/(\d+)\)',l)
        if m:
            fin[m[1]]=int(m[2])/int(m[3]); off+=int(m[5]); o['n_'+m[1]]=int(m[3])
    o['fin']=fin; o['racing_fouls']=off
    i=[k for k,l in enumerate(L) if l.startswith('roundings by tier')][0]
    R={}
    for l in L[i+2:i+18]:
        f=l.split()
        if len(f)<8: continue
        tier,mark,n,mean,med,_,p90,s30,s50=f[:9]
        R[(tier,mark)]=dict(n=int(n),mean=float(mean),med=float(med),p90=float(p90),s30=float(s30),s50=float(s50),rest=' '.join(f[9:]))
    o['R']=R
    i=[k for k,l in enumerate(L) if l.startswith('planing off the wind')][0]
    f=L[i+2].split()
    o['plan']=dict(gybes=float(f[4]),falls=float(f[5]),gybef=float(f[6]),roundf=float(f[7]),deep=float(f[8]))
    i=[k for k,l in enumerate(L) if l.startswith('legs by tactics')][0]
    agg={}
    for l in L[i+2:]:
        m=re.match(r'^\s+(club|regional|national)\s+(club|regional|national)\s+(first beat|later beats|reaches|runs|last run)\s+(.*)$',l)
        if not m: break
        f=m[4].replace(' / ','/').split()
        legs=int(f[1]); 
        a=agg.setdefault(m[3],dict(legs=0,turnlegs=0,falls=0,gybes=0,t31=0,calls=0,clean=0))
        a['legs']+=legs
        a['turnlegs']+=float(f[6])*legs if f[6]!='-' else 0
        a['falls']+=float(f[8])*legs; a['gybes']+=float(f[9])*legs
        calls=[float(x)*legs for x in f[10:19]]
        a['t31']+=calls[-1]; a['calls']+=sum(calls[:-1])
        a['clean']+=float(f[4])*legs
    o['legs']=agg
    g=[l for l in L if l.startswith('gate:')]
    o['gate']=g[0] if g else ''
    return o
def row(name,o):
    R=o['R']; g=R[('all','gate')]; w=R[('all','windward')]; of=R[('all','offset')]
    ov=g['rest'].split()[1] if len(g['rest'].split())>1 else '-'
    ru=o['legs']['runs']; lb=o['legs']['later beats']
    return (f"{name:10s} G n={g['n']} mean {g['mean']:5.1f} med {g['med']:5.1f} p90 {g['p90']:5.1f} >=30 {g['s30']:.3f} >=50 {g['s50']:.3f} over {g['rest']:12s}| "
            f"W {w['mean']:4.1f} O {of['mean']:4.1f} | runs: gybes {ru['gybes']/ru['legs']:.2f} falls {ru['falls']/ru['legs']:.2f} t31 {ru['t31']:.0f} calls {ru['calls']:.0f} turnlegs {ru['turnlegs']:.0f} clean {ru['clean']/ru['legs']:.1f} | laterbeat calls {lb['calls']:.0f} t31 {lb['t31']:.0f} clean {lb['clean']/lb['legs']:.1f}| plan falls {o['plan']['falls']:.2f} rnd {o['plan']['roundf']:.2f} gybe {o['plan']['gybef']:.2f} | racing fouls {o['racing_fouls']} | fin C {o['fin']['club']:.3f} R {o['fin']['regional']:.3f} N {o['fin']['national']:.3f}"
            + f" | gate by tier C {R[('club','gate')]['mean']} R {R[('regional','gate')]['mean']} N {R[('national','gate')]['mean']}")
if __name__=='__main__':
    import os
    d=os.path.dirname(os.path.abspath(__file__))
    for n in sys.argv[1:]:
        print(row(n,summ(os.path.join(d,n+'.txt'))))
