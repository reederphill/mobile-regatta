# #527 critique: strict recount at call + 8 s, cause table, pre-start keep-clear path split.
import json,sys,collections as C
d=[r for r in json.load(open(sys.argv[1])) if r['rule']!='31']
def clean(c): return c['avoided'] and not c['anyCall'] and not c['ocs'] and not c['delayed'] and not c.get('lateCall',False)
SCAN={'hold','luff10','luff20','luff40','bear10','bear20','bear40'}
rs=[r for r in d if r['at5']]; n=len(rs)
def ok(r): return {c['name'] for c in r['at5'] if clean(c)}
cat=C.Counter('a' if ok(r)&SCAN else 'b' if ok(r) else 'd' for r in rs)
print('calls with candidates',n,{k:f'{v} ({v/n:.0%})' for k,v in sorted(cat.items())})
per=C.Counter(k for r in rs for k in ok(r)); print('each candidate clean:',{k:f'{v/n:.0%}' for k,v in sorted(per.items())})
def cause(r):
    b=r['brain']; o3=r['before3s']['offender']; oc=r['atCall']['offender']
    if oc['penalty'] or o3['penalty'] or 'penalty' in b.get('branches',{}): return '1 penalty turn'
    if oc['tacking'] or o3['tacking']: return '2 tack/gybe'
    if b.get('lineFallback',0)>0 and r['phase']=='preStart': return '3 line fallback'
    if b.get('targetedThird',0)>0: return '4 evading a third boat'
    if b.get('targetedOther',0)>0: return '5 evading this boat'
    if b.get('keepClearDecisions',0)==0 and (oc['turning'] or o3['turning']): return '6 plan turn, no evasion'
    return '7 straight, no evasion'
hold=lambda r:'hold' in ok(r)
cc=C.Counter(cause(r) for r in rs); hc=C.Counter(cause(r) for r in rs if hold(r))
print('cause: all / hold-clean'); [print(f'  {k:28} {cc[k]:4} ({cc[k]/n:.0%})  {hc[k]:4}') for k in sorted(cc)]
print('hold clean total',sum(hc.values()),f'{sum(hc.values())/n:.0%}')
def path(r):
    b=r['brain']
    if b.get('startKeepClear',0)>0 and b.get('ruleKeepClearPath',0)>0: return 'both'
    if b.get('startKeepClear',0)>0: return 'startKeepClear'
    if b.get('ruleKeepClearPath',0)>0: return 'ruleKeepClear'
    if b.get('lineFallback',0) or b.get('lineKept',0): return 'line'
    return 'no keep-clear'
pre=[r for r in rs if r['seconds']<0]
print('pre-start (tick<0)',len(pre),dict(C.Counter(path(r) for r in pre)))
top=[r for r in rs if r['seconds']<0 and r['rule']=='10' and r['geometryClass']=='port/starboard crossing']
print('rule10 pre-start port/stbd',len(top),dict(C.Counter(path(r) for r in top)),'hold clean',sum(map(hold,top)))
for rule in ['11','15','13','16.1']:
    t=[r for r in pre if r['rule']==rule]; print(' pre',rule,len(t),dict(C.Counter(path(r) for r in t)))
