// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IArvoPriceOracle } from "./interfaces/IArvoPriceOracle.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ArvoStakingTypes } from "./ArvoStakingTypes.sol";
import { ArvoPoolCreation } from "./ArvoPoolCreation.sol";
import { ArvoAcquisitionEscrow } from "./ArvoAcquisitionEscrow.sol";

contract ArvoStaking is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IERC20 public arvo;
    IERC20 public usdc;

    uint256 public nextPositionId;

    mapping(uint32 => ArvoStakingTypes.VaultConfig) private _vaults;

    mapping(uint32 => bool) private _vaultExists;

    /*
     * Individual pool instances.
     *
     * Standard pools copy their economic terms from ArvoVaultDefaults.
     * Custom pools supply separately validated terms.
     */
    mapping(uint32 => ArvoStakingTypes.PoolConfig) private _pools;

    mapping(uint32 => bool) private _poolExists;

    uint32 public nextVaultId;

    mapping(uint256 => ArvoStakingTypes.Position) private _positions;

    mapping(address => uint256[]) private _userPositionIds;

    /*
     * Principal liabilities are assets belonging to stakers.
     * They must never be considered protocol reward capital.
     */
    uint256 public arvoPrincipalLiability;
    uint256 public usdcPrincipalLiability;

    /*
     * Reward liabilities are rewards already promised to open positions.
     */
    uint256 public arvoRewardLiability;
    uint256 public usdcRewardLiability;

    /*
     * Rewards assigned to pools but not yet committed to individual
     * positions.
     *
     * These funds are protected exactly like committed reward
     * liabilities and cannot be withdrawn as surplus.
     */
    uint256 public arvoRewardBudgetReserved;
    uint256 public usdcRewardBudgetReserved;

    /*
     * Used to enforce optional per-vault capacities.
     */
    mapping(uint32 => uint256) public vaultArvoPrincipal;
    mapping(uint32 => uint256) public vaultUsdcPrincipal;

    // Append-only extension. Existing structs and storage slots remain unchanged.
    IArvoPriceOracle public priceOracle;
    uint32 public maxPriceAge;
    mapping(uint32 => uint8) public poolProducts;
    mapping(uint32 => uint256) public minArvoForUsdc;
    mapping(uint32 => uint8) public poolVisibility; // 0 hidden, 1 opening soon, 2 published

    // Append-only. Acquisition pools use isolated custody and future USDC
    // reward commitments. Existing pool/position structs are never changed.
    ArvoAcquisitionEscrow public acquisitionEscrow;
    mapping(uint32 => bool) public acquisitionPools;
    uint256 public acquisitionUsdcPrincipal;
    uint256 public acquisitionUsdcRewards;
    uint256 public acquisitionUsdcBudget;
    error AcquisitionConfigurationLocked();
    error AcquisitionRolloverDisabled();
    event AcquisitionPoolConfigured(uint32 indexed poolId, address indexed treasury);
    event AcquisitionRewardLimitAdded(uint32 indexed poolId, uint256 amount);

    error InvalidPrice();
    error RewardBelowMinimum();
    error ProductDisabled();
    event PriceOracleConfigured(address oracle, uint32 maxAge);
    event PoolVisibilityChanged(uint32 indexed poolId, uint8 visibility);

    event RewardReserveFunded(address indexed token, address indexed funder, uint256 amount);

    event Staked(
        uint256 indexed positionId,
        address indexed user,
        uint32 indexed vaultId,
        ArvoStakingTypes.StakeMode stakeMode,
        ArvoStakingTypes.RewardMode rewardMode,
        uint256 arvoPrincipal,
        uint256 usdcPrincipal,
        uint256 arvoReward,
        uint256 usdcReward,
        uint256 maturesAt
    );

    event PositionClaimed(
        uint256 indexed positionId,
        address indexed user,
        uint256 arvoPrincipal,
        uint256 usdcPrincipal,
        uint256 arvoReward,
        uint256 usdcReward,
        uint64 settledAt
    );

    event EmergencyExited(
        uint256 indexed positionId,
        address indexed user,
        uint256 arvoPrincipal,
        uint256 usdcPrincipal,
        uint256 arvoRewardForfeited,
        uint256 usdcRewardForfeited,
        uint64 settledAt
    );

    event PositionRestaked(
        uint256 indexed previousPositionId,
        uint256 indexed newPositionId,
        address indexed user,
        uint32 destinationVaultId,
        uint256 arvoPrincipal,
        uint256 usdcPrincipal,
        uint256 arvoRewardPaid,
        uint256 usdcRewardPaid,
        uint64 maturesAt
    );

    event PositionCompounded(
        uint256 indexed previousPositionId,
        uint256 indexed newPositionId,
        address indexed user,
        uint32 destinationVaultId,
        uint256 arvoPrincipal,
        uint256 usdcPrincipal,
        uint256 arvoCompounded,
        uint256 usdcCompounded,
        uint256 newArvoReward,
        uint256 newUsdcReward,
        uint64 maturesAt
    );

    event VaultConfigured(uint32 indexed vaultId);
    event VaultCreated(uint32 indexed vaultId);

    event PoolCreated(
        uint32 indexed poolId,
        ArvoStakingTypes.VaultKind indexed kind,
        uint64 opensAt,
        uint64 closesAt
    );

    event PoolStatusChanged(uint32 indexed poolId, bool enabled);

    event PoolRewardBudgetReserved(uint32 indexed poolId, uint256 arvoAmount, uint256 usdcAmount);

    event ProtocolAllocationIncreased(
        uint32 indexed poolId, uint256 arvoAmount, uint256 usdcAmount
    );

    event PoolFinalized(
        uint32 indexed poolId, uint256 releasedArvoRewardBudget, uint256 releasedUsdcRewardBudget
    );

    event SurplusWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    error EmergencyExitOnlyWhilePaused();
    error EmergencyExitPositionMatured();

    error ZeroAddress();
    error InvalidAmount();
    error InvalidVault();
    error StakeModeDisabled();
    error RewardModeDisabled();
    error BelowMinimum();
    error CapacityExceeded();
    error InsufficientRewardReserve();
    error InvalidConfiguration();
    error InsufficientSurplus();
    error UnexpectedTokenTransfer();
    error InvalidPool();
    error InvalidPoolWindow();
    error PoolAlreadyOpened();
    error PoolBudgetLocked();
    error PoolNotOpen();
    error PoolClosed();
    error InsufficientPoolRewardBudget();
    error PoolFinalizedAlready();
    error PoolStillOpen();
    error ProtocolAllocationRequiresCap();
    error CompoundModeUnsupported();
    error InvalidTokenDecimals();
    error InvalidPosition();
    error NotPositionOwner();
    error PositionAlreadySettled();
    error PositionNotMatured();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address arvoToken, address usdcToken, address admin) external initializer {
        if (arvoToken == address(0) || usdcToken == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }

        if (arvoToken == usdcToken || arvoToken.code.length == 0 || usdcToken.code.length == 0) {
            revert InvalidConfiguration();
        }

        /*
         * Arvo's protected vault economics use fixed token units:
         *
         * ARVO = 18 decimals
         * USDC = 6 decimals
         *
         * Reject incompatible token contracts during initialization so
         * minimums, capacities, principal and reward accounting cannot
         * silently operate at the wrong denomination.
         */
        if (IERC20Metadata(arvoToken).decimals() != 18 || IERC20Metadata(usdcToken).decimals() != 6)
        {
            revert InvalidTokenDecimals();
        }

        __AccessControl_init();
        __Pausable_init();

        arvo = IERC20(arvoToken);
        usdc = IERC20(usdcToken);

        nextPositionId = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(VAULT_MANAGER_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /*
     * =============================================================
     *                           STAKING
     * =============================================================
     */

    function stake(
        uint32 vaultId,
        ArvoStakingTypes.StakeMode stakeMode,
        ArvoStakingTypes.RewardMode rewardMode,
        uint256 arvoAmount,
        uint256 usdcAmount
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        if (stakeMode == ArvoStakingTypes.StakeMode.ARVO && rewardMode == ArvoStakingTypes.RewardMode.USDC) revert RewardBelowMinimum();
        return _stake(vaultId, stakeMode, rewardMode, arvoAmount, usdcAmount, 0);
    }

    function stakeArvoForUsdc(uint32 vaultId, uint256 arvoAmount, uint256 minimumUsdcReward)
        external nonReentrant whenNotPaused returns (uint256 positionId)
    {
        if (minimumUsdcReward == 0) revert RewardBelowMinimum();
        return _stake(vaultId, ArvoStakingTypes.StakeMode.ARVO, ArvoStakingTypes.RewardMode.USDC, arvoAmount, 0, minimumUsdcReward);
    }

    function _stake(uint32 vaultId, ArvoStakingTypes.StakeMode stakeMode,
        ArvoStakingTypes.RewardMode rewardMode, uint256 arvoAmount, uint256 usdcAmount,
        uint256 minimumUsdcReward) internal returns (uint256 positionId) {
        ArvoStakingTypes.VaultConfig memory config = _getVault(vaultId);
        _validateProduct(vaultId, stakeMode, rewardMode, arvoAmount);

        /*
         * Every stakeable vault must be an explicitly created pool.
         */
        if (!_poolExists[vaultId]) {
            revert InvalidPool();
        }

        _validatePoolOpen(vaultId);

        _validateStake(config, stakeMode, arvoAmount, usdcAmount);

        _validateRewardMode(config, rewardMode);

        _validateCapacity(vaultId, arvoAmount, usdcAmount);

        /*
         * At this stage rewards are same-asset only.
         *
         * Cross-asset reward conversion will be introduced separately
         * behind the oracle layer.
         */
        uint256 arvoReward;
        uint256 usdcReward;
        uint16 appliedDualBoost;
        if (minimumUsdcReward != 0) usdcReward = _crossReward(arvoAmount, config.usdcRewardBps);
        else (arvoReward, usdcReward, appliedDualBoost) = _calculateReward(config, stakeMode, rewardMode, arvoAmount, usdcAmount);

        /*
         * Reward capacity is checked BEFORE user principal is transferred.
         *
         * This prevents newly deposited principal from being mistaken
         * for available reward capital.
         */
        if (usdcReward < minimumUsdcReward) revert RewardBelowMinimum();
        _requirePoolRewardBudget(vaultId, arvoReward, usdcReward);

        if (arvoAmount != 0) {
            _pullExact(arvo, msg.sender, arvoAmount);
        }

        if (usdcAmount != 0) {
            _pullExact(usdc, msg.sender, usdcAmount);
        }

        positionId = nextPositionId++;

        uint64 openedAt = block.timestamp.toUint64();

        uint64 maturesAt = (block.timestamp + uint256(config.duration)).toUint64();

        _positions[positionId] = ArvoStakingTypes.Position({
            owner: msg.sender,
            vaultId: vaultId,
            stakeMode: stakeMode,
            rewardMode: rewardMode,
            openedAt: openedAt,
            maturesAt: maturesAt,
            settledAt: 0,
            arvoPrincipal: arvoAmount,
            usdcPrincipal: usdcAmount,
            arvoReward: arvoReward,
            usdcReward: usdcReward,
            appliedDualBoostBps: appliedDualBoost,
            appliedLoyaltyBoostBps: 0,
            previousPositionId: 0,
            nextPositionId: 0,
            settled: false,
            emergencyExit: false
        });

        _userPositionIds[msg.sender].push(positionId);

        arvoPrincipalLiability += arvoAmount;
        usdcPrincipalLiability += usdcAmount;
        if (acquisitionPools[vaultId]) {
            acquisitionUsdcPrincipal += usdcAmount;
            acquisitionUsdcRewards += usdcReward;
            if (usdcAmount != 0) usdc.safeTransfer(address(acquisitionEscrow), usdcAmount);
            acquisitionEscrow.recordDeposit(vaultId, usdcAmount, maturesAt);
        }

        /*
         * Convert the position's reward from uncommitted pool reserve
         * into a committed reward liability.
         *
         * The total protected amount is unchanged by this transition.
         */
        _consumePoolRewardBudget(vaultId, arvoReward, usdcReward);

        arvoRewardLiability += arvoReward;
        usdcRewardLiability += usdcReward;

        vaultArvoPrincipal[vaultId] += arvoAmount;
        vaultUsdcPrincipal[vaultId] += usdcAmount;

        emit Staked(
            positionId,
            msg.sender,
            vaultId,
            stakeMode,
            rewardMode,
            arvoAmount,
            usdcAmount,
            arvoReward,
            usdcReward,
            maturesAt
        );
    }

    /*
     * =============================================================
     *                       POSITION SETTLEMENT
     * =============================================================
     */

    /// @notice Claims a matured position's principal and snapshotted rewards.
    /// @dev Claims intentionally remain available while the protocol is paused.
    function claim(uint256 positionId)
        external
        nonReentrant
        returns (uint256 arvoPaid, uint256 usdcPaid)
    {
        return _settleCashPosition(positionId,false);
    }

    /// @notice Allows the owner of an unmatured position to recover principal
    ///         while the protocol is paused.
    /// @dev Emergency exits return principal only. Snapshotted rewards are
    ///      forfeited and their committed liabilities are released.
    function emergencyExit(uint256 positionId)
        external
        nonReentrant
        returns (uint256 arvoPaid, uint256 usdcPaid)
    {
        return _settleCashPosition(positionId,true);
    }

    // Shared settlement accounting preserves legacy claim and emergency rules.
    function _settleCashPosition(uint256 positionId,bool emergency)
        internal returns(uint256 arvoPaid,uint256 usdcPaid) {
        if(emergency && !paused()) revert EmergencyExitOnlyWhilePaused();
        ArvoStakingTypes.Position storage p=_positions[positionId];
        if(p.owner==address(0)) revert InvalidPosition();
        if(p.owner!=msg.sender) revert NotPositionOwner();
        if(p.settled) revert PositionAlreadySettled();
        if(emergency) {
            if(block.timestamp>=p.maturesAt) revert EmergencyExitPositionMatured();
        } else if(block.timestamp<p.maturesAt) revert PositionNotMatured();
        uint32 poolId=p.vaultId;
        uint256 ap=p.arvoPrincipal; uint256 up=p.usdcPrincipal;
        uint256 ar=p.arvoReward; uint256 ur=p.usdcReward;
        uint64 nowAt=block.timestamp.toUint64();
        p.settled=true; p.settledAt=nowAt;
        if(emergency) p.emergencyExit=true;
        arvoPrincipalLiability-=ap; usdcPrincipalLiability-=up;
        arvoRewardLiability-=ar; usdcRewardLiability-=ur;
        vaultArvoPrincipal[poolId]-=ap; vaultUsdcPrincipal[poolId]-=up;
        arvoPaid=ap+(emergency?0:ar); usdcPaid=up+(emergency?0:ur);
        if(arvoPaid!=0) arvo.safeTransfer(msg.sender,arvoPaid);
        if(acquisitionPools[poolId]) _settleAcquisition(poolId,up,ur,usdcPaid);
        else if(usdcPaid!=0) usdc.safeTransfer(msg.sender,usdcPaid);
        if(emergency) emit EmergencyExited(positionId,msg.sender,ap,up,ar,ur,nowAt);
        else emit PositionClaimed(positionId,msg.sender,ap,up,ar,ur,nowAt);
    }

    /// @notice Rolls a matured position's principal into a new pool while paying
    ///         the previous cycle's earned reward to the owner.
    /// @dev Restaking requires the protocol to be unpaused because it creates
    ///      a new staking commitment. A failed restake leaves the old position
    ///      untouched and independently claimable.
    function restakePrincipal(uint256 positionId, uint32 destinationVaultId,
        ArvoStakingTypes.RewardMode rewardMode)
        external nonReentrant whenNotPaused returns (uint256 newPositionId) {
        ArvoStakingTypes.Position storage oldPosition = _positions[positionId];

        if (acquisitionPools[oldPosition.vaultId] || acquisitionPools[destinationVaultId]) {
            revert AcquisitionRolloverDisabled();
        }

        if (oldPosition.owner == address(0)) {
            revert InvalidPosition();
        }

        if (oldPosition.owner != msg.sender) {
            revert NotPositionOwner();
        }

        if (oldPosition.settled) {
            revert PositionAlreadySettled();
        }

        if (block.timestamp < oldPosition.maturesAt) {
            revert PositionNotMatured();
        }

        if (oldPosition.stakeMode == ArvoStakingTypes.StakeMode.ARVO && rewardMode == ArvoStakingTypes.RewardMode.USDC) revert RewardBelowMinimum();
        _validateProduct(destinationVaultId, oldPosition.stakeMode, rewardMode, oldPosition.arvoPrincipal);
        ArvoStakingTypes.VaultConfig memory config = _getVault(destinationVaultId);

        _validatePoolOpen(destinationVaultId);

        _validateStake(
            config, oldPosition.stakeMode, oldPosition.arvoPrincipal, oldPosition.usdcPrincipal
        );

        _validateRewardMode(config, rewardMode);

        _validateRestakeCapacity(
            destinationVaultId,
            oldPosition.vaultId,
            oldPosition.arvoPrincipal,
            oldPosition.usdcPrincipal
        );

        (uint256 newArvoReward, uint256 newUsdcReward, uint16 appliedDualBoost) = _calculateReward(
            config,
            oldPosition.stakeMode,
            rewardMode,
            oldPosition.arvoPrincipal,
            oldPosition.usdcPrincipal
        );

        _requirePoolRewardBudget(destinationVaultId, newArvoReward, newUsdcReward);

        newPositionId = _executePrincipalRestake(
            positionId,
            destinationVaultId,
            rewardMode,
            config.duration,
            newArvoReward,
            newUsdcReward,
            appliedDualBoost
        );
    }

    function _executePrincipalRestake(uint256 positionId, uint32 destinationVaultId,
        ArvoStakingTypes.RewardMode rewardMode, uint32 duration,
        uint256 newArvoReward, uint256 newUsdcReward, uint16 appliedDualBoost)
        internal returns (uint256 newPositionId) {
        ArvoStakingTypes.Position storage oldPosition = _positions[positionId];
        return _executeCompound(positionId, destinationVaultId, rewardMode, duration,
            oldPosition.arvoPrincipal, oldPosition.usdcPrincipal,
            newArvoReward, newUsdcReward, appliedDualBoost, false);
    }

    function _payAndEmitRestake(
        uint256 positionId,
        uint256 newPositionId,
        uint32 destinationVaultId,
        uint64 maturesAt
    ) internal {
        ArvoStakingTypes.Position storage oldPosition = _positions[positionId];

        uint256 arvoRewardPaid = oldPosition.arvoReward;
        uint256 usdcRewardPaid = oldPosition.usdcReward;

        if (arvoRewardPaid != 0) {
            arvo.safeTransfer(msg.sender, arvoRewardPaid);
        }

        if (usdcRewardPaid != 0) {
            usdc.safeTransfer(msg.sender, usdcRewardPaid);
        }

        emit PositionRestaked(
            positionId,
            newPositionId,
            msg.sender,
            destinationVaultId,
            oldPosition.arvoPrincipal,
            oldPosition.usdcPrincipal,
            arvoRewardPaid,
            usdcRewardPaid,
            maturesAt
        );
    }

    /// @notice Rolls a matured single-asset position's principal and earned
    ///         reward into a new position.
    /// @dev Phase 3C initially supports only ARVO->ARVO and USDC->USDC
    ///      compounding. No token conversion or oracle pricing occurs.
    function compound(uint256 positionId, uint32 destinationVaultId,
        ArvoStakingTypes.RewardMode rewardMode)
        external nonReentrant whenNotPaused returns (uint256 newPositionId) {
        ArvoStakingTypes.Position storage oldPosition = _positions[positionId];

        if (acquisitionPools[oldPosition.vaultId] || acquisitionPools[destinationVaultId]) {
            revert AcquisitionRolloverDisabled();
        }

        if (oldPosition.owner == address(0)) {
            revert InvalidPosition();
        }

        if (oldPosition.owner != msg.sender) {
            revert NotPositionOwner();
        }

        if (oldPosition.settled) {
            revert PositionAlreadySettled();
        }

        if (block.timestamp < oldPosition.maturesAt) {
            revert PositionNotMatured();
        }

        uint256 compoundedArvoPrincipal = 0;
        uint256 compoundedUsdcPrincipal = 0;

        if (
            oldPosition.stakeMode == ArvoStakingTypes.StakeMode.ARVO
                && oldPosition.rewardMode == ArvoStakingTypes.RewardMode.ARVO
        ) {
            compoundedArvoPrincipal = oldPosition.arvoPrincipal + oldPosition.arvoReward;
        } else if (
            oldPosition.stakeMode == ArvoStakingTypes.StakeMode.USDC
                && oldPosition.rewardMode == ArvoStakingTypes.RewardMode.USDC
        ) {
            compoundedUsdcPrincipal = oldPosition.usdcPrincipal + oldPosition.usdcReward;
        } else if (
            oldPosition.stakeMode == ArvoStakingTypes.StakeMode.DUAL
                && oldPosition.rewardMode == ArvoStakingTypes.RewardMode.ARVO
        ) {
            compoundedArvoPrincipal = oldPosition.arvoPrincipal + oldPosition.arvoReward;
            compoundedUsdcPrincipal = oldPosition.usdcPrincipal;
        } else if (
            oldPosition.stakeMode == ArvoStakingTypes.StakeMode.DUAL
                && oldPosition.rewardMode == ArvoStakingTypes.RewardMode.USDC
        ) {
            compoundedArvoPrincipal = oldPosition.arvoPrincipal;
            compoundedUsdcPrincipal = oldPosition.usdcPrincipal + oldPosition.usdcReward;
        } else {
            revert CompoundModeUnsupported();
        }

        if (oldPosition.stakeMode == ArvoStakingTypes.StakeMode.ARVO && rewardMode == ArvoStakingTypes.RewardMode.USDC) revert RewardBelowMinimum();
        _validateProduct(destinationVaultId, oldPosition.stakeMode, rewardMode, compoundedArvoPrincipal);
        ArvoStakingTypes.VaultConfig memory config = _getVault(destinationVaultId);

        _validatePoolOpen(destinationVaultId);

        _validateStake(
            config, oldPosition.stakeMode, compoundedArvoPrincipal, compoundedUsdcPrincipal
        );

        _validateRewardMode(config, rewardMode);

        _validateCompoundCapacity(
            destinationVaultId,
            oldPosition.vaultId,
            oldPosition.arvoPrincipal,
            oldPosition.usdcPrincipal,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal
        );

        (uint256 newArvoReward, uint256 newUsdcReward, uint16 appliedDualBoost) = _calculateReward(
            config,
            oldPosition.stakeMode,
            rewardMode,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal
        );

        _requirePoolRewardBudget(destinationVaultId, newArvoReward, newUsdcReward);

        newPositionId = _executeCompound(
            positionId,
            destinationVaultId,
            rewardMode,
            config.duration,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal,
            newArvoReward,
            newUsdcReward,
            appliedDualBoost,
            true
        );
    }

    function _executeCompound(
        uint256 positionId,
        uint32 destinationVaultId,
        ArvoStakingTypes.RewardMode rewardMode,
        uint32 duration,
        uint256 compoundedArvoPrincipal,
        uint256 compoundedUsdcPrincipal,
        uint256 newArvoReward,
        uint256 newUsdcReward,
        uint16 appliedDualBoost,
        bool compounding
    ) internal returns (uint256 newPositionId) {
        uint64 settledAt = block.timestamp.toUint64();
        uint64 maturesAt = (block.timestamp + uint256(duration)).toUint64();

        newPositionId = nextPositionId++;

        _settlePositionForCompound(
            positionId,
            newPositionId,
            destinationVaultId,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal,
            newArvoReward,
            newUsdcReward,
            settledAt,
            compounding
        );

        _createCompoundedPosition(
            positionId,
            newPositionId,
            destinationVaultId,
            rewardMode,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal,
            newArvoReward,
            newUsdcReward,
            appliedDualBoost,
            settledAt,
            maturesAt
        );

        if (compounding) _emitCompound(
            positionId,
            newPositionId,
            destinationVaultId,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal,
            newArvoReward,
            newUsdcReward,
            maturesAt
        );
        else _payAndEmitRestake(positionId, newPositionId, destinationVaultId, maturesAt);
    }

    function _settlePositionForCompound(
        uint256 positionId,
        uint256 newPositionId,
        uint32 destinationVaultId,
        uint256 compoundedArvoPrincipal,
        uint256 compoundedUsdcPrincipal,
        uint256 newArvoReward,
        uint256 newUsdcReward,
        uint64 settledAt,
        bool compounding
    ) internal {
        ArvoStakingTypes.Position storage oldPosition = _positions[positionId];

        uint32 oldVaultId = oldPosition.vaultId;

        uint256 arvoCompounded = oldPosition.arvoReward;
        uint256 usdcCompounded = oldPosition.usdcReward;

        oldPosition.settled = true;
        oldPosition.settledAt = settledAt;
        oldPosition.nextPositionId = newPositionId;

        /*
         * Matured rewards remain inside the contract and become
         * principal belonging to the user.
         */
        arvoRewardLiability -= arvoCompounded;
        usdcRewardLiability -= usdcCompounded;

        if (compounding) {
            arvoPrincipalLiability += arvoCompounded;
            usdcPrincipalLiability += usdcCompounded;
        }

        vaultArvoPrincipal[oldVaultId] -= oldPosition.arvoPrincipal;
        vaultUsdcPrincipal[oldVaultId] -= oldPosition.usdcPrincipal;

        _consumePoolRewardBudget(destinationVaultId, newArvoReward, newUsdcReward);

        arvoRewardLiability += newArvoReward;
        usdcRewardLiability += newUsdcReward;

        vaultArvoPrincipal[destinationVaultId] += compoundedArvoPrincipal;
        vaultUsdcPrincipal[destinationVaultId] += compoundedUsdcPrincipal;
    }

    function _createCompoundedPosition(
        uint256 previousPositionId,
        uint256 newPositionId,
        uint32 destinationVaultId,
        ArvoStakingTypes.RewardMode rewardMode,
        uint256 compoundedArvoPrincipal,
        uint256 compoundedUsdcPrincipal,
        uint256 newArvoReward,
        uint256 newUsdcReward,
        uint16 appliedDualBoost,
        uint64 openedAt,
        uint64 maturesAt
    ) internal {
        ArvoStakingTypes.Position storage oldPosition = _positions[previousPositionId];

        ArvoStakingTypes.Position storage newPosition = _positions[newPositionId];

        newPosition.owner = msg.sender;
        newPosition.vaultId = destinationVaultId;
        newPosition.stakeMode = oldPosition.stakeMode;
        newPosition.rewardMode = rewardMode;
        newPosition.openedAt = openedAt;
        newPosition.maturesAt = maturesAt;
        newPosition.settledAt = 0;
        newPosition.arvoPrincipal = compoundedArvoPrincipal;
        newPosition.usdcPrincipal = compoundedUsdcPrincipal;
        newPosition.arvoReward = newArvoReward;
        newPosition.usdcReward = newUsdcReward;
        newPosition.appliedDualBoostBps = appliedDualBoost;
        newPosition.appliedLoyaltyBoostBps = 0;
        newPosition.previousPositionId = previousPositionId;
        newPosition.nextPositionId = 0;
        newPosition.settled = false;
        newPosition.emergencyExit = false;

        _userPositionIds[msg.sender].push(newPositionId);
    }

    function _emitCompound(
        uint256 previousPositionId,
        uint256 newPositionId,
        uint32 destinationVaultId,
        uint256 compoundedArvoPrincipal,
        uint256 compoundedUsdcPrincipal,
        uint256 newArvoReward,
        uint256 newUsdcReward,
        uint64 maturesAt
    ) internal {
        ArvoStakingTypes.Position storage oldPosition = _positions[previousPositionId];

        emit PositionCompounded(
            previousPositionId,
            newPositionId,
            msg.sender,
            destinationVaultId,
            compoundedArvoPrincipal,
            compoundedUsdcPrincipal,
            oldPosition.arvoReward,
            oldPosition.usdcReward,
            newArvoReward,
            newUsdcReward,
            maturesAt
        );
    }

    /*
     * =============================================================
     *                       REWARD FUNDING
     * =============================================================
     */

    function fundArvoRewards(uint256 amount) external nonReentrant onlyRole(REWARD_MANAGER_ROLE) {
        if (amount == 0) {
            revert InvalidAmount();
        }

        _pullExact(arvo, msg.sender, amount);

        emit RewardReserveFunded(address(arvo), msg.sender, amount);
    }

    function fundUsdcRewards(uint256 amount) external nonReentrant onlyRole(REWARD_MANAGER_ROLE) {
        if (amount == 0) {
            revert InvalidAmount();
        }

        _pullExact(usdc, msg.sender, amount);

        emit RewardReserveFunded(address(usdc), msg.sender, amount);
    }

    /*
     * Only assets genuinely in excess of every principal and promised
     * reward liability may leave through an administrator function.
     */

    function withdrawArvoSurplus(address recipient, uint256 amount)
        external
        nonReentrant
        onlyRole(REWARD_MANAGER_ROLE)
    {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        uint256 surplus = availableArvoRewardCapacity();

        if (amount == 0 || amount > surplus) {
            revert InsufficientSurplus();
        }

        arvo.safeTransfer(recipient, amount);

        emit SurplusWithdrawn(address(arvo), recipient, amount);
    }

    function withdrawUsdcSurplus(address recipient, uint256 amount)
        external
        nonReentrant
        onlyRole(REWARD_MANAGER_ROLE)
    {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        uint256 surplus = availableUsdcRewardCapacity();

        if (amount == 0 || amount > surplus) {
            revert InsufficientSurplus();
        }

        usdc.safeTransfer(recipient, amount);

        emit SurplusWithdrawn(address(usdc), recipient, amount);
    }

    /*
     * =============================================================
     *                       ADMIN CONTROLS
     * =============================================================
     */

    /// @notice Creates a pool using one of the four protected
    ///         standard Arvo vault definitions.


    /// @notice Creates a pool with custom duration and reward economics.
    ///
    /// @dev Custom terms are validated by the same safety ceilings as
    ///      the existing vault configuration.


    /// @notice Allows an administrator to close or reopen a pool before
    ///         its opening time. Once a pool has opened it can only be
    ///         disabled, never reopened.
    /// @notice products: bit0 ARVO/ARVO, bit1 ARVO/USDC, bit2 USDC/USDC,
    /// bit3 DUAL/ARVO, bit4 DUAL/USDC, bit5 DUAL/native mixed rewards.
    /// Existing pools retain their legacy rules.


    function createStandardPool(
        ArvoStakingTypes.VaultKind kind,
        uint64 opensAt,
        uint64 closesAt,
        uint256 maxArvoPrincipal,
        uint256 maxUsdcPrincipal,
        bool arvoStakeEnabled,
        bool usdcStakeEnabled,
        bool dualStakeEnabled,
        bool arvoRewardEnabled,
        bool usdcRewardEnabled
    ) external onlyRole(VAULT_MANAGER_ROLE) returns (uint32 poolId) {
        ArvoStakingTypes.VaultConfig memory config;
        uint8 flags=(arvoStakeEnabled?1:0)|(usdcStakeEnabled?2:0)|(dualStakeEnabled?4:0)
            |(arvoRewardEnabled?8:0)|(usdcRewardEnabled?16:0);
        poolId=_createPoolTerms(ArvoPoolCreation.Terms(kind,config,opensAt,closesAt,
            maxArvoPrincipal,maxUsdcPrincipal,flags,0,0));
    }

    function createCustomPool(
        ArvoStakingTypes.VaultConfig calldata customConfig,
        uint64 opensAt,
        uint64 closesAt,
        uint256 maxArvoPrincipal,
        uint256 maxUsdcPrincipal
    ) external onlyRole(VAULT_MANAGER_ROLE) returns (uint32 poolId) {
        poolId=_createPoolTerms(ArvoPoolCreation.Terms(ArvoStakingTypes.VaultKind.CUSTOM,
            customConfig,opensAt,closesAt,maxArvoPrincipal,maxUsdcPrincipal,0,0,1));
    }

    function createProductPool(ArvoStakingTypes.VaultKind kind,
        ArvoStakingTypes.VaultConfig calldata customConfig,
        uint64 opensAt, uint64 closesAt, uint256 maxArvoPrincipal,
        uint256 maxUsdcPrincipal, uint8 products, uint256 crossMinimum)
        external onlyRole(VAULT_MANAGER_ROLE) returns (uint32 poolId)
    {
        poolId=_createPoolTerms(ArvoPoolCreation.Terms(kind,customConfig,opensAt,closesAt,
            maxArvoPrincipal,maxUsdcPrincipal,products,crossMinimum,2));
    }

    function _createPoolTerms(ArvoPoolCreation.Terms memory terms) internal returns(uint32 poolId) {
        poolId=nextVaultId++;
        ArvoPoolCreation.create(_vaults,_vaultExists,_pools,_poolExists,poolProducts,minArvoForUsdc,poolId,terms);
    }

    function setPoolVisibility(uint32 poolId, uint8 visibility) external onlyRole(VAULT_MANAGER_ROLE) {
        if (!_poolExists[poolId] || visibility > 2) revert InvalidConfiguration();
        poolVisibility[poolId] = visibility;
        emit PoolVisibilityChanged(poolId, visibility);
    }

    function configurePriceOracle(address oracle, uint32 maxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle != address(0) && (oracle.code.length == 0 || maxAge == 0 || maxAge > 1 days)) revert InvalidConfiguration();
        priceOracle = IArvoPriceOracle(oracle);
        maxPriceAge = maxAge;
        if (oracle != address(0)) _price();
        emit PriceOracleConfigured(oracle, maxAge);
    }

    function quoteArvoForUsdc(uint32 poolId, uint256 amount) external view returns (uint256 reward) {
        ArvoStakingTypes.VaultConfig memory config = _getVault(poolId);
        _validateProduct(poolId, ArvoStakingTypes.StakeMode.ARVO, ArvoStakingTypes.RewardMode.USDC, amount);
        // Explicit product configuration already enforces a positive cross
        // minimum covering the ARVO minimum and enables both required assets.
        reward = _crossReward(amount, config.usdcRewardBps);
    }

    function _crossReward(uint256 amount, uint16 rate) internal view returns (uint256 reward) {
        (uint256 price, uint8 decimals,) = _price();
        uint256 value = (amount * price) / (10 ** (uint256(decimals) + 12));
        reward = (value * rate) / BPS;
        if (reward == 0) revert InvalidAmount();
    }

    function _price() internal view returns (uint256 price, uint8 decimals, uint256 updatedAt) {
        if (address(priceOracle) == address(0)) revert InvalidPrice();
        (price, decimals, updatedAt) = priceOracle.getArvoUsdPrice();
        if (price == 0 || decimals > 18 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) revert InvalidPrice();
    }

    function _validateProduct(uint32 poolId, ArvoStakingTypes.StakeMode stakeMode,
        ArvoStakingTypes.RewardMode rewardMode, uint256 amount) internal view {
        uint8 products = poolProducts[poolId];
        if (products == 0) {
            if (stakeMode == ArvoStakingTypes.StakeMode.ARVO && rewardMode == ArvoStakingTypes.RewardMode.USDC) revert ProductDisabled();
            return;
        }
        uint8 bit;
        if (stakeMode == ArvoStakingTypes.StakeMode.ARVO) {
            if (rewardMode == ArvoStakingTypes.RewardMode.ARVO) bit = 1;
            else if (rewardMode == ArvoStakingTypes.RewardMode.USDC) {
                bit = 2;
                if (amount < minArvoForUsdc[poolId]) revert BelowMinimum();
            }
        } else if (stakeMode == ArvoStakingTypes.StakeMode.USDC && rewardMode == ArvoStakingTypes.RewardMode.USDC) bit = 4;
        else if (stakeMode == ArvoStakingTypes.StakeMode.DUAL) {
            if (rewardMode == ArvoStakingTypes.RewardMode.ARVO) bit = 8;
            else if (rewardMode == ArvoStakingTypes.RewardMode.USDC) bit = 16;
            else if (rewardMode == ArvoStakingTypes.RewardMode.MIXED) bit = 32;
        }
        if ((products & bit) == 0) revert ProductDisabled();
    }

    function setPoolEnabled(uint32 poolId, bool enabled) external onlyRole(VAULT_MANAGER_ROLE) {
        if (!_poolExists[poolId]) {
            revert InvalidPool();
        }

        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (enabled && block.timestamp >= poolConfig.opensAt) {
            revert PoolAlreadyOpened();
        }

        poolConfig.enabled = enabled;

        emit PoolStatusChanged(poolId, enabled);
    }

    /// @notice Reserves already-funded reward assets for a pool.
    ///
    /// @dev Reservation does not transfer tokens. It moves reward
    ///      capacity from the protocol's free reserve into a protected
    ///      pool-specific budget.
    ///
    ///      Budgets may only be added before the pool opens. Once the
    ///      opening time is reached, its announced funding cannot be
    ///      changed through this function.
    function reservePoolRewardBudget(uint32 poolId, uint256 arvoAmount, uint256 usdcAmount)
        external
        onlyRole(REWARD_MANAGER_ROLE)
    {
        if (!_poolExists[poolId]) {
            revert InvalidPool();
        }

        if (arvoAmount == 0 && usdcAmount == 0) {
            revert InvalidAmount();
        }

        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (poolConfig.finalized || block.timestamp >= poolConfig.opensAt) {
            revert PoolBudgetLocked();
        }

        /*
         * Check free capacity before increasing reserved accounting.
         *
         * available*RewardCapacity() already excludes every existing
         * principal liability, committed reward and previously reserved
         * pool budget.
         */
        if (arvoAmount > availableArvoRewardCapacity()) {
            revert InsufficientRewardReserve();
        }

        if (usdcAmount != 0 && acquisitionPools[poolId]) revert AcquisitionConfigurationLocked();
        if (usdcAmount > availableUsdcRewardCapacity()) {
            revert InsufficientRewardReserve();
        }

        if (arvoAmount != 0) {
            poolConfig.arvoRewardBudget += arvoAmount;
            poolConfig.arvoRewardBudgetRemaining += arvoAmount;
            arvoRewardBudgetReserved += arvoAmount;
        }

        if (usdcAmount != 0) {
            poolConfig.usdcRewardBudget += usdcAmount;
            poolConfig.usdcRewardBudgetRemaining += usdcAmount;
            usdcRewardBudgetReserved += usdcAmount;
        }

        emit PoolRewardBudgetReserved(poolId, arvoAmount, usdcAmount);
    }

    /// @notice Binds the acquisition module once. Deploy it with this proxy
    /// as controller and the same USDC token. Cannot be replaced through admin.
    function configureAcquisitionEscrow(ArvoAcquisitionEscrow escrow)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(acquisitionEscrow) != address(0) || address(escrow).code.length == 0
            || escrow.controller() != address(this) || address(escrow.usdc()) != address(usdc)) {
            revert AcquisitionConfigurationLocked();
        }
        acquisitionEscrow = escrow;
    }

    /// @notice Permanently opts a NEW pool into acquisition custody.
    /// @dev Rejects opened pools, existing positions and prefunded USDC budgets.
    function configureAcquisitionPool(uint32 poolId, address treasury)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ArvoStakingTypes.PoolConfig storage pc = _pools[poolId];
        ArvoStakingTypes.VaultConfig storage vc = _vaults[poolId];
        if (address(acquisitionEscrow) == address(0) || !_poolExists[poolId]
            || pc.finalized || block.timestamp >= pc.opensAt || acquisitionPools[poolId]
            || pc.usdcRewardBudget != 0 || pc.maxUsdcPrincipal == 0
            || !(vc.usdcStakeEnabled || vc.dualStakeEnabled)) {
            revert AcquisitionConfigurationLocked();
        }
        acquisitionPools[poolId] = true;
        acquisitionEscrow.configure(poolId, treasury, pc.opensAt);
        emit AcquisitionPoolConfigured(poolId, treasury);
    }

    /// @notice Defines future USDC obligations, NOT an already funded reserve.
    function addAcquisitionRewardLimit(uint32 poolId, uint256 amount)
        external onlyRole(REWARD_MANAGER_ROLE)
    {
        ArvoStakingTypes.PoolConfig storage pc = _pools[poolId];
        if (!acquisitionPools[poolId] || pc.finalized || block.timestamp >= pc.opensAt) revert PoolBudgetLocked();
        if (amount == 0) revert InvalidAmount();
        pc.usdcRewardBudget += amount;
        pc.usdcRewardBudgetRemaining += amount;
        usdcRewardBudgetReserved += amount;
        acquisitionUsdcBudget += amount;
        emit AcquisitionRewardLimitAdded(poolId, amount);
    }

    /// @notice Permanently allocates unused pool capacity to the protocol.
    ///
    /// @dev This is capacity accounting only. No tokens are transferred,
    ///      no staking position is created, no principal liability is
    ///      created and no reward is earned.
    ///
    ///      Allocation can only increase and cannot exceed the pool's
    ///      configured capacity together with real user principal.
    function increaseProtocolAllocation(uint32 poolId, uint256 arvoAmount, uint256 usdcAmount)
        external
        onlyRole(VAULT_MANAGER_ROLE)
    {
        if (!_poolExists[poolId]) {
            revert InvalidPool();
        }

        if (arvoAmount == 0 && usdcAmount == 0) {
            revert InvalidAmount();
        }

        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (poolConfig.finalized) {
            revert PoolFinalizedAlready();
        }

        if (arvoAmount != 0) {
            if (poolConfig.maxArvoPrincipal == 0) {
                revert ProtocolAllocationRequiresCap();
            }

            if (
                vaultArvoPrincipal[poolId] + poolConfig.protocolArvoAllocation + arvoAmount
                    > poolConfig.maxArvoPrincipal
            ) {
                revert CapacityExceeded();
            }

            poolConfig.protocolArvoAllocation += arvoAmount;
        }

        if (usdcAmount != 0) {
            if (poolConfig.maxUsdcPrincipal == 0) {
                revert ProtocolAllocationRequiresCap();
            }

            if (
                vaultUsdcPrincipal[poolId] + poolConfig.protocolUsdcAllocation + usdcAmount
                    > poolConfig.maxUsdcPrincipal
            ) {
                revert CapacityExceeded();
            }

            poolConfig.protocolUsdcAllocation += usdcAmount;
        }

        emit ProtocolAllocationIncreased(poolId, arvoAmount, usdcAmount);
    }

    /// @notice Finalizes a closed pool and releases any reward budget
    ///         that was never committed to staking positions.
    ///
    /// @dev A scheduled pool can be finalized once closesAt is reached.
    ///      An open-ended pool must first be explicitly disabled.
    ///
    ///      Finalization is permanent.
    function finalizePool(uint32 poolId) external onlyRole(VAULT_MANAGER_ROLE) {
        if (!_poolExists[poolId]) {
            revert InvalidPool();
        }

        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (poolConfig.finalized) {
            revert PoolFinalizedAlready();
        }

        bool scheduledClosed = poolConfig.closesAt != 0 && block.timestamp >= poolConfig.closesAt;

        if (poolConfig.enabled && !scheduledClosed) {
            revert PoolStillOpen();
        }

        uint256 releasedArvo = poolConfig.arvoRewardBudgetRemaining;

        uint256 releasedUsdc = poolConfig.usdcRewardBudgetRemaining;

        if (releasedArvo != 0) {
            poolConfig.arvoRewardBudgetRemaining = 0;
            arvoRewardBudgetReserved -= releasedArvo;
        }

        if (releasedUsdc != 0) {
            poolConfig.usdcRewardBudgetRemaining = 0;
            usdcRewardBudgetReserved -= releasedUsdc;
            if (acquisitionPools[poolId]) acquisitionUsdcBudget -= releasedUsdc;
        }

        poolConfig.enabled = false;
        poolConfig.finalized = true;
        if (acquisitionPools[poolId]) acquisitionEscrow.finalize(poolId);

        emit PoolStatusChanged(poolId, false);

        emit PoolFinalized(poolId, releasedArvo, releasedUsdc);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*
     * =============================================================
     *                           VIEWS
     * =============================================================
     */

    function vault(uint32 vaultId) external view returns (ArvoStakingTypes.VaultConfig memory) {
        return _getVault(vaultId);
    }

    function vaultExists(uint32 vaultId) external view returns (bool) {
        return _vaultExists[vaultId];
    }

    function pool(uint32 poolId) external view returns (ArvoStakingTypes.PoolConfig memory) {
        if (!_poolExists[poolId]) {
            revert InvalidPool();
        }

        return _pools[poolId];
    }

    function poolExists(uint32 poolId) external view returns (bool) {
        return _poolExists[poolId];
    }

    function standardVaultConfig(ArvoStakingTypes.VaultKind kind)
        external
        pure
        returns (ArvoStakingTypes.VaultConfig memory)
    {
        if (kind == ArvoStakingTypes.VaultKind.CUSTOM) {
            revert InvalidConfiguration();
        }

        return ArvoPoolCreation.standard(kind);
    }

    function position(uint256 positionId) external view returns (ArvoStakingTypes.Position memory) {
        return _positions[positionId];
    }

    function userPositionIds(address user) external view returns (uint256[] memory) {
        return _userPositionIds[user];
    }

    /*
     * Reward capacity means:
     *
     * token balance
     * - user principal
     * - already promised rewards
     * - rewards reserved for individual pools
     *
     * Principal and pool-reserved rewards can therefore never fund
     * another reward promise or be withdrawn as surplus.
     */

    function availableArvoRewardCapacity() public view returns (uint256) {
        uint256 protectedAssets =
            arvoPrincipalLiability + arvoRewardLiability + arvoRewardBudgetReserved;

        uint256 balance = arvo.balanceOf(address(this));

        if (balance <= protectedAssets) {
            return 0;
        }

        return balance - protectedAssets;
    }

    function availableUsdcRewardCapacity() public view returns (uint256) {
        // Acquisition cash is physically isolated in its escrow. Only ordinary
        // liabilities and cash-backed budgets are protected by this balance.
        uint256 protectedAssets = usdcPrincipalLiability - acquisitionUsdcPrincipal
            + usdcRewardLiability - acquisitionUsdcRewards
            + usdcRewardBudgetReserved - acquisitionUsdcBudget;

        uint256 balance = usdc.balanceOf(address(this));

        if (balance <= protectedAssets) {
            return 0;
        }

        return balance - protectedAssets;
    }

    function isArvoSolvent() external view returns (bool) {
        return arvo.balanceOf(address(this))
            >= arvoPrincipalLiability + arvoRewardLiability + arvoRewardBudgetReserved;
    }

    function isUsdcSolvent() external view returns (bool) {
        uint256 acquisitionCash = address(acquisitionEscrow) == address(0) ? 0 : acquisitionEscrow.totalCash();
        return usdc.balanceOf(address(this)) + acquisitionCash
            >= usdcPrincipalLiability + usdcRewardLiability + usdcRewardBudgetReserved;
    }

    /*
     * =============================================================
     *                       INTERNAL LOGIC
     * =============================================================
     */

    /// @dev Self-only common storage writer avoids duplicating pool creation
    /// bytecode across factories. External callers cannot reach this path.




    function _getVault(uint32 vaultId)
        internal
        view
        returns (ArvoStakingTypes.VaultConfig memory config)
    {
        if (!_vaultExists[vaultId]) {
            revert InvalidVault();
        }

        config = _vaults[vaultId];

        if (config.duration == 0) {
            revert InvalidVault();
        }
    }





    function _validateCapacity(uint32 vaultId, uint256 arvoAmount, uint256 usdcAmount)
        internal
        view
    {
        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[vaultId];

        uint256 protocolArvoAllocation = poolConfig.protocolArvoAllocation;
        uint256 protocolUsdcAllocation = poolConfig.protocolUsdcAllocation;

        if (
            poolConfig.maxArvoPrincipal != 0
                && vaultArvoPrincipal[vaultId] + protocolArvoAllocation + arvoAmount
                    > poolConfig.maxArvoPrincipal
        ) {
            revert CapacityExceeded();
        }

        if (
            poolConfig.maxUsdcPrincipal != 0
                && vaultUsdcPrincipal[vaultId] + protocolUsdcAllocation + usdcAmount
                    > poolConfig.maxUsdcPrincipal
        ) {
            revert CapacityExceeded();
        }
    }

    function _validateRestakeCapacity(uint32 destinationVaultId, uint32 sourceVaultId,
        uint256 arvoAmount, uint256 usdcAmount) internal view {
        _validateCompoundCapacity(destinationVaultId, sourceVaultId, arvoAmount, usdcAmount, arvoAmount, usdcAmount);
    }

    function _validateCompoundCapacity(
        uint32 destinationVaultId,
        uint32 sourceVaultId,
        uint256 oldArvoPrincipal,
        uint256 oldUsdcPrincipal,
        uint256 newArvoPrincipal,
        uint256 newUsdcPrincipal
    ) internal view {
        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[destinationVaultId];

        uint256 destinationArvoPrincipal = vaultArvoPrincipal[destinationVaultId];
        uint256 destinationUsdcPrincipal = vaultUsdcPrincipal[destinationVaultId];

        /*
         * A same-pool compound replaces the old principal with the
         * compounded principal. Only the old principal is already
         * present in the pool counters; the matured reward was still
         * classified as a reward liability.
         */
        if (destinationVaultId == sourceVaultId) {
            destinationArvoPrincipal -= oldArvoPrincipal;
            destinationUsdcPrincipal -= oldUsdcPrincipal;
        }

        if (
            poolConfig.maxArvoPrincipal != 0
                && destinationArvoPrincipal + poolConfig.protocolArvoAllocation + newArvoPrincipal
                    > poolConfig.maxArvoPrincipal
        ) {
            revert CapacityExceeded();
        }

        if (
            poolConfig.maxUsdcPrincipal != 0
                && destinationUsdcPrincipal + poolConfig.protocolUsdcAllocation + newUsdcPrincipal
                    > poolConfig.maxUsdcPrincipal
        ) {
            revert CapacityExceeded();
        }
    }



    function _validatePoolOpen(uint32 poolId) internal view {
        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (!poolConfig.enabled || poolConfig.finalized) {
            revert PoolClosed();
        }

        if (block.timestamp < poolConfig.opensAt) {
            revert PoolNotOpen();
        }

        if (poolConfig.closesAt != 0 && block.timestamp >= poolConfig.closesAt) {
            revert PoolClosed();
        }
    }

    function _requirePoolRewardBudget(uint32 poolId, uint256 arvoReward, uint256 usdcReward)
        internal
        view
    {
        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (arvoReward > poolConfig.arvoRewardBudgetRemaining) {
            revert InsufficientPoolRewardBudget();
        }

        if (usdcReward > poolConfig.usdcRewardBudgetRemaining) {
            revert InsufficientPoolRewardBudget();
        }
    }

    function _consumePoolRewardBudget(uint32 poolId, uint256 arvoReward, uint256 usdcReward)
        internal
    {
        ArvoStakingTypes.PoolConfig storage poolConfig = _pools[poolId];

        if (arvoReward != 0) {
            poolConfig.arvoRewardBudgetRemaining -= arvoReward;
            arvoRewardBudgetReserved -= arvoReward;
        }

        if (usdcReward != 0) {
            poolConfig.usdcRewardBudgetRemaining -= usdcReward;
            usdcRewardBudgetReserved -= usdcReward;
            if (acquisitionPools[poolId]) acquisitionUsdcBudget -= usdcReward;
        }
    }

    function _validateStake(
        ArvoStakingTypes.VaultConfig memory config,
        ArvoStakingTypes.StakeMode stakeMode,
        uint256 arvoAmount,
        uint256 usdcAmount
    ) internal pure {
        if (stakeMode == ArvoStakingTypes.StakeMode.ARVO) {
            if (!config.arvoStakeEnabled) {
                revert StakeModeDisabled();
            }

            if (arvoAmount == 0 || usdcAmount != 0) {
                revert InvalidAmount();
            }

            if (arvoAmount < config.minArvo) {
                revert BelowMinimum();
            }

            return;
        }

        if (stakeMode == ArvoStakingTypes.StakeMode.USDC) {
            if (!config.usdcStakeEnabled) {
                revert StakeModeDisabled();
            }

            if (usdcAmount == 0 || arvoAmount != 0) {
                revert InvalidAmount();
            }

            if (usdcAmount < config.minUsdc) {
                revert BelowMinimum();
            }

            return;
        }

        if (!config.dualStakeEnabled) {
            revert StakeModeDisabled();
        }

        if (arvoAmount == 0 || usdcAmount == 0) {
            revert InvalidAmount();
        }

        if (arvoAmount < config.minArvo || usdcAmount < config.minUsdc) {
            revert BelowMinimum();
        }
    }

    function _validateRewardMode(
        ArvoStakingTypes.VaultConfig memory config,
        ArvoStakingTypes.RewardMode rewardMode
    ) internal pure {
        if (rewardMode == ArvoStakingTypes.RewardMode.ARVO && !config.arvoRewardEnabled) {
            revert RewardModeDisabled();
        }

        if (rewardMode == ArvoStakingTypes.RewardMode.USDC && !config.usdcRewardEnabled) {
            revert RewardModeDisabled();
        }

        if (rewardMode == ArvoStakingTypes.RewardMode.MIXED && !config.mixedRewardEnabled) {
            revert RewardModeDisabled();
        }
    }

    function _calculateReward(
        ArvoStakingTypes.VaultConfig memory config,
        ArvoStakingTypes.StakeMode stakeMode,
        ArvoStakingTypes.RewardMode rewardMode,
        uint256 arvoAmount,
        uint256 usdcAmount
    ) internal pure returns (uint256 arvoReward, uint256 usdcReward, uint16 appliedDualBoost) {
        uint256 rewardMultiplier = BPS;

        if (stakeMode == ArvoStakingTypes.StakeMode.DUAL) {
            appliedDualBoost = config.dualBoostBps;

            uint256 cappedBoost = appliedDualBoost;

            if (cappedBoost > config.combinedBoostCapBps) {
                cappedBoost = config.combinedBoostCapBps;
            }

            rewardMultiplier = BPS + cappedBoost;
        }

        /*
         * Until the oracle module is introduced, rewards can only
         * be paid in assets represented by the position.
         *
         * Multipliers are combined before division to minimise
         * intermediate rounding loss.
         */

        if (rewardMode == ArvoStakingTypes.RewardMode.ARVO) {
            if (arvoAmount == 0) {
                revert RewardModeDisabled();
            }

            arvoReward = (arvoAmount * config.arvoRewardBps * rewardMultiplier) / (BPS * BPS);

            return (arvoReward, 0, appliedDualBoost);
        }

        if (rewardMode == ArvoStakingTypes.RewardMode.USDC) {
            if (usdcAmount == 0) {
                revert RewardModeDisabled();
            }

            usdcReward = (usdcAmount * config.usdcRewardBps * rewardMultiplier) / (BPS * BPS);

            return (0, usdcReward, appliedDualBoost);
        }

        if (stakeMode != ArvoStakingTypes.StakeMode.DUAL) {
            revert RewardModeDisabled();
        }

        uint256 arvoShare = config.mixedArvoShareBps;

        uint256 usdcShare = BPS - arvoShare;

        arvoReward =
            (arvoAmount * config.arvoRewardBps * rewardMultiplier * arvoShare) / (BPS * BPS * BPS);

        usdcReward =
            (usdcAmount * config.usdcRewardBps * rewardMultiplier * usdcShare) / (BPS * BPS * BPS);
    }

    function _settleAcquisition(uint32 poolId, uint256 principal, uint256 reward, uint256 paid) internal {
        acquisitionUsdcPrincipal -= principal;
        acquisitionUsdcRewards -= reward;
        acquisitionEscrow.settle(poolId, msg.sender, principal, paid);
    }



    /*
     * Only accept tokens when the contract receives exactly the
     * amount our accounting expects.
     *
     * This prevents fee-on-transfer or otherwise unusual ERC-20
     * behaviour from creating liabilities larger than the assets
     * actually received.
     */
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 balanceBefore = token.balanceOf(address(this));

        token.safeTransferFrom(from, address(this), amount);

        uint256 balanceAfter = token.balanceOf(address(this));

        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) {
            revert UnexpectedTokenTransfer();
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
