#!/usr/bin/env python3
"""Drafts the governance audit manifest from the live chain. Read-only; no keys, no transactions.

The manifest pins what audit_governance.py must find: addresses, runtime code hashes, Safe owners,
threshold and fallback handler. This tool reads them from the chain so nothing is typed by hand,
then prints a summary. Check the Safe owners and threshold against the Safe app yourself before
using the file; the audit is only as good as that review.

  export ARVO_GOVERNANCE_RPC=https://...
  python3 tooling/make_governance_manifest.py --out mainnet-governance.json \\
    --chain-id 4663 --staking-proxy 0x... --deployment-admin 0x... --governance-safe 0x... \\
    --emergency 0x... --timelock 0x... --timelock-delay 86400 \\
    --staking-tx 0x... --timelock-tx 0x...
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_governance as gate  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    for name in ('out', 'staking-proxy', 'deployment-admin', 'governance-safe', 'emergency', 'timelock', 'staking-tx', 'timelock-tx'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--chain-id', type=int, required=True)
    p.add_argument('--timelock-delay', type=int, required=True)
    a = p.parse_args()

    rpc = gate.RPC(os.environ.get('ARVO_GOVERNANCE_RPC', ''))
    chain = int(rpc('eth_chainId', []), 16)
    gate.require(chain == a.chain_id, 'Wrong chain: RPC reports %d' % chain)
    block = rpc('eth_blockNumber', [])

    def code_hash(target):
        code = rpc('eth_getCode', [target, block])
        gate.require(code not in ('0x', '0x0'), 'No contract code at ' + target)
        return gate.keccak(code)

    def call(target, signature, args=''):
        return gate.words(rpc('eth_call', [{'to': target, 'data': gate.selector(signature) + args}, block]))

    staking, safe, timelock = (gate.address(v) for v in (a.staking_proxy, a.governance_safe, a.timelock))
    implementation = gate.address('0x' + rpc('eth_getStorageAt', [staking, gate.IMPLEMENTATION_SLOT, block])[-40:])
    singleton = gate.address('0x' + rpc('eth_getStorageAt', [safe, '0x0', block])[-40:])
    owners_raw = call(safe, 'getOwners()')
    owners = gate.array_at(owners_raw, owners_raw[0])
    threshold = call(safe, 'getThreshold()')[0]
    fallback = gate.address('0x' + rpc('eth_getStorageAt', [safe, gate.keccak('fallback_manager.handler.address'), block])[-40:])

    manifest = {
        'chainId': chain,
        'stakingProxy': staking,
        'deploymentAdmin': gate.address(a.deployment_admin),
        'governanceSafe': safe,
        'emergencyAuthority': gate.address(a.emergency),
        'timelock': timelock,
        'timelockDelay': a.timelock_delay,
        'stakingProxyDeploymentTx': a.staking_tx,
        'timelockDeploymentTx': a.timelock_tx,
        'stakingProxyCodeHash': code_hash(staking),
        'stakingImplementationCodeHash': code_hash(implementation),
        'timelockCodeHash': code_hash(timelock),
        'safeProxyCodeHash': code_hash(safe),
        'safeSingletonCodeHash': code_hash(singleton),
        'safeOwners': owners,
        'safeThreshold': threshold,
        'safeFallbackHandler': fallback,
    }
    if fallback != gate.ZERO:
        manifest['safeFallbackHandlerCodeHash'] = code_hash(fallback)

    with open(a.out, 'w') as f:
        json.dump(manifest, f, indent=2)
    print('Wrote ' + a.out)
    print('Implementation: ' + implementation)
    print('Safe singleton: ' + singleton)
    print('Safe owners (check these in the Safe app):')
    for o in owners:
        print('  ' + o)
    print('Safe threshold: %d of %d' % (threshold, len(owners)))
    print('Safe fallback handler: ' + fallback)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Manifest FAILED: ' + (str(error) if isinstance(error, gate.AuditError) else type(error).__name__), file=sys.stderr)
        raise SystemExit(1)
