// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../IFlax.sol";

/**
 * @title IPhlimbo
 * @notice Interface for the PhlimboEA staking yield farm contract
 */
interface IPhlimbo {
    // ========================== ADMIN FUNCTIONS ==========================

    /**
     * @notice Updates the desired APY and recalculates emission rate
     * @param bps New APY in basis points
     */
    function setDesiredAPY(uint256 bps) external;

    /**
     * @notice Sets the yield accumulator address
     * @param _yieldAccumulator New yield accumulator address
     */
    function setYieldAccumulator(address _yieldAccumulator) external;

    /**
     * @notice Sets the EMA alpha parameter
     * @param _alpha New alpha value (scaled by 1e18)
     */
    function setAlpha(uint256 _alpha) external;

    /**
     * @notice Unpauses the contract (only owner)
     */
    function unpause() external;

    /**
     * @notice Sets the address authorized to pause the contract
     * @param _pauser Address to authorize for pausing (can be zero address to disable pausing)
     */
    function setPauser(address _pauser) external;

    /**
     * @notice Emergency function to transfer all tokens to a recipient
     * @param recipient Address to receive the tokens
     */
    function emergencyTransfer(address recipient) external;

    // ========================== PAUSE MECHANISM ==========================

    /**
     * @notice Pauses the contract
     * @dev Can only be called by the designated pauser address
     */
    function pause() external;

    // ========================== REWARD COLLECTION ==========================

    /**
     * @notice Collects rewards from yield-accumulator and updates EMA-smoothed rate
     * @dev Can only be called by the yield accumulator contract
     * @param amount Amount of reward tokens to collect
     */
    function collectReward(uint256 amount) external;

    // ========================== CORE STAKING FUNCTIONS ==========================

    /**
     * @notice Stake phUSD tokens
     * @param amount Amount of phUSD to stake
     */
    function stake(uint256 amount) external;

    /**
     * @notice Withdraw staked phUSD and claim rewards
     * @param amount Amount of phUSD to withdraw
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Claim pending rewards without withdrawing stake
     */
    function claim() external;

    // ========================== VIEW FUNCTIONS ==========================

    /**
     * @notice Returns pending phUSD rewards for a user
     * @param user Address to check
     * @return Pending phUSD amount
     */
    function pendingPhUSD(address user) external view returns (uint256);

    /**
     * @notice Returns pending stable rewards for a user
     * @param user Address to check
     * @return Pending stable amount
     */
    function pendingStable(address user) external view returns (uint256);

    /**
     * @notice Returns current pool information
     * @return _totalStaked Total staked amount
     * @return _accPhUSDPerShare Accumulated phUSD per share
     * @return _accStablePerShare Accumulated stable per share
     * @return _phUSDPerSecond Current emission rate
     * @return _lastRewardTime Last update time
     */
    function getPoolInfo() external view returns (
        uint256 _totalStaked,
        uint256 _accPhUSDPerShare,
        uint256 _accStablePerShare,
        uint256 _phUSDPerSecond,
        uint256 _lastRewardTime
    );

    // ========================== STATE VARIABLE GETTERS ==========================

    function phUSD() external view returns (IFlax);
    function rewardToken() external view returns (IERC20);
    function yieldAccumulator() external view returns (address);
    function pauser() external view returns (address);
    function desiredAPYBps() external view returns (uint256);
    function phUSDPerSecond() external view returns (uint256);
    function lastClaimTimestamp() external view returns (uint256);
    function smoothedStablePerSecond() external view returns (uint256);
    function alpha() external view returns (uint256);
    function lastRewardTime() external view returns (uint256);
    function accPhUSDPerShare() external view returns (uint256);
    function accStablePerShare() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function PRECISION() external view returns (uint256);
    function SECONDS_PER_YEAR() external view returns (uint256);
    function userInfo(address user) external view returns (uint256 amount, uint256 phUSDDebt, uint256 stableDebt);
}
