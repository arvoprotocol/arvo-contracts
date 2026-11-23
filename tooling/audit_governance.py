#!/usr/bin/env python3
"""Read-only governance release gate. No private keys or transactions."""
from functools import lru_cache
import argparse
import json
import os
import subprocess
import urllib.error
import urllib.request

ZERO = '0x' + '00' * 20
SENTINEL = '0x' + '00' * 19 + '01'
IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

class AuditError(Exception):
    pass

def require(condition, message):
    if not condition:
        raise AuditError(message)

def address(value):
    require(isinstance(value, str) and len(value) == 42 and value.startswith('0x'), 'Invalid address')
    int(value[2:], 16)
    return value.lower()

def word(value):
    return hex(value)[2:].zfill(64)

@lru_cache(maxsize=256)
def keccak(value):
    return subprocess.check_output([os.environ.get('ARVO_CAST', 'cast'), 'keccak', value], text=True).strip().lower()

def selector(signature):
    return keccak(signature)[:10]

def words(data):
    require(data.startswith('0x') and len(data[2:]) % 64 == 0, 'Invalid ABI return')
    return [int(data[i:i+64], 16) for i in range(2, len(data), 64)]

def array_at(values, offset):
    require(offset % 32 == 0 and offset // 32 < len(values), 'Invalid ABI array offset')
    index = offset // 32
    size = values[index]
    require(size <= 1000 and index + size < len(values), 'Invalid ABI array length')
    return [address('0x' + word(v)[-40:]) for v in values[index+1:index+1+size]]

class RPC:
    def __init__(self, url):
        require(url.startswith(('http://', 'https://')), 'RPC URL missing or invalid')
        self.url = url
    def __call__(self, method, params):
        payload = json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode()
        # Some public RPCs (behind Cloudflare) refuse Python's default User-Agent with HTTP 403.
        request = urllib.request.Request(self.url, data=payload, headers={'Content-Type':'application/json','Accept':'application/json','User-Agent':'arvo-governance-audit/1.0'})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    result = json.load(response)
                break
            except urllib.error.HTTPError as error:
                # Rate limited: wait and retry. Report only the status code, never the URL (it may hold a key).
                if error.code == 429 and attempt < 3:
                    __import__('time').sleep(2 ** attempt)
                    continue
                raise AuditError('RPC returned HTTP %d for %s' % (error.code, method)) from None
        require('error' not in result and 'result' in result, 'RPC operation failed: ' + method)
        return result['result']

def audit(config, rpc, phase):
    chain = int(rpc('eth_chainId', []), 16)
    require(chain == config['chainId'], 'Wrong chain')
    block = rpc('eth_blockNumber', [])
    height = int(block, 16)
    header = rpc('eth_getBlockByNumber', [block, False])
    fields = ('stakingProxy','deploymentAdmin','governanceSafe','emergencyAuthority','timelock')
    staking, admin, safe, emergency, timelock = [address(config[k]) for k in fields]
    require(ZERO not in (staking,admin,safe,emergency,timelock), 'Zero authority address')
    require(len({staking,admin,safe,timelock}) == 4 and emergency not in (staking,admin,timelock), 'Overlapping authority addresses')
    require(config['timelockDelay'] >= 86400, 'Timelock shorter than one day')
    def call(target, signature, args=''):
        return words(rpc('eth_call', [{'to':target,'data':selector(signature)+args}, block]))
    def code_hash(target, expected):
        code = rpc('eth_getCode', [target, block])
        require(code not in ('0x','0x0'), 'Authority has no code: '+target)
        require(keccak(code) == expected.lower(), 'Unapproved runtime code: '+target)
    code_hash(staking, config['stakingProxyCodeHash'])
    implementation = address('0x'+rpc('eth_getStorageAt',[staking,IMPLEMENTATION_SLOT,block])[-40:])
    code_hash(implementation, config['stakingImplementationCodeHash'])
    code_hash(timelock, config['timelockCodeHash'])
    code_hash(safe, config['safeProxyCodeHash'])
    singleton = address('0x'+rpc('eth_getStorageAt',[safe,'0x0',block])[-40:])
    code_hash(singleton, config['safeSingletonCodeHash'])
    owners_raw = call(safe,'getOwners()')
    owners = array_at(owners_raw, owners_raw[0])
    approved = [address(v) for v in config['safeOwners']]
    require(len(approved)>=2 and len(set(approved))==len(approved) and ZERO not in approved, 'Approve at least two distinct Safe owners')
    require(len(owners)==len(approved) and set(owners)==set(approved), 'Safe owner mismatch')
    threshold = call(safe,'getThreshold()')[0]
    require(2 <= threshold <= len(owners) and threshold == config['safeThreshold'], 'Safe threshold mismatch')
    modules = call(safe,'getModulesPaginated(address,uint256)',word(int(SENTINEL,16))+word(1000))
    require(modules[1] == int(SENTINEL,16) and not array_at(modules,modules[0]), 'Enabled Safe modules require separate review')
    for slot_name in ('guard_manager.guard.address','fallback_manager.handler.address'):
        slot = keccak(slot_name)
        value = address('0x'+rpc('eth_getStorageAt',[safe,slot,block])[-40:])
        expected = ZERO if slot_name.startswith('guard_') else address(config['safeFallbackHandler'])
        require(value == expected, 'Safe guard or fallback handler mismatch')
    fallback = address(config['safeFallbackHandler'])
    if fallback != ZERO:
        code_hash(fallback, config['safeFallbackHandlerCodeHash'])
    require(call(timelock,'getMinDelay()')[0] == config['timelockDelay'], 'Timelock delay mismatch')
    granted = keccak('RoleGranted(bytes32,address,address)')
    revoked = keccak('RoleRevoked(bytes32,address,address)')
    def first_block(target, tx_field):
        # A contract cannot emit events before it exists. If the manifest names the transaction that
        # created the contract, start at that block, but only after checking on chain that this
        # transaction succeeded and created exactly this address. Otherwise scan from genesis.
        tx = config.get(tx_field)
        if not tx:
            return 0
        require(isinstance(tx, str) and len(tx) == 66 and tx.startswith('0x'), 'Invalid deployment transaction hash')
        receipt = rpc('eth_getTransactionReceipt', [tx])
        require(isinstance(receipt, dict) and receipt.get('status') == '0x1', 'Deployment transaction not found or failed')
        require(address(receipt.get('contractAddress') or ZERO) == target, 'Deployment transaction did not create '+target)
        start = int(receipt['blockNumber'], 16)
        require(start <= height, 'Deployment block is after the audited block')
        return start
    def roles(target, expected, tx_field):
        # Scan from the verified creation block (or genesis), never an unverified start that could omit grants.
        observed = {}
        for start in range(first_block(target, tx_field),height+1,2000):
            logs = rpc('eth_getLogs',[{'address':target,'fromBlock':hex(start),'toBlock':hex(min(height,start+1999)), 'topics':[[granted,revoked]]}])
            logs.sort(key=lambda entry:(int(entry['blockNumber'],16),int(entry['logIndex'],16)))
            for event in logs:
                require(not event.get('removed',False) and len(event['topics'])==4, 'Invalid role event')
                role = event['topics'][1].lower()
                account = address('0x'+event['topics'][2][-40:])
                holders = observed.setdefault(role,set())
                if event['topics'][0].lower()==granted:
                    holders.add(account)
                else:
                    holders.discard(account)
        for role in set(expected)|set(observed):
            actual = observed.get(role,set())
            wanted = expected.get(role,set())
            require(actual == wanted, 'Unexpected complete role-holder set: '+target+' role '+role)
            for account in actual|wanted:
                require(call(target,'hasRole(bytes32,address)',role[2:]+word(int(account,16)))[0]==1, 'Role event/state mismatch')
    default = '0x'+'00'*32
    staking_roles = {default:{timelock},keccak('UPGRADER_ROLE'):{timelock},keccak('VAULT_MANAGER_ROLE'):{safe},keccak('REWARD_MANAGER_ROLE'):{safe},keccak('PAUSER_ROLE'):{emergency}}
    if phase=='staged':
        for holders in staking_roles.values():
            holders.add(admin)
    roles(staking,staking_roles,'stakingProxyDeploymentTx')
    roles(timelock,{default:{timelock},keccak('PROPOSER_ROLE'):{safe},keccak('CANCELLER_ROLE'):{safe},keccak('EXECUTOR_ROLE'):{safe}},'timelockDeploymentTx')
    require(rpc('eth_getBlockByNumber',[block,False])['hash'] == header['hash'], 'Chain reorganized during audit; rerun')
    return [int(staking,16),int(admin,16),int(safe,16),int(emergency,16),int(timelock,16),config['timelockDelay'],chain]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--phase',choices=('staged','final'),required=True)
    parser.add_argument('--ffi',action='store_true')
    args=parser.parse_args()
    with open(args.config) as file:
        config=json.load(file)
    result=audit(config,RPC(os.environ.get('ARVO_GOVERNANCE_RPC','')),args.phase)
    if args.ffi:
        print('0x'+''.join(word(value) for value in result))
    else:
        print('PASS: approved Safe configuration, code provenance and complete governance role sets ('+args.phase+'). Read-only; no transactions sent.')

if __name__=='__main__':
    try:
        main()
    except Exception as error:
        # RPC URLs can contain credentials; never display network exception text.
        print('Governance audit FAILED: '+(str(error) if isinstance(error,AuditError) else type(error).__name__),file=__import__('sys').stderr)
        raise SystemExit(1)
