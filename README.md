# ARVO staking contracts

Upgradeable staking implementation, vault creation library, acquisition escrow,
deployment/governance scripts and Foundry tests. The app is maintained separately
in `arvoprotocol/arvo-app`.

## Build and test

Use Foundry with Solidity 0.8.35 and Node.js 22–24. The compiler settings in
`foundry.toml` are required to keep the staking implementation within the EVM
runtime-size limit. Upgrade validation invokes OpenZeppelin upgrades-core through
`npx` and therefore requires npm access or a populated npm cache.

```sh
forge clean
forge test -vv
python3 tooling/verify_acquisition_build.py
python3 tooling/test_audit_governance.py
```

No tests require production private keys. Never add secrets to repository files.
Broadcasting deployment scripts is a separate operation and is not part of a GitHub
source update.

## Compatibility fixtures

`src/ArvoStakingBaseline.sol`, `src/ArvoVaultDefaultsBaseline.sol` and
`test/upgrade/fixtures/ArvoStakingTestnetV1.sol` are intentional historical references
used by compatibility tests. Keep them even though obsolete working-file revisions
have been removed.

## Dependencies

Dependency Solidity source and licenses are vendored under `lib`, using the
reviewed server copies. Upstream tests, fixtures, generated artifacts and tooling
are omitted. Dependency versions/revisions are recorded in `foundry.lock`.
These are ordinary tracked files, not Git submodules; recursive submodule setup
is not required. Do not run `forge update` to replace them implicitly.

## Release checks

`tooling/verify_acquisition_build.py` checks runtime sizes, the original public ABI
and storage compatibility after compilation. Governance topology has a separate
read-only audit helper. The testnet acquisition upgrade script is tied to its
original implementation and is not a generic mainnet deployment script.

The repository excludes environment secrets, keystores, broadcast/cache files,
compiler output, checkpoints and temporary `.pre-*` / `.phase*` revisions.
