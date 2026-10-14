import json,sys
b=json.load(open(sys.argv[1]));n=json.load(open(sys.argv[2]))
def key(r): L=r['layout']; return (r['seed'],L['size'],int(L['offset']),L['gybes'],int(L['current']))
bm={key(r):r for r in b['races']}
rows=[];cnt={}
for r in n['races']:
  br=bm[key(r)]
  for x,y in zip(br['boats'],r['boats']):
    if y.get('deepest') is None or x.get('deepest') is None: continue
    sw = x.get('markUsed')!=y.get('markUsed')
    c=cnt.setdefault(sw,[0,0,0,0,0]); c[0]+=1; c[1]+=x['deepest']; c[2]+=y['deepest']; c[3]+=x['stillBelow']; c[4]+=y['stillBelow']
    rows.append((round(y['deepest']-x['deepest'],1),round(x['deepest'],1),round(y['deepest'],1),y['stillBelow'],key(r),y['seat'],x.get('markUsed'),y.get('markUsed')))
for k,c in cnt.items(): print('switched' if k else 'same', c[0], 'deepest %.1f -> %.1f still %d -> %d'%(c[1]/c[0],c[2]/c[0],c[3],c[4]))
rows.sort(reverse=True)
for r in rows[:int(sys.argv[3]) if len(sys.argv)>3 else 12]: print(r)
