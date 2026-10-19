// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAcquisitionController {
    function hasRole(bytes32 role,address account) external view returns (bool);
    function paused() external view returns (bool);
    function usdc() external view returns (IERC20);
}

/// @notice Non-upgradeable, pool-isolated acquisition custody. Treasury debt
/// is tracked at face value only; it is not a cash reserve or proof of solvency.
contract ArvoAcquisitionEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable controller;
    IERC20 public immutable usdc;

    struct Account {
        address treasury;
        uint64 opensAt;
        uint64 firstMaturity;
        bool finalized;
        uint256 cash;
        uint256 principal;
        uint256 outstandingPrincipal;
        uint256 activePositions;
        bytes32 projectId;
    }
    mapping(uint32=>Account) public accounts;
    uint256 public totalCash;
    error Unauthorized();
    error InvalidConfiguration();
    error LiquidityUnavailable();
    error UnexpectedTokenTransfer();
    event PrincipalReleased(uint32 indexed poolId,address indexed treasury,uint256 amount);
    event Repaid(uint32 indexed poolId,address indexed payer,uint256 amount,uint256 outstandingPrincipal);
    event ProjectLinked(uint32 indexed poolId,bytes32 indexed projectId);
    event ExcessWithdrawn(uint32 indexed poolId,address indexed treasury,uint256 amount);
    event Configured(uint32 indexed poolId,address indexed treasury,uint64 opensAt);
    event Deposited(uint32 indexed poolId,uint256 principal,uint64 maturity);
    event Settled(uint32 indexed poolId,address indexed owner,uint256 principal,uint256 paid);
    event Finalized(uint32 indexed poolId);
    constructor(address staking,address token) {
        if (staking.code.length==0 || token.code.length==0
            || address(IAcquisitionController(staking).usdc())!=token) revert InvalidConfiguration();
        controller=staking; usdc=IERC20(token);
    }
    modifier onlyController() { if(msg.sender!=controller) revert Unauthorized(); _; }
    modifier onlyRole(bytes32 role) {
        if(!IAcquisitionController(controller).hasRole(role,msg.sender)) revert Unauthorized(); _;
    }
    modifier onlyTreasury(uint32 poolId) {
        if(msg.sender!=accounts[poolId].treasury) revert Unauthorized(); _;
    }
    function configure(uint32 poolId,address treasury,uint64 opensAt) external onlyController {
        if(accounts[poolId].treasury!=address(0) || treasury.code.length==0
            || treasury==controller || treasury==address(this) || opensAt<=block.timestamp) revert InvalidConfiguration();
        accounts[poolId].treasury=treasury; accounts[poolId].opensAt=opensAt;
        emit Configured(poolId,treasury,opensAt);
    }
    /// @notice Optional immutable canonical project ID hash. It conveys no equity
    /// and cannot enforce external treasury spending after USDC leaves this escrow.
    function linkProject(uint32 poolId,bytes32 projectId) external onlyRole(bytes32(0)) {
        Account storage a=accounts[poolId];
        if(a.treasury==address(0) || projectId==bytes32(0) || a.projectId!=bytes32(0)
            || a.finalized || block.timestamp>=a.opensAt) revert InvalidConfiguration();
        a.projectId=projectId; emit ProjectLinked(poolId,projectId);
    }
    /// @dev Staking sends exact principal first. Unassigned direct transfers are
    /// not available to release, repay, claim or withdraw through any pool.
    function recordDeposit(uint32 poolId,uint256 amount,uint64 maturity) external onlyController {
        Account storage a=accounts[poolId];
        if(a.treasury==address(0) || a.finalized || maturity<=block.timestamp) revert InvalidConfiguration();
        if(usdc.balanceOf(address(this)) < totalCash+amount) revert UnexpectedTokenTransfer();
        a.cash+=amount; totalCash+=amount; a.principal+=amount; a.activePositions++;
        if(a.firstMaturity==0 || maturity<a.firstMaturity) a.firstMaturity=maturity;
        emit Deposited(poolId,amount,maturity);
    }
    /// @notice Only liquid principal from this pool, to its fixed reviewed treasury.
    /// @dev No maturity cutoff: Treasury may release available principal at any time.
    /// Original user due dates remain unchanged; due claims still require pool cash.
    function releasePrincipal(uint32 poolId,uint256 amount)
        external nonReentrant onlyTreasury(poolId) {
        Account storage a=accounts[poolId];
        if(IAcquisitionController(controller).paused() || a.treasury==address(0)
            || amount==0 || amount>a.cash || amount>a.principal-a.outstandingPrincipal) revert LiquidityUnavailable();
        a.cash-=amount; totalCash-=amount; a.outstandingPrincipal+=amount;
        usdc.safeTransfer(a.treasury,amount); emit PrincipalReleased(poolId,a.treasury,amount);
    }
    /// @notice Permissionless exact repayment assigned solely to the chosen pool.
    /// @dev Always available, including while paused and after finalization.
    function repay(uint32 poolId,uint256 amount) external nonReentrant {
        Account storage a=accounts[poolId];
        if(a.treasury==address(0) || amount==0) revert InvalidConfiguration();
        uint256 beforeBalance=usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender,address(this),amount);
        uint256 afterBalance=usdc.balanceOf(address(this));
        if(afterBalance<beforeBalance || afterBalance-beforeBalance!=amount) revert UnexpectedTokenTransfer();
        uint256 returnedPrincipal=amount<a.outstandingPrincipal?amount:a.outstandingPrincipal;
        a.outstandingPrincipal-=returnedPrincipal; a.cash+=amount; totalCash+=amount;
        emit Repaid(poolId,msg.sender,amount,a.outstandingPrincipal);
    }
    /// @dev Staking authenticates owner, maturity, payout and reentrancy. Effects
    /// revert atomically in both contracts if liquidity is insufficient.
    function settle(uint32 poolId,address owner,uint256 principal,uint256 paid)
        external nonReentrant onlyController {
        Account storage a=accounts[poolId];
        if(a.treasury==address(0) || a.activePositions==0 || principal>a.principal
            || paid>a.cash || a.outstandingPrincipal>a.principal-principal) revert LiquidityUnavailable();
        a.principal-=principal; a.activePositions--; a.cash-=paid; totalCash-=paid;
        if(paid!=0) usdc.safeTransfer(owner,paid);
        emit Settled(poolId,owner,principal,paid);
    }
    function finalize(uint32 poolId) external onlyController {
        accounts[poolId].finalized=true;
        emit Finalized(poolId);
    }
    /// @notice No excess can leave until every position is settled, debt is zero,
    /// and deposit-window finalization prevents creating new obligations.
    function withdrawExcess(uint32 poolId,uint256 amount)
        external nonReentrant onlyTreasury(poolId) {
        Account storage a=accounts[poolId];
        if(!a.finalized || a.activePositions!=0 || a.principal!=0 || a.outstandingPrincipal!=0
            || amount==0 || amount>a.cash) revert LiquidityUnavailable();
        a.cash-=amount; totalCash-=amount; usdc.safeTransfer(a.treasury,amount);
        emit ExcessWithdrawn(poolId,a.treasury,amount);
    }
}
