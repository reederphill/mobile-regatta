import json,sys,os
base=json.load(open(sys.argv[1]))['matrix']; out=sys.argv[2]; seeds=json.loads(sys.argv[3]); cells=json.loads(sys.argv[4]) if len(sys.argv)>4 else None
cv=base['conditionsByVenue']
for v in base['venues']:
  for c in cv.get(v,base['conditions']):
    if cells and [v,c] not in cells: continue
    for s in (seeds if seeds!='split' else [None]):
      m=dict(base); m['venues']=[v]; m['conditions']=[c]; m['conditionsByVenue']={v:[c]} if v in cv else {}; m['seeds']=s if isinstance(s,list) else [s]
      n=f"{v}__{c}__{'-'.join(map(str,m['seeds']))}".replace('@','_')
      json.dump(m,open(f'{out}/{n}.json','w')); print(n)
