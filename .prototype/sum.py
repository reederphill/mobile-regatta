#!/usr/bin/env python3
"""Summarise botsuite --diagnose outputs: python3 .prototype/sum.py name [name...] (reads .prototype/results/<name>.txt)."""
import re, sys, os
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
TIERS = ('club', 'regional', 'national')

def summ(path):
    L = open(path).read().split('\n')
    o = {'races': L[0].split(',')[0], 'fin': {}, 'marks': {}, 'calls': {}, 'racing': 0, 'place': {}}
    for l in L:
        m = re.match(r'^(club|regional|national): (\d+)/(\d+) finished.*marks ([\d.]+)/boat.*racing (\d+)/(\d+)\)', l)
        if m:
            o['fin'][m[1]] = int(m[2]) / int(m[3]); o['marks'][m[1]] = float(m[4]); o['racing'] += int(m[5])
        m = re.match(r'^  (club|regional|national) calls: (.*?);', l)
        if m:
            o['calls'][m[1]] = {k: int(v) for k, v in re.findall(r'(\d+(?:\.\d)?) (\d+)(?:,|$)', m[2])}
        m = re.match(r'^  by skill: (.*)$', l)
        if m:
            o['place'] = {k: float(v) for k, v in re.findall(r'(club|regional|national) ([\d.]+) \(', m[1])}
    i = [k for k, l in enumerate(L) if l.startswith('roundings by tier')][0]
    R = {}
    for l in L[i + 2:i + 18]:
        f = l.split()
        if len(f) < 9: continue
        tier, mark, n, mean = f[0], f[1], int(f[2]), float(f[3])
        d = dict(n=n, mean=mean, med=float(f[4]), p90=float(f[6]), s30=float(f[7]), s50=float(f[8]))
        if mark == 'gate' and len(f) >= 24:
            d.update(over=int(f[10]), e2em=float(f[12]), e2es=float(f[13]), e2es90=float(f[16]), below=float(f[17]),
                     deepest=float(f[21]), still=int(f[23]))
        R[(tier, mark)] = d
    o['R'] = R
    i = [k for k, l in enumerate(L) if l.startswith('legs by tactics')][0]
    agg = {}
    for l in L[i + 2:]:
        m = re.match(r'^\s+(club|regional|national)\s+(club|regional|national)\s+(first beat|later beats|reaches|runs|last run)\s+(.*)$', l)
        if not m: break
        f = m[4].replace(' / ', '/').split()
        legs = int(f[1])
        a = agg.setdefault(m[3], dict(legs=0, gybes=0, calls=0, t31=0))
        a['legs'] += legs; a['gybes'] += float(f[9]) * legs
        calls = [float(x) * legs for x in f[10:19]]
        a['t31'] += calls[-1]; a['calls'] += sum(calls[:-1])
    o['legs'] = agg
    o['gate'] = ([l for l in L if l.startswith('gate:')] or [''])[0]
    o['tick'] = ([l for l in L if l.startswith('tick:')] or [''])[0]
    return o

def row(name, o):
    g = o['R'][('all', 'gate')]
    ru = o['legs']['runs']
    c = lambda t: f"{o['R'][(t, 'gate')]['mean']:.1f}"
    s = (f"{name:12s} gate n={g['n']} mean {g['mean']:5.1f} med {g['med']:5.1f} p90 {g['p90']:5.1f} >=30 {g['s30']:.3f} >=50 {g['s50']:.3f}"
         f" | e2e {g.get('e2em', 0):.1f} m {g.get('e2es', 0):.1f} s (p90 {g.get('e2es90', 0):.1f}) below {g.get('below', 0):.1f} s deepest {g.get('deepest', 0):.1f} over {g.get('over', 0)} still {g.get('still', 0)}"
         f" | by tier {c('club')}/{c('regional')}/{c('national')}"
         f" | runs gybes {ru['gybes'] / ru['legs']:.2f} calls {ru['calls']:.0f} t31 {ru['t31']:.0f}"
         f" | marks C/R/N {o['marks']['club']:.2f}/{o['marks']['regional']:.2f}/{o['marks']['national']:.2f}"
         f" | racing fouls {o['racing']} | fin C/R/N {o['fin']['club']:.3f}/{o['fin']['regional']:.3f}/{o['fin']['national']:.3f}"
         f" | place C/R/N {o['place'].get('club', 0):.2f}/{o['place'].get('regional', 0):.2f}/{o['place'].get('national', 0):.2f}")
    return s

if __name__ == '__main__':
    for n in sys.argv[1:]:
        print(row(n, summ(os.path.join(D, n + '.txt'))))
