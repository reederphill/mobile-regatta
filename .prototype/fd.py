#!/usr/bin/env python3
"""python3 .prototype/fd.py run...: FD lines (position error of the stored roll-out track at +4/8/12 s) by skill band and wind."""
import sys,os,collections,statistics as st
D=os.path.join(os.path.dirname(os.path.abspath(__file__)),'results')
for n in sys.argv[1:]:
    g=collections.defaultdict(list)
    for l in open(os.path.join(D,n+'.err')):
        if not l.startswith('FD '): continue
        d=dict(x.split('=') for x in l.split()[1:])
        sk=float(d['skill']); band='club' if sk<.6 else 'regional' if sk<.8 else 'national'
        tws=float(d['tws']); w='light<6' if tws<6 else 'mid6-9' if tws<9 else 'fresh>=9'
        g[('all','all',int(d['k']))].append(float(d['err'])); g[(band,'all',int(d['k']))].append(float(d['err'])); g[('all',w,int(d['k']))].append(float(d['err']))
    print('##',n)
    print('| band | wind | n(k=4) | err m @4 s mean/p90 | @8 s mean/p90 | @12 s mean/p90 |'); print('|---|---|---|---|---|---|')
    for b,w in [('all','all'),('club','all'),('regional','all'),('national','all'),('all','light<6'),('all','mid6-9'),('all','fresh>=9')]:
        c=[]
        for k in (4,8,12):
            v=sorted(g.get((b,w,k),[]))
            c.append('%.1f / %.1f (n %d)'%(st.mean(v),v[int(.9*(len(v)-1))],len(v)) if v else '-')
        print('| %s | %s | %d | %s | %s | %s |'%(b,w,len(g.get((b,w,4),[])),*c))
