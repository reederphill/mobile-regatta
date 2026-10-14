import sys
for path in sys.argv[1:]:
    blocks=open(path).read().split('\n== ')[1:]
    for b in blocks:
        lines=[l for l in b.split('\n') if l.startswith('t ')]
        hdr=b.split('\n')[0].split(' gate ')[0]
        mark=hdr.split(' mark ')[1][0]
        rows=[]
        for l in lines:
            f=l.split()
            rows.append(dict(t=float(f[1]),leg=int(f[3]),st=int(f[5]),al=float(f[7]),up=float(f[9]),twa=float(f[11]),v=float(f[13]),tack=f[14],plan=f[16],pick=f[18],Lr=f[28],pen=int(f[30])))
        if not rows: continue
        needs = rows[0]['Lr'] if mark=='L' else ('S' if rows[0]['Lr']=='P' else 'P')
        cross=next((r for r in rows if r['st']==1 or r['leg']>rows[0]['leg']),None)
        picks=[]; 
        for r in rows:
            if r['up']<80 and (not picks or picks[-1]!=r['pick']) and r['pick']!='-': picks.append(r['pick'])
        gyb=[(r['t'],r['up'],r['tack']) for p,r in zip(rows,rows[1:]) if p['tack']!=r['tack'] and r['up']<60]
        pen=max(r['pen'] for r in rows)
        deep=min(r['up'] for r in rows)
        markal=-24.5 if mark=='L' else 24.5
        pre=[g for g in gyb if cross and g[0]<=cross['t']]
        post=[g for g in gyb if cross and g[0]>cross['t']]
        c=cross
        out=f"{hdr[:70]:70s} needs {needs} | cross {c['tack']} al {c['al']:.0f} v {c['v']:.1f} | picks {''.join(picks)} pen {pen} | gybes<line {[(round(g[1]),g[2]) for g in pre]} first>line {[(round(g[1]),g[2]) for g in post[:1]]}"
        print(out)
