# #527 owner round 3: startKeepClear signature vs racing evasion; 10 s reruns of the committed subsets.
import json,sys,collections as C,statistics as S
d=[r for r in json.load(open(sys.argv[1])) if r['rule']!='31' and r['at5']]
def clean(c): return c['avoided'] and not c['anyCall'] and not c['ocs'] and not c['delayed'] and not c.get('lateCall',False)
def ok(cs): return {c['name'] for c in cs if clean(c)}
SCAN={'hold','luff10','luff20','luff40','bear10','bear20','bear40'}
def cause(r):
    b=r['brain']; o3=r['before3s']['offender']; oc=r['atCall']['offender']
    if oc['penalty'] or o3['penalty'] or 'penalty' in b.get('branches',{}): return 'penalty'
    if oc['tacking'] or o3['tacking']: return 'tack'
    if b.get('lineFallback',0)>0 and r['phase']=='preStart': return 'line'
    if b.get('targetedThird',0)>0: return 'third'
    if b.get('targetedOther',0)>0: return 'this'
    if b.get('keepClearDecisions',0)==0 and (oc['turning'] or o3['turning']): return 'plan'
    return 'straight'
def pct(x,n): return f'{x/n:.0%}' if n else '-'
def sig(name,rs):
    n=len(rs)
    if not n: print(name,0); return
    b=[r['brain'] for r in rs]
    off=sum(x.get('offDecisions',0) for x in b)
    cand=C.Counter(k for r in rs for k in ok(r['at5']))
    print(f'\n== {name}: n={n}')
    print('  hold clean',pct(cand['hold'],n),'| tack',pct(cand['tack'],n),'| best heading',pct(sum(bool(ok(r['at5'])&SCAN) for r in rs),n),
          '| only ease/tack/gybe',pct(sum(bool(ok(r['at5'])) and not ok(r['at5'])&SCAN for r in rs),n),'| nothing',pct(sum(not ok(r['at5']) for r in rs),n))
    print('  candidates', {k:pct(v,n) for k,v in sorted(cand.items())})
    print('  toggled 2+',pct(sum(x['toggles']>=2 for x in b),n),'| mean |offset| deg',round(S.mean(x['meanHeadingDeltaDeg'] for x in b),1),
          '| median max offset',round(S.median(x['maxHeadingDeltaDeg'] for x in b),0),
          '| off decisions that luff',pct(sum(x.get('luffs',0) for x in b),off),'| toward the called boat',pct(sum(x.get('towardOther',0) for x in b),off),
          '| mean signed (+luff)',round(S.mean(x.get('meanLuffDeg',0) for x in b if x.get('offDecisions',0)),1) if off else '-')
    print('  keep-clear share of decisions',round(S.mean(x['keepClearShare'] for x in b),2),'| isAboutToHit on her',pct(sum(x['aboutToHitOther']>0 for x in b),n),
          '| evasion aimed at a third boat',pct(sum(x['targetedThird']>0 for x in b),n))
    print('  cause',dict(C.Counter(cause(r) for r in rs).most_common()))
    print('  rule',dict(C.Counter(r['rule'] for r in rs).most_common(6)),'| geometry',dict(C.Counter(r['geometryClass'] for r in rs).most_common(5)))
    print('  her tack at call',dict(C.Counter(r['atCall']['offender']['tack'] for r in rs)),'| her speed share median',round(S.median(r['atCall']['offender']['speedShare'] for r in rs),2),
          '| other stopped',pct(sum(r['atCall']['other']['stopped'] for r in rs),n),'| line m median',round(S.median(r['atCall']['lineM'] for r in rs),1))
pre=[r for r in d if r['seconds']<0]
skc=[r for r in pre if r['brain'].get('startKeepClear',0)>0]
rkc_pre=[r for r in pre if r['brain'].get('ruleKeepClearPath',0)>0 and not r['brain'].get('startKeepClear',0)]
racing_ev=[r for r in d if r['seconds']>=0 and cause(r) in ('this','third')]
print('pre-start calls',len(pre))
sig('pre-start, startKeepClear in the 5 s before',skc)
sig('  of which startKeepClear only (no rule path, no line)',[r for r in skc if not r['brain'].get('ruleKeepClearPath',0) and not r['brain'].get('lineFallback',0)])
sig('pre-start, ruleKeepClear path only',rkc_pre)
sig('racing, evading (this or third boat)',racing_ev)
print('\n==== 10 s')
idt=[r for r in d if r.get('identity10')]
print('identity from T-10 s: same pair called',sum(1 for r in idt if not r['identity10']['avoided']),'/',len(idt))
def ten(name,rs):
    rs=[r for r in rs if r['at10']]; n=len(rs)
    if not n: print(name,'no 10 s forks'); return
    c10=C.Counter(k for r in rs for k in ok(r['at10']))
    print(f'{name}: n={n}; anything clean from 10 s {pct(sum(bool(ok(r["at10"])) for r in rs),n)}; hold {pct(c10["hold"],n)}; heading {pct(sum(bool(ok(r["at10"])&SCAN) for r in rs),n)}; tack {pct(c10["tack"],n)}')
    print('   phase',dict(C.Counter(r['phase'] for r in rs)),'| cause',dict(C.Counter(cause(r) for r in rs).most_common()),'| rule',dict(C.Counter(r['rule'] for r in rs).most_common(5)))
nothing5=[r for r in d if not ok(r['at5'])]
ten('nothing avoids from 5 s',nothing5)
ten('  racing',[r for r in nothing5 if r['seconds']>=0]); ten('  pre-start',[r for r in nothing5 if r['seconds']<0])
line=[r for r in d if cause(r)=='line']
ten('line fallback (all)',line)
ten('line fallback, not avoided by holding from 5 s',[r for r in line if 'hold' not in ok(r['at5'])])
ten('all calls (reference)',d)
