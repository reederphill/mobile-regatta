import json,sys,collections as C
d=[r for r in json.load(open(sys.argv[1])) if r['rule']!='31']
print('calls',len(d))
def clean(c): return c['avoided'] and not c['anyCall'] and not c['ocs'] and not c['delayed']
OWN={'hold','luff10','luff20','bear10','bear20'}  # within a modest own-tack scan
SCAN={'hold','luff10','luff20','luff40','bear10','bear20','bear40'}
cnt=C.Counter(); n=0
per=C.Counter()
for r in d:
    cs=r['at5']
    if not cs: cnt['nocf']+=1; continue
    n+=1
    ok={c['name'] for c in cs if clean(c)}
    for k in ok: per[k]+=1
    third=r['brain'].get('targetedThird',0)>0
    if ok & SCAN: cat='a'
    elif ok: cat='b'
    else: cat='d'
    if third and cat in 'ab': cnt['c_overlay']+=1
    cnt[cat]+=1
    if not ok & SCAN and not ok: 
        if r.get('avoidable10'): cnt['d10']+=1
    if 'hold' in ok: cnt['holdclean']+=1
print('with candidates',n, dict(cnt))
print({k:round(v/n,3) for k,v in sorted(per.items())})
# what did brain do on hold-clean calls?
hc=[r for r in d if r['at5'] and any(c['name']=='hold' and clean(c) for c in r['at5'])]
ev=C.Counter(); br=C.Counter()
for r in hc:
    b=r['brain']; ev['keepClear>0' if b.get('keepClearDecisions',0)>0 else 'noKeepClear']+=1
    ev['tacked/turning offender at call' if r['atCall']['offender']['turning'] or r['atCall']['offender']['tacking'] else 'straight at call']+=1
    ev['wantsOtherTack' if b.get('wantsOtherTack',0)>0 else 'noTackWanted']+=1
    for k in b.get('branches',{}): br[k]+=1
print('hold-clean',len(hc),dict(ev)); print(br.most_common(8))
print('--- attribution, all calls with candidates (first that holds)')
def cause(r):
    b=r['brain']; o3=r['before3s']['offender']; oc=r['atCall']['offender']
    if oc['penalty'] or o3['penalty'] or 'penalty' in b.get('branches',{}): return '1 her own penalty turn'
    if oc['tacking'] or o3['tacking']: return '2 her tack/gybe'
    if b.get('startKeepClear',0)>0 and r['phase']=='preStart' and b.get('lineFallback',0)>0: return '3 line fallback'
    if b.get('targetedThird',0)>0: return '4 evading a third boat'
    if b.get('targetedOther',0)>0: return '5 evading this boat (not enough / wrong way)'
    if b.get('keepClearDecisions',0)==0 and (oc['turning'] or o3['turning']): return '6 plan turn, no evasion'
    return '7 straight, no evasion'
for grp,sel in [('all',lambda r:True),('hold clean',lambda r:any(c['name']=='hold' and clean(c) for c in r['at5'])),('hold not clean',lambda r:not any(c['name']=='hold' and clean(c) for c in r['at5']))]:
    rs=[r for r in d if r['at5'] and sel(r)]
    cc=C.Counter(cause(r) for r in rs)
    print(grp,len(rs),{k:v for k,v in sorted(cc.items())})
print('--- by rule: n, hold-clean share, cause mix')
for rule in ['11','10','15','13','16.1','21.2']:
    rs=[r for r in d if r['at5'] and r['rule']==rule]
    hcl=sum(any(c['name']=='hold' and clean(c) for c in r['at5']) for r in rs)
    cc=C.Counter(cause(r)[0] for r in rs)
    print(rule,len(rs),round(hcl/len(rs),2),dict(sorted(cc.items())))
