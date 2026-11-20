// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ArvoStakingTypes as T } from "../ArvoStakingTypes.sol";

/// @notice Read-only view of the audited ArvoStaking proxy used by the bonus.
interface IArvoStakingBonusView {
    function arvo() external view returns (IERC20);
    function poolExists(uint32 poolId) external view returns (bool);
    function acquisitionPools(uint32 poolId) external view returns (bool);
    function pool(uint32 poolId) external view returns (T.PoolConfig memory);
    function vault(uint32 vaultId) external view returns (T.VaultConfig memory);
    function vaultArvoPrincipal(uint32 poolId) external view returns (uint256);
    function position(uint256 positionId) external view returns (T.Position memory);
}

/// @title ArvoSharedBonus
/// @notice Fixed ARVO bonus pot shared pro rata across one staking pool's
///         ARVO principal, measured once after the pool's entry window closes.
///         Works for pools that take ARVO deposits only, whether the base
///         reward is paid in ARVO, in USDC, or either.
///
/// @dev Standalone companion to the audited ArvoStaking contract. It only reads
///      staking state and never calls a state-changing staking function, so it
///      cannot move user principal or base rewards. It has no owner, no admin,
///      no pause and no upgrade path. Every parameter is immutable.
///
///      Lifecycle:
///      1. Deploy before the pool opens and transfer at least `bonusPot` ARVO.
///      2. After `closesAt` and before the earliest possible maturity, anyone
///         calls `snapshot()`. It records the pool's ARVO principal, which at
///         that time equals the principal of every unsettled pool position.
///      3. From each position's maturity until `claimDeadline`, anyone may call
///         `claim()`; payment always goes to the position owner.
///         bonus = bonusPot * position.arvoPrincipal / totalEligible.
///      4. Positions that used emergency exit forfeit their bonus.
///
///      Trust assumption: ArvoStaking is an upgradeable proxy. Whoever controls
///      its UPGRADER_ROLE (the timelock) could deploy logic that reports false
///      position data. The bonus pot is the maximum exposure; user principal
///      in ArvoStaking is never reachable from this contract.
///      5. After `claimDeadline`, anyone may send the remaining balance to the
///         immutable `treasury`. Funding above the outstanding obligation can be
///         sent to `treasury` at any time.
///
///      Why the snapshot equals the eligible set: before the earliest maturity a
///      pool position can only be settled by emergency exit, which removes its
///      principal from `vaultArvoPrincipal`. Entries are impossible after
///      `closesAt`, and pool times are immutable in ArvoStaking. Every unsettled
///      position was therefore opened in this pool and is counted exactly once,
///      so the sum of all floor-rounded bonuses can never exceed `bonusPot`.
contract ArvoSharedBonus is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IArvoStakingBonusView public immutable staking;
    IERC20 public immutable arvo;
    uint32 public immutable poolId;
    uint256 public immutable bonusPot;
    address public immutable treasury;
    uint64 public immutable closesAt;
    /// @notice Earliest timestamp any position in the pool can mature.
    uint64 public immutable earliestMaturity;
    /// @notice After this time unclaimed bonus can be returned to treasury.
    uint64 public immutable claimDeadline;
    /// @notice Minimum time between entry close and the earliest maturity,
    ///         leaving a practical window to call `snapshot()`.
    uint256 public constant MIN_SNAPSHOT_WINDOW = 1 days;

    bool public snapshotTaken;
    uint64 public snapshotAt;
    uint256 public totalEligible;
    uint256 public totalClaimed;
    mapping(uint256 => bool) public claimed;

    event SnapshotTaken(uint256 totalEligible, uint64 snapshotAt);
    event BonusClaimed(uint256 indexed positionId, address indexed owner, uint256 amount);
    event ReturnedToTreasury(uint256 amount);

    error InvalidConfiguration();
    error SnapshotTooEarly();
    error SnapshotWindowMissed();
    error SnapshotAlreadyTaken();
    error SnapshotMissing();
    error PotNotFunded();
    error WrongPool();
    error NotMatured();
    error AlreadyClaimed();
    error EmergencyExited();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error NothingToReturn();

    constructor(
        IArvoStakingBonusView staking_,
        uint32 poolId_,
        uint256 bonusPot_,
        address treasury_,
        uint64 claimGracePeriod
    ) {
        if (address(staking_) == address(0) || treasury_ == address(0) || bonusPot_ == 0) {
            revert InvalidConfiguration();
        }
        if (!staking_.poolExists(poolId_) || staking_.acquisitionPools(poolId_)) {
            revert InvalidConfiguration();
        }

        T.PoolConfig memory p = staking_.pool(poolId_);
        T.VaultConfig memory v = staking_.vault(poolId_);

        // A fixed close is required so the eligible set is final before any
        // position can mature. The pot must be committed before entries open.
        if (p.closesAt == 0 || p.finalized || block.timestamp >= p.opensAt) {
            revert InvalidConfiguration();
        }
        if (v.duration == 0 || uint256(p.closesAt) + MIN_SNAPSHOT_WINDOW > uint256(p.opensAt) + v.duration) {
            revert InvalidConfiguration();
        }
        // ARVO deposits only, so every eligible position's share is measured in
        // ARVO principal. The base reward may be ARVO (ARVO->ARVO), USDC paid on
        // ARVO principal (ARVO->USDC), or both products in one pool: in each case
        // ArvoStaking adds exactly the deposited ARVO to vaultArvoPrincipal.
        // USDC deposits, dual deposits and mixed rewards stay excluded.
        if (!v.arvoStakeEnabled || v.usdcStakeEnabled || v.dualStakeEnabled || v.mixedRewardEnabled
            || (!v.arvoRewardEnabled && !v.usdcRewardEnabled)) {
            revert InvalidConfiguration();
        }
        if (claimGracePeriod < 30 days || claimGracePeriod > 730 days) {
            revert InvalidConfiguration();
        }

        staking = staking_;
        arvo = staking_.arvo();
        poolId = poolId_;
        bonusPot = bonusPot_;
        treasury = treasury_;
        closesAt = p.closesAt;
        uint256 deadline = uint256(p.closesAt) + v.duration + claimGracePeriod;
        if (deadline > type(uint64).max) revert InvalidConfiguration();
        earliestMaturity = uint64(uint256(p.opensAt) + v.duration);
        // Latest possible maturity is just before closesAt + duration.
        claimDeadline = uint64(deadline);
    }

    /// @notice Records the pool's eligible ARVO principal. Callable by anyone,
    ///         once, after entries close and before the first maturity.
    function snapshot() external {
        if (snapshotTaken) revert SnapshotAlreadyTaken();
        if (block.timestamp < closesAt) revert SnapshotTooEarly();
        if (block.timestamp >= earliestMaturity) revert SnapshotWindowMissed();
        if (arvo.balanceOf(address(this)) < bonusPot) revert PotNotFunded();
        // Configuration can still change before opening; re-check at snapshot.
        if (staking.acquisitionPools(poolId)) revert InvalidConfiguration();

        uint256 total = staking.vaultArvoPrincipal(poolId);
        snapshotTaken = true;
        snapshotAt = uint64(block.timestamp);
        totalEligible = total;

        emit SnapshotTaken(total, uint64(block.timestamp));
    }

    /// @notice Bonus a position would receive. Before the snapshot this is an
    ///         estimate using current pool principal and can fall as more ARVO
    ///         enters. Returns zero for ineligible or already claimed positions.
    function bonusFor(uint256 positionId) public view returns (uint256) {
        if (claimed[positionId] || block.timestamp >= claimDeadline) return 0;
        if (!snapshotTaken && block.timestamp >= earliestMaturity) return 0;
        T.Position memory p = staking.position(positionId);
        if (p.owner == address(0) || p.vaultId != poolId || p.emergencyExit) return 0;
        if (p.openedAt >= closesAt) return 0;
        uint256 total = snapshotTaken ? totalEligible : staking.vaultArvoPrincipal(poolId);
        if (total == 0) return 0;
        return Math.mulDiv(bonusPot, p.arvoPrincipal, total);
    }

    /// @notice Pays a matured position's bonus to the position owner.
    function claim(uint256 positionId) public nonReentrant returns (uint256 amount) {
        if (!snapshotTaken) revert SnapshotMissing();
        if (block.timestamp >= claimDeadline) revert ClaimWindowClosed();
        if (claimed[positionId]) revert AlreadyClaimed();

        T.Position memory p = staking.position(positionId);
        if (p.owner == address(0) || p.vaultId != poolId || p.openedAt >= closesAt) {
            revert WrongPool();
        }
        if (p.emergencyExit) revert EmergencyExited();
        if (block.timestamp < p.maturesAt) revert NotMatured();

        amount = Math.mulDiv(bonusPot, p.arvoPrincipal, totalEligible);
        claimed[positionId] = true;
        totalClaimed += amount;

        if (amount != 0) arvo.safeTransfer(p.owner, amount);
        emit BonusClaimed(positionId, p.owner, amount);
    }

    /// @notice Convenience batch claim; each position is paid to its owner.
    function claimMany(uint256[] calldata positionIds) external returns (uint256 total) {
        for (uint256 i; i < positionIds.length; ++i) {
            total += claim(positionIds[i]);
        }
    }

    /// @notice ARVO still reserved for bonuses that may yet be claimed.
    function outstanding() public view returns (uint256) {
        if (snapshotTaken && totalEligible == 0) return 0;
        if (block.timestamp >= claimDeadline) return 0;
        // A missed snapshot window means no bonus can ever be claimed.
        if (!snapshotTaken && block.timestamp >= earliestMaturity) return 0;
        return bonusPot - totalClaimed;
    }

    /// @notice Sends any ARVO above the outstanding obligation to treasury:
    ///         over-funding at any time, everything after the claim deadline,
    ///         a missed snapshot or a pool with no eligible stake.
    function returnToTreasury() external nonReentrant returns (uint256 amount) {
        uint256 balance = arvo.balanceOf(address(this));
        uint256 owed = outstanding();
        if (balance <= owed) revert NothingToReturn();
        amount = balance - owed;
        arvo.safeTransfer(treasury, amount);
        emit ReturnedToTreasury(amount);
    }
}
