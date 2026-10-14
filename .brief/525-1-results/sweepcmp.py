import sys,re
S=sys.argv[1]; names=sys.argv[2:]
def parse(p):
    L=open(p).read().split('\n'); d={}
    d['head']=L[0]
    for l in L:
        m=re.match(r'^(club|regional|national): (\d+)/(\d+) finished.*contacts (\d+) \(([\d.]+) fouls\), encounters (\d+) \(([\d.]+) fouls; pre-start (\d+)/(\d+), racing (\d+)/(\d+)\)',l)
        if m:
            t=m.group(1); d[t+'_fin']=int(m.group(2))/int(m.group(3)); d[t+'_boats']=int(m.group(3)); d[t+'_contacts']=int(m.group(4)); d[t+'_racing']=f'{m.group(10)}/{m.group(11)}'; d[t+'_prest']=f'{m.group(8)}/{m.group(9)}'
            d[t+'_racingN']=int(m.group(10)); d[t+'_racingEnc']=int(m.group(11))
            mm=re.search(r'marks ([\d.]+)/boat',l); d[t+'_marks']=mm.group(1)
        m=re.match(r'^  (club|regional|national) calls: (.*?);',l)
        if m:
            d[m.group(1)+'_calls']=dict((a,int(b)) for a,b in re.findall(r'([\d.]+) (\d+)',m.group(2)))
        m=re.match(r'^  by skill: (.*)',l)
        if m: d['byskill']=m.group(1)
        m=re.match(r'^  by handling: (.*)',l)
        if m: d['byhand']=m.group(1)
        m=re.match(r'^  (all|club|regional|national)\s+(gate)\s+(\d+)\s+([\d.]+)\s+([\d.-]+) / ([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+-\s+(\d+) \(([\d.]+)%\)\s+([\d.-]+)\s+([\d.-]+)\s+([\d.-]+) / ([\d.-]+)\s+([\d.-]+)\s+([\d.-]+) / ([\d.-]+)\s+([\d.-]+)\s+([\d.-]+)\s+(\d+) \(([\d.]+)%\)',l)
        if m:
            g=m.groups(); d['gate_'+g[0]]=dict(n=int(g[2]),mean=float(g[3]),med=g[4],p90=float(g[5]),ge30=float(g[6]),ge50=float(g[7]),over=g[8],e2e_m=float(g[10]),e2e_s=float(g[11]),below_s=float(g[14]),deepest=float(g[17]),still=g[19]+' ('+g[20]+'%)')
    # all/all appr extra: roundings 'all all'
    for l in L:
        m=re.match(r'^  all\s+all\s+(\d+)\s+([\d.]+)\s+([\d.-]+) / ([\d.]+)\s+([\d.]+)\s+([\d.]+)',l)
        if m: d['allall_mean']=float(m.group(2))
    return d
for n in names:
    B=parse(f'{S}/out/{n}-base.txt'); N=parse(f'{S}/out/{n}-branch.txt')
    print('=====',n,B['head'],'|',N['head'])
    for t in ['all','club','regional','national']:
        b=B.get('gate_'+t);c=N.get('gate_'+t)
        if b and c:
            print(f'gate {t:8s} n={b["n"]}: mean {b["mean"]:5.1f} -> {c["mean"]:5.1f} ({c["mean"]-b["mean"]:+.1f}) | e2e m {b["e2e_m"]:.1f} -> {c["e2e_m"]:.1f} | e2e p90? p90 {b["p90"]} -> {c["p90"]} | >=30 {b["ge30"]:.3f} -> {c["ge30"]:.3f} | >=50 {b["ge50"]:.3f}->{c["ge50"]:.3f} | over {b["over"]} -> {c["over"]} | below s {b["below_s"]} -> {c["below_s"]} | deepest {b["deepest"]} -> {c["deepest"]} | still {b["still"]} -> {c["still"]}')
    if 'allall_mean' in B: print(f'all roundings mean m {B["allall_mean"]} -> {N["allall_mean"]}')
    for t in ['club','regional','national']:
        if t+'_fin' in B:
            print(f'{t:8s} finish {B[t+"_fin"]:.3f} -> {N[t+"_fin"]:.3f} | contacts {B[t+"_contacts"]} -> {N[t+"_contacts"]} | racing fouls/enc {B[t+"_racing"]} -> {N[t+"_racing"]} | prestart {B[t+"_prest"]} -> {N[t+"_prest"]} | marks/boat {B[t+"_marks"]} -> {N[t+"_marks"]}')
            cb,cn=B[t+'_calls'],N[t+'_calls']
            rules=sorted(set(cb)|set(cn),key=float)
            print('   calls '+', '.join(f'{r}: {cb.get(r,0)}->{cn.get(r,0)}' for r in rules)+f' | total {sum(cb.values())}->{sum(cn.values())}')
    print('places by skill   base:',B.get('byskill'),'\n                branch:',N.get('byskill'))
    print('places by handling base:',B.get('byhand'),'\n                  branch:',N.get('byhand'))
