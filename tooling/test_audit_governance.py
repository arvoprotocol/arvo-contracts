import copy
import hashlib
import unittest
from unittest.mock import patch
import audit_governance as gate

def hash_value(value):
    return '0x'+hashlib.sha256(value.encode()).hexdigest()
def addr(n):
    return '0x'+hex(n)[2:].zfill(40)
def encode(values):
    return '0x'+''.join(gate.word(v) for v in values)

class AuditTests(unittest.TestCase):
    def setUp(self):
        self.hash_patch=patch.object(gate,'keccak',hash_value); self.hash_patch.start();self.addCleanup(self.hash_patch.stop)
        self.c={'chainId':31337,'stakingProxy':addr(10),'deploymentAdmin':addr(11),'governanceSafe':addr(12),'emergencyAuthority':addr(13),'timelock':addr(14),'timelockDelay':172800,'safeOwners':[addr(20),addr(21),addr(22)],'safeThreshold':2,'safeFallbackHandler':gate.ZERO}
        for field in ('stakingProxyCodeHash','stakingImplementationCodeHash','timelockCodeHash','safeProxyCodeHash','safeSingletonCodeHash'):
            self.c[field]=hash_value('0x6000')
        self.staking={ '0x'+'00'*32:{addr(14),addr(11)},hash_value('UPGRADER_ROLE'):{addr(14),addr(11)},hash_value('VAULT_MANAGER_ROLE'):{addr(12),addr(11)},hash_value('REWARD_MANAGER_ROLE'):{addr(12),addr(11)},hash_value('PAUSER_ROLE'):{addr(13),addr(11)}}
        self.timelock={'0x'+'00'*32:{addr(14)},hash_value('PROPOSER_ROLE'):{addr(12)},hash_value('CANCELLER_ROLE'):{addr(12)},hash_value('EXECUTOR_ROLE'):{addr(12)}}
        self.empty_safe=False;self.modules=[];self.guard=gate.ZERO;self.revoked=[];self.chain=31337
    def rpc(self,method,params):
        if method=='eth_chainId':return hex(self.chain)
        if method=='eth_blockNumber':return '0x80'
        if method=='eth_getBlockByNumber':return {'hash':'0x'+'ab'*32}
        if method=='eth_getCode':return '0x' if self.empty_safe and params[0]==addr(12) else '0x6000'
        if method=='eth_getStorageAt':
            target,slot,_=params
            if slot==gate.IMPLEMENTATION_SLOT:return encode([30])
            if slot=='0x0':return encode([31])
            if slot==hash_value('guard_manager.guard.address'):return encode([int(self.guard,16)])
            return encode([0])
        if method=='eth_getLogs':
            target=params[0]['address'];roles=self.staking if target==addr(10) else self.timelock
            entries=[]
            for role,holders in roles.items():
                for account in holders:
                    entries.append({'topics':[hash_value('RoleGranted(bytes32,address,address)'),role,'0x'+gate.word(int(account,16)),'0x'+gate.word(11)],'blockNumber':'0x1','logIndex':hex(len(entries))})
            for role,account in self.revoked:
                for action in ('RoleGranted','RoleRevoked'):
                    entries.append({'topics':[hash_value(action+'(bytes32,address,address)'),role,'0x'+gate.word(int(account,16)),'0x'+gate.word(11)],'blockNumber':'0x2','logIndex':hex(len(entries))})
            return entries
        if method=='eth_call':
            tx,_=params;data=tx['data'];head=data[:10]
            if head==gate.selector('getOwners()'):return encode([32,len(self.c['safeOwners'])]+[int(v,16) for v in self.c['safeOwners']])
            if head==gate.selector('getThreshold()'):return encode([2])
            if head==gate.selector('getModulesPaginated(address,uint256)'):return encode([64,1,len(self.modules)]+[int(v,16) for v in self.modules])
            if head==gate.selector('getMinDelay()'):return encode([172800])
            if head==gate.selector('hasRole(bytes32,address)'):
                role='0x'+data[10:74];account=addr(int(data[74:],16)); roles=self.staking if tx['to']==addr(10) else self.timelock
                return encode([int(account in roles.get(role,set()))])
        raise AssertionError(method)
    def passes(self,phase='staged'):gate.audit(self.c,self.rpc,phase)
    def fails(self):
        with self.assertRaises(gate.AuditError):self.passes()
    def test_valid_staged(self):self.passes()
    def test_valid_final(self):
        for holders in self.staking.values():holders.discard(addr(11))
        self.passes('final')
    def test_extra_upgrader_rejected(self):self.staking[hash_value('UPGRADER_ROLE')].add(addr(99));self.fails()
    def test_extra_admin_rejected(self):self.staking['0x'+'00'*32].add(addr(99));self.fails()
    def test_timelock_extra_executor_rejected(self):self.timelock[hash_value('EXECUTOR_ROLE')].add(gate.ZERO);self.fails()
    def test_eoa_safe_rejected(self):self.empty_safe=True;self.fails()
    def test_single_signature_rejected(self):self.c['safeThreshold']=1;self.fails()
    def test_modules_rejected(self):self.modules=[addr(40)];self.fails()
    def test_guard_rejected(self):self.guard=addr(40);self.fails()
    def test_unapproved_code_rejected(self):self.c['timelockCodeHash']='0x'+'ff'*32;self.fails()
    def test_wrong_chain_rejected(self):self.chain=1;self.fails()
    def test_revoked_extra_role_not_active(self):self.revoked=[(hash_value('UPGRADER_ROLE'),addr(99))];self.passes()
    def test_missing_role_rejected(self):self.staking[hash_value('UPGRADER_ROLE')].discard(addr(14));self.fails()
    def test_malformed_abi_rejected(self):
        with self.assertRaises(gate.AuditError):gate.array_at([64,1],64)

if __name__=='__main__':unittest.main()
