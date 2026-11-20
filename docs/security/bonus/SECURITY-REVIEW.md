# ArvoSharedBonus — security review record

Date: 18 November 2026
Contract: `src/bonus/ArvoSharedBonus.sol` (runtime size 5,467 bytes)
Base: audited ArvoStaking `007754e6806aebc7e1aa88b09c31d2b6c2746443`, which this change leaves **unchanged**.

**Status: NOT audited by Soken.** This record describes automated analysis, testing and an independent AI review. It is not a third-party audit. Describe the contract publicly as "independently tested with automated security analysis and AI review". Do not describe it as audited.

## Design summary

- A standalone contract. It **reads** the audited ArvoStaking proxy and never calls a state-changing staking function.
- It has no owner, admin, pause or upgrade path. All parameters are immutable.
- A fixed ARVO pot is shared pro rata by ARVO principal across one ARVO→ARVO pool's positions. The total is measured once, by a permissionless `snapshot()`, after entries close and before the earliest maturity.
- Each position's bonus is claimable from its maturity and is paid to the position owner. Emergency-exited positions forfeit their share.
- Unclaimed and forfeited ARVO returns to an immutable treasury after `claimDeadline`. Funding above the outstanding obligation is returnable at any time.

## Trust assumptions

1. ArvoStaking is a UUPS proxy. The holder of `UPGRADER_ROLE` (the timelock) could upgrade it to report false position data. The **maximum exposure is the bonus pot**; the contract cannot reach user principal.
2. Someone must call `snapshot()` in the window from `closesAt` to `opensAt + duration`, which is at least 1 day and in practice about 51 days for a 9-day entry window. If it is missed, no bonus is payable and the whole pot returns to treasury.
3. ARVO is a standard ERC-20 token, without fee-on-transfer or rebasing.

## Testing

| Suite | Result |
| --- | --- |
| Existing audited suite (unchanged) | 271 / 271 pass |
| `test/bonus/ArvoSharedBonus.t.sol`: unit tests, handover maths examples, edge cases, plus a 2,000-run fuzz conservation test | 24 / 24 pass |
| `test/bonus/ArvoSharedBonusInvariant.t.sol`: 4 invariants × 512 runs × 100 calls (stake, exit, snapshot, claim, principal claim, sweep, time jumps) | 4 / 4 pass |
| `test/bonus/ArvoSharedBonusReview.t.sol`: the independent reviewer's proofs of concept and regression tests | 6 / 6 pass |
| **Total** | **305 / 305** (`forge clean && forge test`) |

The invariants checked are:
- The pot is never overpaid.
- Every ARVO is accounted for.
- The outstanding obligation is always backed by the contract's balance.
- The snapshot equals the principal of the eligible positions.
- Staking solvency is unaffected.

## Static analysis

- **Slither 0.11.6** (102 detectors): no high, medium or low results. The informational results are timestamp comparisons (by design: windows are measured in days), external calls in the `claimMany` loop (a non-claimable id reverts only that batch; single claims always work), a gas note, and the repo-wide mixed-pragma note. Output: `slither.txt`.
- **Semgrep** with the Decurity smart-contract rules (57 rules): no security findings, only 5 gas-style suggestions, intentionally not applied for readability. Output: `semgrep.txt`.
- **Aderyn** was not run: its release binaries were unavailable from the build environment.

## Independent AI review (separate reviewer that did not write the code)

No critical, high or medium findings. Overpayment was attempted through restake and compound into and out of the pool, same-block exits around the snapshot, protocol allocations, donations, timing edges and pool admin controls. None succeeded.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| L-1 | Low | The snapshot window could be one second long | Fixed: the constructor requires `MIN_SNAPSHOT_WINDOW = 1 days` |
| L-2 | Low | Dual or cross-asset positions in the same pool would share the ARVO pot | Fixed: the constructor requires an ARVO-stake, ARVO-reward-only vault |
| I-1 | Info | The pool could be converted to an acquisition pool after deployment | Fixed: `snapshot()` reverts for acquisition pools. The test shows ARVO-only pools cannot be converted anyway |
| I-2 | Info | Depends on the staking proxy's upgrade governance | Documented trust assumption |
| I-3 | Info | `bonusFor` could show an unpayable estimate | Fixed: returns 0 after a missed snapshot window or after the deadline |
| I-4 | Info | Forfeited shares stay locked until the deadline | Intended; returned to treasury after `claimDeadline` |
| — | Cleanup | `uint64` casts were unchecked | Fixed: the deadline is bounds-checked |

## Deployment checklist

1. Create the pool on the staking contract (ARVO deposits only: ARVO→ARVO, ARVO→USDC or both; `closesAt` set, entry window under `duration − 1 day`).
2. Deploy `ArvoSharedBonus(stakingProxy, poolId, bonusPot, treasurySafe, claimGracePeriod)` **before `opensAt`**. The constructor reverts otherwise.
3. Transfer `bonusPot` ARVO to the bonus contract and verify its source on the block explorer.
4. Add the bonus address to `NEXT_PUBLIC_BONUS_ADDRESSES` in the app.
5. Schedule a `snapshot()` call at `closesAt`. It is permissionless, so any wallet can make it.

## Rename (18 Nov 2026)

The contract was renamed from `ArvoFirstEditionBonus` to `ArvoSharedBonus` (and the deploy script to `DeploySharedBonus.s.sol`) because one bonus contract can be deployed for any ARVO->ARVO vault, not only First Edition. No logic changed: the full suite (308 tests, including the reviewer's proof-of-concept regression tests and the invariant tests) passes unchanged, and Slither and Semgrep were re-run with the same results.

## Scope change: ARVO->USDC pools (20 Nov 2026)

**What changed.** The constructor previously accepted only pools that take ARVO and pay an ARVO base reward (review finding L-2 excluded dual and cross-asset pools as a precaution). It now also accepts pools that take ARVO deposits and pay a USDC base reward (`products` 2, or 1|2). The bonus pot is still paid in ARVO and shared by ARVO principal. Dual deposits, USDC deposits, mixed rewards and acquisition pools remain rejected.

**Why it is safe.** `ArvoStaking._stake` adds exactly the deposited ARVO to `vaultArvoPrincipal[vaultId]` and records it as `position.arvoPrincipal`, whatever the reward mode. Claims, emergency exits, restakes and compounds subtract or add that same principal. So the snapshot invariant in the contract header (the snapshot equals the sum of eligible ARVO principal; payouts can never exceed `bonusPot`) holds for ARVO->USDC positions exactly as for ARVO->ARVO ones. No other logic changed.

**Tests.** `testRejectsDualAndCrossAssetPools` was replaced by `testRejectsDualAndUsdcDepositPools` (dual and USDC-deposit pools still revert). Added `testArvoForUsdcPoolSharesPotByArvoPrincipal` (pro-rata ARVO payout in an ARVO->USDC pool; base USDC reward and principal unaffected) and `testMixedArvoProductsShareOnePot` (ARVO->ARVO and ARVO->USDC positions share one pot; emergency exit forfeits). 39 bonus tests and 310 tests in the full suite pass. Slither was re-run with no new findings.

**Review status.** This change was made after the independent review above and has not been separately reviewed. It needs your approval before any deployment.
