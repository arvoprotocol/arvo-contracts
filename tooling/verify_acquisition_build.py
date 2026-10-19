#!/usr/bin/env python3
"""Read-only runtime, ABI and storage-layout verification after a clean build."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
def artifact(file,name):
    return json.loads((root/'out'/file/(name+'.json')).read_text())
new=artifact('ArvoStaking.sol','ArvoStaking')
old=artifact('ArvoStakingAuditedV1.sol','ArvoStakingAuditedV1')
escrow=artifact('ArvoAcquisitionEscrow.sol','ArvoAcquisitionEscrow')
factory=artifact('ArvoPoolCreation.sol','ArvoPoolCreation')
def shape(types,key):
    t=types[key]
    v={k:t[k] for k in ['encoding','label','numberOfBytes'] if k in t}
    for k in ['key','value','base']:
        if k in t:v[k]=shape(types,t[k])
    if 'members' in t:
        v['members']=[{'label':m['label'],'slot':m['slot'],'offset':m['offset'],
                       'type':shape(types,m['type'])} for m in t['members']]
    return v
a=old['storageLayout']; b=new['storageLayout']
assert len(b['storage'])>=len(a['storage']), 'Existing storage removed'
for previous,current in zip(a['storage'],b['storage']):
    for key in ['label','slot','offset']:
        assert previous[key]==current[key],f'Storage changed: {previous["label"]}'
    assert shape(a['types'],previous['type'])==shape(b['types'],current['type']),f'Type changed: {previous["label"]}'
def signature(item):
    def typ(x):
        return '('+','.join(typ(c) for c in x['components'])+')'+x['type'][5:] if x['type'].startswith('tuple') else x['type']
    return item['name']+'('+','.join(typ(x) for x in item.get('inputs',[]))+')'
current={signature(x):x for x in new['abi'] if x['type']=='function'}
for x in old['abi']:
    if x['type']=='function':
        key=signature(x)
        assert key in current,f'Existing function removed: {key}'
        assert x['outputs']==current[key]['outputs'],f'Output changed: {key}'
        assert x['stateMutability']==current[key]['stateMutability'],f'Mutability changed: {key}'
for name,item in [('staking',new),('escrow',escrow),('factory',factory)]:
    bytecode=item['deployedBytecode']['object'].removeprefix('0x')
    size=len(bytecode)//2
    assert size<=24576,f'{name} exceeds EIP-170: {size}'
    print(f'PASS: {name} runtime {size:,} / 24,576 bytes')
print('PASS: audited ca8b3d2 storage prefix and existing public ABI preserved')
print('No deployment, transactions, files, balances or services changed.')
