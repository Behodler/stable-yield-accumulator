// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IClaimArbitrage
 * @notice Interface for the ClaimArbitrage contract that atomically pumps phUSD price,
 *         claims discounted stablecoins, unwinds the price pump, and converts profit to ETH.
 */
interface IClaimArbitrage {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Parameters for executing the atomic arbitrage
     * @param pumpAmount sUSDS to sell for phUSD (calibrated off-chain to just cross targetPrice)
     * @param usdcNeeded USDC to borrow for claim payment (= calculateClaimAmount())
     * @param pumpPriceLimit max sqrtPriceX96 willing to pay when buying phUSD
     * @param unwindPriceLimit min sqrtPriceX96 willing to accept when selling phUSD back
     */
    struct ExecuteParams {
        uint256 pumpAmount;
        uint256 usdcNeeded;
        uint160 pumpPriceLimit;
        uint160 unwindPriceLimit;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an arbitrage is successfully executed
     * @param caller The address that initiated the arbitrage
     * @param ethProfit The amount of ETH profit sent to the caller
     */
    event ArbitrageExecuted(address indexed caller, uint256 ethProfit);

    /**
     * @notice Emitted when a stable-to-USDC pool mapping is updated
     * @param stable The stablecoin address
     */
    event StableToUSDCPoolSet(address indexed stable);

    /**
     * @notice Emitted when a known stablecoin is added
     * @param stable The stablecoin address added
     */
    event KnownStableAdded(address indexed stable);

    /**
     * @notice Emitted when a known stablecoin is removed
     * @param stable The stablecoin address removed
     */
    event KnownStableRemoved(address indexed stable);

    /**
     * @notice Emitted when pool keys are updated
     */
    event PoolKeysUpdated();

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when the callback caller is not the PoolManager
     */
    error OnlyPoolManager();

    /**
     * @notice Thrown when the arbitrage produces no USDC profit
     */
    error NoProfit();

    /**
     * @notice Thrown when the USDC-to-WETH conversion produces no WETH
     */
    error NoWETHProfit();

    /**
     * @notice Thrown when ETH transfer to the caller fails
     */
    error ETHTransferFailed();

    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute the atomic arbitrage. Permissionless -- anyone (including MEV bots) can call.
     * @param params The calibrated parameters for the arbitrage
     */
    function execute(ExecuteParams calldata params) external;
}
