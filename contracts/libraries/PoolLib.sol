// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../interfaces/ILoan.sol";
import "../interfaces/IPool.sol";
import "../interfaces/ILoan.sol";
import "../interfaces/IServiceConfiguration.sol";
import "../FirstLossVault.sol";
import "../LoanFactory.sol";

/**
 * @title Collection of functions used by the Pool
 */
library PoolLib {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 constant RAY = 10**27;

    /**
     * @dev Emitted when first loss is supplied to the pool.
     */
    event FirstLossDeposited(
        address indexed caller,
        address indexed spender,
        uint256 amount
    );

    /**
     * @dev Emitted when first loss is withdrawn from the pool.
     */
    event FirstLossWithdrawn(
        address indexed caller,
        address indexed receiver,
        uint256 amount
    );

    /**
     * @dev See IERC4626 for event definition.
     */
    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /**
     * @dev See IPool for event definition
     */
    event LoanDefaulted(address indexed loan);

    /**
     * @dev Transfers first loss to the vault.
     * @param liquidityAsset Pool liquidity asset
     * @param amount Amount of first loss being contributed
     * @param currentState Lifecycle state of the pool
     * @param minFirstLossRequired The minimum amount of first loss the pool needs to become active
     * @return newState The updated Pool lifecycle state
     */
    function executeFirstLossDeposit(
        address liquidityAsset,
        address spender,
        uint256 amount,
        address firstLossVault,
        IPoolLifeCycleState currentState,
        uint256 minFirstLossRequired
    ) external returns (IPoolLifeCycleState newState) {
        require(firstLossVault != address(0), "Pool: 0 address");

        IERC20(liquidityAsset).safeTransferFrom(
            spender,
            firstLossVault,
            amount
        );
        newState = currentState;

        // Graduate pool state if needed
        if (
            currentState == IPoolLifeCycleState.Initialized &&
            (amount >= minFirstLossRequired ||
                IERC20(liquidityAsset).balanceOf(address(firstLossVault)) >=
                minFirstLossRequired)
        ) {
            newState = IPoolLifeCycleState.Active;
        }
        emit FirstLossDeposited(msg.sender, spender, amount);
    }

    /**
     * @dev Withdraws first loss capital. Can only be called by the Pool manager under certain conditions.
     * @param amount Amount of first loss being withdrawn
     * @param withdrawReceiver Where the liquidity should be withdrawn to
     * @param firstLossVault Vault holding first loss
     * @return newState The updated Pool lifecycle state
     */
    function executeFirstLossWithdraw(
        uint256 amount,
        address withdrawReceiver,
        address firstLossVault
    ) external returns (uint256) {
        require(firstLossVault != address(0), "Pool: 0 address");
        require(withdrawReceiver != address(0), "Pool: 0 address");

        FirstLossVault(firstLossVault).withdraw(amount, withdrawReceiver);
        emit FirstLossWithdrawn(msg.sender, withdrawReceiver, amount);
        return amount;
    }

    /**
     * @dev Computes the exchange rate for converting assets to shares
     * @param assets Amount of assets to exchange
     * @param sharesTotalSupply Supply of Vault's ERC20 shares
     * @param totalAssets Pool total assets
     * @return shares The amount of shares
     */
    function calculateAssetsToShares(
        uint256 assets,
        uint256 sharesTotalSupply,
        uint256 totalAssets
    ) external pure returns (uint256 shares) {
        if (totalAssets == 0) {
            return assets;
        }

        // TODO: add in interest rate.
        uint256 rate = (sharesTotalSupply.mul(RAY)).div(totalAssets);
        shares = (rate.mul(assets)).div(RAY);
    }

    /**
     * @dev Computes the exchange rate for converting shares to assets
     * @param shares Amount of shares to exchange
     * @param sharesTotalSupply Supply of Vault's ERC20 shares
     * @param totalAssets Pool NAV
     * @return assets The amount of shares
     */
    function calculateSharesToAssets(
        uint256 shares,
        uint256 sharesTotalSupply,
        uint256 totalAssets
    ) external pure returns (uint256 assets) {
        if (sharesTotalSupply == 0) {
            return shares;
        }

        // TODO: add in interest rate.
        uint256 rate = (totalAssets.mul(RAY)).div(sharesTotalSupply);
        assets = (rate.mul(shares)).div(RAY);
    }

    /**
     * @dev Calculates total assets held by Vault
     * @param asset Amount of total assets held by the Vault
     * @param vault Address of the ERC4626 vault
     * @param outstandingLoanPrincipals Sum of all oustanding loan principals
     * @return totalAssets Total assets
     */
    function calculateTotalAssets(
        address asset,
        address vault,
        uint256 outstandingLoanPrincipals
    ) external view returns (uint256 totalAssets) {
        totalAssets =
            IERC20(asset).balanceOf(vault) +
            outstandingLoanPrincipals;
    }

    /**
     * @dev Calculates the max deposit allowed in the pool
     * @param poolLifeCycleState The current pool lifecycle state
     * @param poolMaxCapacity Max pool capacity allowed per the pool settings
     * @param totalAssets Sum of all pool assets
     * @return Max deposit allowed
     */
    function calculateMaxDeposit(
        IPoolLifeCycleState poolLifeCycleState,
        uint256 poolMaxCapacity,
        uint256 totalAssets
    ) external pure returns (uint256) {
        return
            poolLifeCycleState == IPoolLifeCycleState.Active
                ? poolMaxCapacity - totalAssets
                : 0;
    }

    /**
     * @dev Executes a deposit into the pool
     * @param asset Pool liquidity asset
     * @param vault Address of ERC4626 vault
     * @param sharesReceiver Address of receiver of shares
     * @param assets Amount of assets being deposited
     * @param shares Amount of shares being minted
     * @param maxDeposit Max allowed deposit into the pool
     * @param mint A pointer to the mint function
     * @return The amount of shares being minted
     */
    function executeDeposit(
        address asset,
        address vault,
        address sharesReceiver,
        uint256 assets,
        uint256 shares,
        uint256 maxDeposit,
        function(address, uint256) mint
    ) internal returns (uint256) {
        require(shares > 0, "Pool: 0 deposit not allowed");
        require(assets <= maxDeposit, "Pool: Exceeds max deposit");

        IERC20(asset).safeTransferFrom(msg.sender, vault, assets);
        mint(sharesReceiver, shares);
        emit Deposit(msg.sender, sharesReceiver, assets, shares);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                    Withdrawal Request Methods
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The current withdrawal period.
     */
    function currentWithdrawPeriod(
        uint256 activatedAt,
        uint256 withdrawalWindowDuration
    ) public view returns (uint256) {
        if (activatedAt == 0) {
            return 0;
        }

        return (block.timestamp - activatedAt) / withdrawalWindowDuration;
    }

    /**
     * @dev The current withdrawal request period. Withdrawal requests made
     * made now are able to be withdrawn in the withdrawal period that matches
     * this value.
     */
    function currentRequestPeriod(
        uint256 activatedAt,
        uint256 withdrawalWindowDuration
    ) public view returns (uint256) {
        return currentWithdrawPeriod(activatedAt, withdrawalWindowDuration) + 1;
    }

    /**
     * @dev Determines whether an address corresponds to a pool loan
     * @param loan address of loan
     * @param serviceConfiguration address of service configuration
     * @param pool address of pool
     */
    function isPoolLoan(
        address loan,
        address serviceConfiguration,
        address pool
    ) public view returns (bool) {
        address factory = ILoan(loan).factory();
        return
            IServiceConfiguration(serviceConfiguration).isLoanFactory(
                factory
            ) &&
            LoanFactory(factory).isLoan(loan) &&
            ILoan(loan).pool() == pool;
    }
}