import re,json,sys,math,statistics as st
P='/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad'
src={'base':P+'/525-1/out/{}-base','r1':P+'/525-1/out/{}-branch','head':P+'/525-1r2/out/{}-branch'}
def gate(p,tier):
    for l in open(p+'.txt'):
        t=l.split()
        if len(t)>5 and t[0]==tier and t[1]=='gate':
            # tier gate n mean med / p90 ge30 ge50 - over (x%) e2em e2es med / p90 below med / p90 deepest p90 still (x%)
            n=int(t[2]); mean=float(t[3]); over=int(t[10]); e2e=float(t[12]); below=float(t[17]); deep=float(t[21]); dp90=float(t[22]); still=int(t[23])
            return dict(n=n,mean=mean,over=over,e2e=e2e,below=below,deep=deep,dp90=dp90,still=still)
def runs(p):
    d=json.load(open(p+'.json'))
    def key(r): c=r['cell']; return (c['seed'],c['venue'],c['conditions'],c['fleetSize'],c['tierMix'])
    return {key(r):r for r in d['races']}
print('| set | gate mean m (b / r1 / H) | deepest m | deepest p90 m | below s | still below | overshoot | entry-to-end m |')
print('|---|---|---|---|---|---|---|---|')
for n,tier in [('m8','all'),('m8n','all'),('m16','all'),('m16n','all'),('club8','club'),('mix10','all'),('nat16','national')]:
    g={w:gate(src[w].format(n),tier) for w in src}
    f=lambda k,fmt='{:.1f}': ' / '.join(fmt.format(g[w][k]) for w in src)
    st_=' / '.join(f"{g[w]['still']} ({g[w]['still']/g[w]['n']*100:.1f}%)" for w in src)
    print(f"| {n} | {f('mean')} | {f('deep')} | {f('dp90')} | {f('below')} | {st_} | {f('over','{}')} | {f('e2e')} |")
print()
print('| set | finishers b / r1 / H (H-b, z) | racing fouls b / r1 / H | calls b / r1 / H (H-b z) | contacts (H-b z) | 10 | 11 | 12 | 18.2 |')
print('|---|---|---|---|---|---|---|---|---|')
for n in ['m8','m8n','m16','m16n','club8','mix10','nat16']:
    R={w:runs(src[w].format(n)) for w in src}; ks=sorted(R['base'])
    def tot(w,f): return [f(R[w][k]) for k in ks]
    def z(f):
        a=tot('base',f); b=tot('head',f); d=[y-x for x,y in zip(a,b)]; se=st.stdev(d)*math.sqrt(len(d)); return sum(d),(sum(d)/se if se else 0)
    fin=lambda r:r['fleet']['finished']; calls=lambda r:r['fleet']['ruleCalls']; con=lambda r:r['fleet']['boatContacts']
    rf=lambda r:sum(s['foulsAsOffender'] for s in r['seats'])-sum(sum(s['preStartCallsByRule'].values()) for s in r['seats'])
    rule=lambda x:(lambda r:sum(s['callsByRule'].get(x,0) for s in r['seats']))
    s=lambda f:' / '.join(str(sum(tot(w,f))) for w in src)
    fz=z(fin); cz=z(calls); kz=z(con); rz=z(rf)
    print(f"| {n} | {s(fin)} ({fz[0]:+d}, {fz[1]:+.1f}) | {s(rf)} ({rz[1]:+.1f}) | {s(calls)} ({cz[1]:+.1f}) | {s(con)} ({kz[1]:+.1f}) | {s(rule('10'))} | {s(rule('11'))} | {s(rule('12'))} | {s(rule('18.2'))} |")
