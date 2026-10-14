#!/usr/bin/env python3
"""Q1 measures from the PK lines: python3 .prototype/pk.py name [name...] (reads .prototype/results/<name>.err)."""
import re, sys, os, collections
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')

def load(name):
    rows = []
    for l in open(os.path.join(D, name + '.err')):
        if not l.startswith('PK '): continue
        f = l.split()
        d = dict(x.split('=', 1) for x in f[2:])
        v, c, seed, fleet = f[1].split(':')
        d.update(race=f[1], venue=v.split('@')[0], cur=v.startswith('saltings-reach'), fleet=int(fleet), seat=int(d['seat']),
                 leg=int(d['leg']), nb=[(int(x.split('/')[0]), float(x.split('/')[1])) for x in d['nb'].split(',') if x], mark=int(d['mark']), ent=int(d['ent']),
                 out=int(d['out']), out0=int(d['out0']), dirtyS=float(d['dirtyS']), dirtyM=float(d['dirtyM']), e2eX=float(d['e2eX']),
                 e2em=float(d['e2em']), e2es=float(d['e2es']), over=int(d['over']), below=float(d['below']))
        d['pack'] = sum(1 for _, m in d['nb'] if m < 20) >= 2
        d['pack40'] = len(d['nb']) >= 2
        d['pair'] = any(m < 20 for _, m in d['nb'])
        rows.append(d)
    return rows

def mean(xs): xs = list(xs); return sum(xs) / len(xs) if xs else float('nan')

def packs(rows):
    by = {(r['race'], r['leg'], r['seat']): r for r in rows}
    seen = {}
    for r in rows:
        if r['pack']:
            key = (r['race'], r['leg'], frozenset([r['seat']] + [s for s, m in r['nb'] if m < 20]))
            seen[key] = r
    res = []
    for (race, leg, members), r in seen.items():
        marks = [by[(race, leg, s)]['mark'] for s in members if (race, leg, s) in by]
        res.append((race, len(members), len(marks), len(set(marks)) > 1))
    return res

def table(name, rows, groups):
    print(f'## {name}')
    print('| group | roundings | in a pack (>=3 within 20 m) | a boat within 20 m | pack within 40 m | unique packs | packs using one mark | entitled roundings | passed outside while entitled (>=1 hull / any) | dirty air s/rounding (inside 80 m) | share with dirty air | dirty m | e2e extra m: pack / not | e2e extra m: dirty / not |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    for g, sel in groups:
        rs = [r for r in rows if sel(r)]
        if not rs: continue
        pk = packs(rs)
        one = [p for p in pk if p[2] >= 2 and not p[3]]
        ent = [r for r in rs if r['ent']]
        out = [r for r in ent if r['out']]
        dirty = [r for r in rs if r['dirtyS'] > 0]
        print(f"| {g} | {len(rs)} | {sum(r['pack'] for r in rs)} ({100*sum(r['pack'] for r in rs)/len(rs):.0f}%) | {100*sum(r['pair'] for r in rs)/len(rs):.0f}% | {100*sum(r['pack40'] for r in rs)/len(rs):.0f}% | {len(pk)} | "
              f"{len(one)} ({100*len(one)/max(1,len([p for p in pk if p[2]>=2])):.0f}%) | {len(ent)} ({100*len(ent)/len(rs):.0f}%) | {len(out)} ({100*len(out)/max(1,len(ent)):.0f}%) / {sum(r['out0'] for r in ent)} | "
              f"{mean(r['dirtyS'] for r in rs):.2f} | {len(dirty)/len(rs):.2f} | {mean(r['dirtyM'] for r in rs):.1f} | "
              f"{mean(r['e2eX'] for r in rs if r['pack']):.1f} / {mean(r['e2eX'] for r in rs if not r['pack']):.1f} | "
              f"{mean(r['e2eX'] for r in dirty):.1f} / {mean(r['e2eX'] for r in rs if r['dirtyS']==0):.1f} |")

if __name__ == '__main__':
    for n in sys.argv[1:]:
        rows = load(n)
        groups = [('all', lambda r: True), ('current (saltings-reach)', lambda r: r['cur']), ('no current', lambda r: not r['cur'])]
        groups += [(f'tier {t}', (lambda t: lambda r: r['tier'] == t)(t)) for t in ('club', 'regional', 'national')]
        groups += [(f'venue {v}', (lambda v: lambda r: r['venue'] == v)(v)) for v in sorted({r['venue'] for r in rows})]
        table(n, rows, groups)
