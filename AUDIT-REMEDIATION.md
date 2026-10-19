# Soken draft remediation - 16 October 2026

Base: ca8b3d217a2666252680f88b732d76182c5b316d. Status describes source
changes for verification, not a deployed fix or a final auditor disposition.

| Finding | Response |
| --- | --- |
| M-001 | DUAL acquisition emergency exit pays ARVO immediately, forfeits rewards, and creates `pendingEmergencyUsdc(positionId)`. `claimEmergencyUsdc` collects only that principal when that pool has enough cash and returned principal. It works while paused/unpaused and before/after maturity. Original position fields stay intact. USDC liabilities, pool principal and escrow active-position accounting remain until actual USDC settlement. A liquid DUAL exit also uses this explicit second claim. |
| L-001 | `Math.mulDiv` quotient/remainder calculation performs the exact single final floor without overflowing `amount*price` or `price*rate` where the final reward fits uint256. Zero rewards still revert. Applies only to new quotes; existing rewards do not change. |
| L-002 | Validate nonzero minimums for each enabled deposit mode in custom and product creation. Existing pools are not rewritten. |
| L-003 | Add Configured, Deposited, Settled and Finalized events to new escrow deployments. The already-bound testnet escrow is immutable and is **not** replaced by the staking upgrade. The final report must distinguish fixed new-deployment source from the unchanged legacy deployment. |
| L-004 | Proposed retained security design: pause immediately, unpause through DEFAULT_ADMIN/timelock. Claims remain available. No new instant-unpause privilege is introduced. Request auditor acknowledgement of this deliberate trade-off; do not describe it as a code fix. |
| L-005 | Share ordinary USDC obligations between capacity and solvency views; exclude unused acquisition reward limits. The cash-solvency signal still reports false for actual acquisition principal/reward cash shortfalls; Treasury receivables are not cash. |
| I-001 | Preserve all pre-existing slots and struct layouts; append only the pending receipt mapping. Validate against the audited source fixture and original historical fixtures. |
| I-002 | Cancun remains required for the existing OpenZeppelin guard; no guard replacement or storage relocation. |
| I-003, I-007, I-011 | Keep the existing two-stage governance handoff and mandatory governance audit. On-chain handoff is outstanding and requires signed transactions and verified Safe owners. The historical 1-of-1 test Safe does not meet the release gate's 2+ owner/2+ signature requirements. Do not bypass that gate. |
| I-004 | Pin the six in-scope production source pragmas to solc 0.8.35. Historical fixtures retain their historical source. |
| I-005 | Factory error declarations are now used by the consolidated pure validation helpers. |
| I-006 | Keep one-time immutable escrow binding. No silent migration or pool redirection. |
| I-008 | Historical position IDs remain append-only. The app bounds reads to its latest 100 positions and labels that limit. No ABI-breaking storage redesign. |
| I-009 | No change to the reviewed false positive. |
| I-010 | Consolidate validation, reward/oracle computation and pool-finalization terms in the linked factory library. Role enforcement remains at staking entry points; storage writes use explicitly supplied mappings. Finalization events may precede the new escrow Finalized event; transaction effects still revert atomically. Check deployed runtime size as a release gate. |
| I-012 | App CI installs dependencies, generates Prisma, creates a throwaway fixture and runs the actual auth checks. The helper already ships in the audited app. |
| I-013 | Retain the validated custom admin challenge; one-time nonce, expiry, exact message, domain/address binding and EOA verification remain. SIWE migration is optional and is not bundled into the fund-access fix. |

## Regression evidence

`test/unit/ArvoAuditRemediation.t.sol` covers the locked-ARVO reproduction,
deferred-receipt conservation, failed claims, other-pool repayment, wrong owner,
repeat calls, reward forfeiture, immediate funded collection, original terms,
rounding/overflow, minimums, escrow events and false/real cash-solvency signals.
`test/upgrade/ArvoAuditUpgrade.t.sol` upgrades a live acquisition position from
the audited implementation fixture and checks preservation before exercising
the fixed exit. The new upgrade script runs OpenZeppelin storage validation.

The audited implementation fixture is test-only source from the base commit,
renamed with adjusted import paths. It is not claimed to have byte-for-byte
identical deployed metadata. New source is not authority to move Treasury funds.

## Deployment order

1. Complete clean tests, runtime/ABI/storage checks and auditor fix verification.
2. Run `UpgradeArvoAuditTestnet.s.sol` as a dry run on chain 46630. It pins the
   existing implementation and leaves the existing escrow binding untouched.
3. Broadcast only the reviewed dry-run transactions with the existing encrypted
   testnet keystore. Re-read implementation, escrow binding, balances and roles.
4. Rehearse governance with an actually verified Safe configuration and the
   existing staged/final audit manifest. Renounce deployer privileges last.
5. Mainnet is a separate deployment with the new event-emitting escrow. Never
   point this testnet-only script at mainnet or bind an escrow to a wrong proxy.

Do not rerun the old `UpgradeArvoAcquisitionTestnet` operational entry point:
it targets the pre-acquisition implementation and initial binding, not this fix.
