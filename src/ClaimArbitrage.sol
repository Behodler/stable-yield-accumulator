// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import "./interfaces/IClaimArbitrage.sol";
import "./interfaces/IStableYieldAccumulator.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title ClaimArbitrage
 * @notice Atomically pumps phUSD price above targetPrice, calls claim() on StableYieldAccumulator
 *         to capture discounted stablecoins, unwinds the price pump, converts profit to ETH,
 *         and sends it to the caller. All operations use Uniswap V4 PoolManager's unlock/delta
 *         accounting for flash liquidity -- no external flash loans needed.
 * @dev Implements IUnlockCallback. The execute() entry point is permissionless so MEV bots can call it.
 */
contract ClaimArbitrage is Ownable, IUnlockCallback, IClaimArbitrage {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V4 PoolManager singleton
    IPoolManager public immutable poolManager;

    /// @notice The StableYieldAccumulator to claim from
    IStableYieldAccumulator public immutable sya;

    /// @notice WETH token address
    address public immutable WETH;

    /// @notice sUSDS token address
    address public immutable sUSDS;

    /// @notice phUSD token address
    address public immutable phUSD;

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool key for the phUSD/sUSDS pool (price manipulation + unwind)
    PoolKey public phUSD_sUSDS_pool;

    /// @notice Pool key for the reward-token/WETH pool (profit conversion)
    PoolKey public rewardTokenWethPool;

    /// @notice Pool key for the sUSDS/USDC pool (slippage coverage)
    PoolKey public sUSDS_USDC_pool;

    /// @notice Mapping from stablecoin address to its reward-token conversion pool
    mapping(address => PoolKey) public stableToRewardTokenPool;

    /// @notice Iterable list of stablecoins that claim() might yield
    address[] public knownStables;

    /// @notice Whether phUSD is token0 in the phUSD/sUSDS pool
    bool public token0IsPhUSD;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the ClaimArbitrage contract
     * @param _poolManager Uniswap V4 PoolManager address
     * @param _sya StableYieldAccumulator address
     * @param _weth WETH token address
     * @param _sUSDS sUSDS token address
     * @param _phUSD phUSD token address
     */
    constructor(
        address _poolManager,
        address _sya,
        address _weth,
        address _sUSDS,
        address _phUSD
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        sya = IStableYieldAccumulator(_sya);
        WETH = _weth;
        sUSDS = _sUSDS;
        phUSD = _phUSD;
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE
    //////////////////////////////////////////////////////////////*/

    /// @notice Accept ETH from WETH unwrap
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                        ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute the atomic arbitrage. Permissionless.
     * @param params Calibrated parameters for the arbitrage
     */
    function execute(ExecuteParams calldata params) external override {
        poolManager.unlock(abi.encode(params, msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                    UNLOCK CALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by PoolManager during unlock. Performs the 9-step atomic arbitrage.
     * @param data ABI-encoded (ExecuteParams, caller address)
     * @return Empty bytes on success
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (ExecuteParams memory p, address caller) = abi.decode(data, (ExecuteParams, address));

        // ──────────────────────────────────────────────────────────
        // PRE-FLIGHT: CACHE REWARD TOKEN
        // Query sya.rewardToken() once and cache it for the entire callback.
        // Steps 2, 3, 5, and 7 all depend on the current reward token denomination.
        // Using the cached value avoids repeated STATICCALL overhead and ensures
        // consistency within a single transaction. (audit-5 M-01 fix)
        // ──────────────────────────────────────────────────────────
        address rewardToken_ = sya.rewardToken();

        // ──────────────────────────────────────────────────────────
        // PRE-FLIGHT: VALIDATE KNOWN STABLES COVERAGE
        // Ensure every SYA strategy token is in knownStables[] so Step 5 won't
        // silently skip any distributed tokens. Reverting here inside the PM callback
        // atomically unwinds all deltas — no tokens can be locked (audit M-01).
        // ──────────────────────────────────────────────────────────
        _validateKnownStablesCoverage();

        // ──────────────────────────────────────────────────────────
        // STEP 1: PUMP phUSD PRICE ABOVE TARGET
        // Swap sUSDS -> phUSD in the phUSD/sUSDS pool.
        // This buys phUSD, pushing its spot price up past targetPrice.
        // ──────────────────────────────────────────────────────────
        bool sellingToken0 = token0IsPhUSD ? false : true; // sell sUSDS side
        BalanceDelta pumpDelta = poolManager.swap(
            phUSD_sUSDS_pool,
            SwapParams({
                zeroForOne: sellingToken0,
                amountSpecified: -int256(p.pumpAmount), // negative = exact input
                sqrtPriceLimitX96: p.pumpPriceLimit
            }),
            ""
        );

        // ──────────────────────────────────────────────────────────
        // STEP 2: BORROW REWARD TOKEN (flash)
        // take() sends actual reward tokens to this contract
        // and records a negative reward-token delta (debt).
        // Note: If the reward token changes to a token with insufficient
        // PoolManager liquidity, the borrow will fail. The owner must
        // ensure adequate pool liquidity for the current reward token.
        // ──────────────────────────────────────────────────────────
        poolManager.take(Currency.wrap(rewardToken_), address(this), p.rewardTokenNeeded);

        // ──────────────────────────────────────────────────────────
        // STEP 3: CALL CLAIM
        // phUSD price is now above the floor -> claim() succeeds.
        // We pay rewardTokenNeeded in the current reward token (discounted),
        // receive full-value mixed stablecoins as real ERC20 tokens.
        // (audit-5 M-01 fix: approve the current reward token, not hardcoded USDC)
        // ──────────────────────────────────────────────────────────
        IERC20(rewardToken_).approve(address(sya), p.rewardTokenNeeded);
        sya.claim();

        // ──────────────────────────────────────────────────────────
        // STEP 4: UNWIND PRICE PUMP
        // Sell all phUSD back for sUSDS in the same pool.
        // Resolves most of the phUSD/sUSDS deltas from Step 1.
        // ──────────────────────────────────────────────────────────
        uint256 phUSD_toSell = _absDelta(pumpDelta, token0IsPhUSD);

        poolManager.swap(
            phUSD_sUSDS_pool,
            SwapParams({
                zeroForOne: !sellingToken0, // selling phUSD side now
                amountSpecified: -int256(phUSD_toSell), // exact input: sell all phUSD
                sqrtPriceLimitX96: p.unwindPriceLimit
            }),
            ""
        );

        // ──────────────────────────────────────────────────────────
        // STEP 5: CONVERT RECEIVED STABLECOINS -> REWARD TOKEN
        // For each stablecoin received from claim():
        //   1. Deposit tokens into PM (positive delta / credit)
        //   2. Swap stablecoin -> reward token within PM (adjusts deltas)
        //
        // Uses rewardToken_ cached in PRE-FLIGHT above. The reward token is a
        // property of SYA, not of this contract. If SYA's reward token ever
        // changes, this logic adapts automatically.
        // ──────────────────────────────────────────────────────────

        for (uint256 i = 0; i < knownStables.length; i++) {
            address stable = knownStables[i];
            uint256 bal = IERC20(stable).balanceOf(address(this));
            if (bal == 0) continue;

            // Deposit real tokens into PoolManager, creating positive delta for this token.
            _depositIntoPM(stable, bal);

            // If this stable IS the reward token (e.g., USDC from a USDC-yielding strategy),
            // skip the swap — it's already the target denomination. The deposit above already
            // created the positive reward-token delta we need. Attempting to swap reward->reward
            // would require a non-existent self-referential pool and is nonsensical.
            //
            // Delta accounting recap for the reward token:
            //   Step 2:  take(rewardToken, rewardTokenNeeded) -> negative reward-token delta
            //   Step 3:  claim() pays Phlimbo in reward token  -> real tokens leave contract
            //   Step 3:  claim() receives reward token from strategies -> real tokens enter contract
            //   Step 5:  _depositIntoPM(rewardToken, balance)  -> positive reward-token delta
            //   Net:     positive delta = profit from strategies minus Phlimbo payment
            //   Step 7:  swap net reward-token delta -> WETH    -> profit extraction
            if (stable == rewardToken_) continue;

            // Swap stable -> reward token (exact input)
            PoolKey memory pool = stableToRewardTokenPool[stable];
            bool stableIsToken0 = (Currency.unwrap(pool.currency0) == stable);
            poolManager.swap(
                pool,
                SwapParams({
                    zeroForOne: stableIsToken0,
                    amountSpecified: -int256(bal),
                    sqrtPriceLimitX96: stableIsToken0
                        ? type(uint160).min + 1 // selling token0, price goes down
                        : type(uint160).max - 1 // selling token1, price goes up
                }),
                ""
            );
        }

        // ──────────────────────────────────────────────────────────
        // STEP 6: COVER sUSDS ROUND-TRIP SLIPPAGE COST
        // If we still have negative sUSDS delta from pump/unwind,
        // buy a tiny amount of sUSDS with USDC to zero it out.
        // ──────────────────────────────────────────────────────────
        int256 sUSDSDelta = poolManager.currencyDelta(address(this), Currency.wrap(sUSDS));
        if (sUSDSDelta < 0) {
            uint256 sUSDS_owed = uint256(-sUSDSDelta);
            bool sUSDS_isToken0 = (Currency.unwrap(sUSDS_USDC_pool.currency0) == sUSDS);

            // Buy exact output of sUSDS_owed using USDC
            poolManager.swap(
                sUSDS_USDC_pool,
                SwapParams({
                    zeroForOne: !sUSDS_isToken0, // selling USDC side
                    amountSpecified: int256(sUSDS_owed), // positive = exact output
                    sqrtPriceLimitX96: !sUSDS_isToken0
                        ? type(uint160).min + 1
                        : type(uint160).max - 1
                }),
                ""
            );
        }

        // Step 6b: Settle any residual phUSD delta via phUSD/sUSDS pool
        _settleResidualDelta(phUSD);
        // Step 6c: Settle secondary sUSDS residual from phUSD settlement.
        // The phUSD→sUSDS swap above creates a new sUSDS delta that must be settled
        // via sUSDS_USDC_pool. The resulting USDC delta feeds into Step 7's profit conversion.
        _settleResidualDelta(sUSDS);

        // ──────────────────────────────────────────────────────────
        // STEP 7: CONVERT REWARD TOKEN PROFIT TO WETH
        // Remaining positive reward-token delta = profit minus costs.
        // Swap all of it to WETH. (audit-5 M-01 fix: use rewardToken_, not hardcoded USDC)
        // ──────────────────────────────────────────────────────────
        int256 rewardTokenProfit = poolManager.currencyDelta(address(this), Currency.wrap(rewardToken_));
        if (rewardTokenProfit <= 0) revert NoProfit();

        bool rewardTokenIsToken0 = (Currency.unwrap(rewardTokenWethPool.currency0) == rewardToken_);
        poolManager.swap(
            rewardTokenWethPool,
            SwapParams({
                zeroForOne: rewardTokenIsToken0,
                amountSpecified: -int256(uint256(rewardTokenProfit)), // exact input: sell all reward token
                sqrtPriceLimitX96: rewardTokenIsToken0
                    ? type(uint160).min + 1
                    : type(uint160).max - 1
            }),
            ""
        );

        // ──────────────────────────────────────────────────────────
        // STEP 8: EXTRACT WETH PROFIT
        // take() converts positive WETH delta into actual WETH tokens.
        // ──────────────────────────────────────────────────────────
        int256 wethDelta = poolManager.currencyDelta(address(this), Currency.wrap(WETH));
        if (wethDelta <= 0) revert NoWETHProfit();

        uint256 profit = uint256(wethDelta);
        poolManager.take(Currency.wrap(WETH), address(this), profit);

        // ──────────────────────────────────────────────────────────
        // STEP 9: UNWRAP WETH -> ETH AND SEND TO CALLER
        // ──────────────────────────────────────────────────────────
        IWETH(WETH).withdraw(profit);
        (bool ok,) = caller.call{value: profit}("");
        if (!ok) revert ETHTransferFailed();

        emit ArbitrageExecuted(caller, profit);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deposit ERC20 tokens into PoolManager, creating a positive (credit) delta.
     *      Pattern: sync -> transfer -> settle
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function _depositIntoPM(address token, uint256 amount) internal {
        poolManager.sync(Currency.wrap(token));
        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    /**
     * @dev Extract the absolute amount for one side of a BalanceDelta
     * @param delta The balance delta from a swap
     * @param useToken0 Whether to extract the token0 amount
     * @return The absolute value of the specified side
     */
    function _absDelta(BalanceDelta delta, bool useToken0) internal pure returns (uint256) {
        int128 raw = useToken0 ? delta.amount0() : delta.amount1();
        return raw > 0 ? uint256(uint128(raw)) : uint256(uint128(-raw));
    }

    /**
     * @dev If a currency has residual delta (positive or negative), settle it to zero.
     *      - Zero delta: no-op.
     *      - Positive delta (credit owed by PM to the contract): stay internal to PM's
     *        delta accounting by swapping the credit to the reward token so it contributes
     *        to Step 7's profit conversion. If the token IS the reward token, return
     *        immediately — the positive delta will be picked up by Step 7's currencyDelta
     *        query. No take() is needed because the credit remains within PM's accounting
     *        and feeds directly into the profit pipeline (Steps 7-9).
     *      - Negative delta: buy the owed amount via the configured pool (stableToRewardTokenPool,
     *        sUSDS_USDC_pool, or phUSD_sUSDS_pool fallback).
     *
     *      Note on sUSDS_USDC_pool: This pool is genuinely an sUSDS/USDC pool used for slippage
     *      coverage from the pump/unwind cycle. It is not renamed to reference the dynamic reward
     *      token because it handles a specific known pair (sUSDS<->USDC). If the reward token
     *      changes from USDC, the owner must update this pool accordingly. The settlement cost
     *      feeds into the reward-token delta via Step 7's profit conversion.
     * @param token The token to check and settle
     */
    function _settleResidualDelta(address token) internal {
        int256 d = poolManager.currencyDelta(address(this), Currency.wrap(token));
        if (d == 0) return;

        if (d > 0) {
            // Positive delta: credit owed by PM to the contract.
            // Stay internal to PM's delta accounting — swap the credit to the
            // reward token so it contributes to Step 7's profit conversion.
            address rewardToken_ = sya.rewardToken();
            if (token == rewardToken_) {
                // Already in reward-token denomination. The positive delta
                // will be picked up by Step 7's currencyDelta query.
                return;
            }

            // Swap the positive credit to reward token within PM.
            // The positive delta IS the input — no take() or deposit needed.
            PoolKey memory pool = stableToRewardTokenPool[token];
            if (Currency.unwrap(pool.currency0) == address(0)
                && Currency.unwrap(pool.currency1) == address(0))
            {
                if (token == sUSDS) {
                    pool = sUSDS_USDC_pool;
                } else if (token == phUSD) {
                    pool = phUSD_sUSDS_pool;
                } else {
                    revert UnsettledResidualForUnconfiguredToken(token);
                }
            }

            bool tokenIsToken0 = (Currency.unwrap(pool.currency0) == token);
            poolManager.swap(
                pool,
                SwapParams({
                    zeroForOne: tokenIsToken0,
                    amountSpecified: -int256(uint256(d)), // exact input: sell the positive delta
                    sqrtPriceLimitX96: tokenIsToken0
                        ? type(uint160).min + 1
                        : type(uint160).max - 1
                }),
                ""
            );
            return;
        }

        // Negative delta: need to buy `token` to zero the debt.
        // Use the stableToRewardTokenPool mapping if available, otherwise use hardcoded fallbacks.
        PoolKey memory pool = stableToRewardTokenPool[token];
        if (Currency.unwrap(pool.currency0) == address(0) && Currency.unwrap(pool.currency1) == address(0)) {
            if (token == sUSDS) {
                pool = sUSDS_USDC_pool;
            } else if (token == phUSD) {
                pool = phUSD_sUSDS_pool;
            } else {
                revert UnsettledResidualForUnconfiguredToken(token);
            }
        }

        uint256 owed = uint256(-d);
        bool tokenIsToken0 = (Currency.unwrap(pool.currency0) == token);

        // Buy exact output of owed amount
        poolManager.swap(
            pool,
            SwapParams({
                zeroForOne: !tokenIsToken0, // selling the other side
                amountSpecified: int256(owed), // positive = exact output
                sqrtPriceLimitX96: !tokenIsToken0
                    ? type(uint160).min + 1
                    : type(uint160).max - 1
            }),
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                        RESCUE & VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rescue stranded ERC20 tokens from the contract (audit M-01 mitigation A).
     * @dev Safety net for any tokens that become trapped, regardless of cause.
     *      Only callable by the contract owner.
     * @param token The ERC20 token to rescue
     * @param to The recipient address (must not be zero address)
     * @param amount The amount to rescue
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @dev Validates that every token SYA's yield strategies might distribute is present in
    ///      knownStables[]. This is a one-directional check: knownStables CAN be a superset
    ///      (CA may preemptively register tokens before SYA adds the strategy), but SYA strategy
    ///      tokens must never be absent from knownStables, otherwise Step 5 would silently skip
    ///      them and they'd be permanently locked in this contract (audit finding M-01).
    ///
    ///      Gas: O(n*m) where n = strategies, m = knownStables. Both arrays are expected to be
    ///      small (single digits), so this is acceptable.
    function _validateKnownStablesCoverage() internal view {
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            address token = sya.strategyTokens(strategies[i]);
            bool found = false;
            for (uint256 j = 0; j < knownStables.length; j++) {
                if (knownStables[j] == token) {
                    found = true;
                    break;
                }
            }
            if (!found) revert StrategyTokenNotInKnownStables(token);
        }
    }

    /**
     * @notice Public wrapper for off-chain verification of strategy coverage.
     * @dev Allows bots and monitoring to check if knownStables[] covers all SYA strategy tokens
     *      before attempting execute(). Reverts with StrategyTokenNotInKnownStables if not.
     */
    function validateKnownStablesCoverage() external view {
        _validateKnownStablesCoverage();
    }

    /*//////////////////////////////////////////////////////////////
                        OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the pool key mapping for a stablecoin to reward-token conversion
     * @param stable The stablecoin address
     * @param pool The PoolKey for the stable/reward-token pool
     */
    function setStableToRewardTokenPool(address stable, PoolKey calldata pool) external onlyOwner {
        stableToRewardTokenPool[stable] = pool;
        emit StableToRewardTokenPoolSet(stable);
    }

    /**
     * @notice Add a stablecoin to the known stables list
     * @param stable The stablecoin address to add
     */
    function addKnownStable(address stable) external onlyOwner {
        knownStables.push(stable);
        emit KnownStableAdded(stable);
    }

    /**
     * @notice Remove a stablecoin from the known stables list
     * @param stable The stablecoin address to remove
     */
    function removeKnownStable(address stable) external onlyOwner {
        for (uint256 i = 0; i < knownStables.length; i++) {
            if (knownStables[i] == stable) {
                knownStables[i] = knownStables[knownStables.length - 1];
                knownStables.pop();
                emit KnownStableRemoved(stable);
                return;
            }
        }
    }

    /**
     * @notice Set the pool keys for the three main pools and the token ordering flag
     * @param _phUSD_sUSDS_pool Pool key for phUSD/sUSDS
     * @param _rewardTokenWethPool Pool key for reward-token/WETH
     * @param _sUSDS_USDC_pool Pool key for sUSDS/USDC
     * @param _token0IsPhUSD Whether phUSD is token0 in the phUSD/sUSDS pool
     */
    function setPoolKeys(
        PoolKey calldata _phUSD_sUSDS_pool,
        PoolKey calldata _rewardTokenWethPool,
        PoolKey calldata _sUSDS_USDC_pool,
        bool _token0IsPhUSD
    ) external onlyOwner {
        phUSD_sUSDS_pool = _phUSD_sUSDS_pool;
        rewardTokenWethPool = _rewardTokenWethPool;
        sUSDS_USDC_pool = _sUSDS_USDC_pool;
        token0IsPhUSD = _token0IsPhUSD;
        emit PoolKeysUpdated();
    }

    /**
     * @notice Get all known stablecoins
     * @return Array of known stablecoin addresses
     */
    function getKnownStables() external view returns (address[] memory) {
        return knownStables;
    }
}
