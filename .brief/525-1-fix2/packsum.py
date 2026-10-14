import json,sys
for f in sys.argv[1:]:
  d=json.load(open(f)); bs=[b for r in d['races'] for b in r['boats']]
  def m(k): v=[b[k] for b in bs if b.get(k) is not None]; return sum(v)/len(v), len(v)
  ex=m('extraMetres')[0]; dp=m('deepest')[0]
  sb=[b['stillBelow'] for b in bs if b.get('stillBelow') is not None]
  pe=[sum(b['extraMetres'] for b in r['boats'] if b['inPack'] and b.get('extraMetres') is not None) for r in d['races']]
  print(f.split('/')[-1], 'extra %.2f deepest %.2f below %.2f still %.3f packextra/race %.1f'%(ex,dp,m('belowSeconds')[0],sum(sb)/len(sb),sum(pe)/len(pe)))
