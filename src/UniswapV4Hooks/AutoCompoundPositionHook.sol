// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAutoCompoundPositionHook} from "./IAutoCompoundPositionHook.sol";

/// @title AutoCompoundPositionHook
/// @notice A Uniswap V4 hook that charges an additional fee on swaps and auto-compounds
/// collected fees into its own concentrated liquidity position.
/// @dev This hook:
/// - Charges a configurable fee (default 0.05%) on top of the pool's base fee
/// - Maintains its own liquidity position with configurable tick range
/// - Auto-compounds collected fees when in-range and above a threshold
/// - Is ownable with admin functions to adjust parameters
contract AutoCompoundPositionHook is BaseHook, Ownable, IAutoCompoundPositionHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ============ Immutables ============

    /// @notice The pool key this hook is bound to
    PoolKey private _poolKey;

    /// @notice The pool ID this hook is bound to
    PoolId public immutable poolId;

    // ============ State Variables ============

    /// @notice Whether the hook is active (charges fees and compounds)
    bool public active = true;

    /// @notice Hook fee in basis points (5 = 0.05%)
    uint256 public taxBps = 5;

    /// @notice Which token is used for threshold checking (0 or 1)
    uint256 public thresholdTokenIndex = 0;

    /// @notice Minimum balance of threshold token required to trigger compounding
    uint256 public thresholdAmount;

    /// @notice Lower tick boundary of the hook's position
    int24 public tickLower;

    /// @notice Upper tick boundary of the hook's position
    int24 public tickUpper;

    /// @notice Salt to uniquely identify the hook's position
    bytes32 public positionSalt;

    // ============ Constructor ============

    /// @notice Creates a new AutoCompoundPositionHook
    /// @param _poolManager The Uniswap V4 pool manager
    /// @param poolKey_ The pool key (must have hooks = this contract)
    /// @param _tickLower Lower tick of initial position
    /// @param _tickUpper Upper tick of initial position
    /// @param _salt Salt for position uniqueness
    /// @param _thresholdTokenIndex Which token for threshold (0 or 1)
    /// @param _thresholdAmount Minimum balance to trigger compounding
    constructor(
        IPoolManager _poolManager,
        PoolKey memory poolKey_,
        int24 _tickLower,
        int24 _tickUpper,
        bytes32 _salt,
        uint256 _thresholdTokenIndex,
        uint256 _thresholdAmount
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        require(_thresholdTokenIndex == 0 || _thresholdTokenIndex == 1, "bad threshold index");
        require(_tickLower < _tickUpper, "bad ticks");
        _validatePoolKeyHooks(poolKey_);

        _poolKey = poolKey_;
        poolId = poolKey_.toId();

        tickLower = _tickLower;
        tickUpper = _tickUpper;
        positionSalt = _salt;

        thresholdTokenIndex = _thresholdTokenIndex;
        thresholdAmount = _thresholdAmount;
    }

    // ============ View Functions ============

    /// @inheritdoc IAutoCompoundPositionHook
    function poolKey()
        external
        view
        returns (
            address currency0,
            address currency1,
            uint24 fee,
            int24 tickSpacing,
            address hooks
        )
    {
        return (
            Currency.unwrap(_poolKey.currency0),
            Currency.unwrap(_poolKey.currency1),
            _poolKey.fee,
            _poolKey.tickSpacing,
            address(_poolKey.hooks)
        );
    }

    // ============ Hook Permissions ============

    /// @notice Returns the hook permissions for this contract
    /// @dev Only afterSwap and afterSwapReturnDelta are enabled
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Owner Functions ============

    /// @inheritdoc IAutoCompoundPositionHook
    function setThresholdToken(uint256 index) external onlyOwner {
        require(index == 0 || index == 1, "bad index");
        thresholdTokenIndex = index;
        emit ThresholdTokenSet(index);
    }

    /// @inheritdoc IAutoCompoundPositionHook
    function changeThreshold(uint256 amount) external onlyOwner {
        thresholdAmount = amount;
        emit ThresholdAmountSet(amount);
    }

    /// @inheritdoc IAutoCompoundPositionHook
    function modifyPosition(int24 _tickLower, int24 _tickUpper, bytes32 _salt) external onlyOwner {
        require(_tickLower < _tickUpper, "bad ticks");
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        positionSalt = _salt;
        emit PositionParamsSet(_tickLower, _tickUpper, _salt);
    }

    /// @inheritdoc IAutoCompoundPositionHook
    function setActive(bool _active) external onlyOwner {
        active = _active;
        emit ActiveSet(_active);
    }

    /// @inheritdoc IAutoCompoundPositionHook
    function setTaxPercentage(uint256 basisPoints) external onlyOwner {
        require(basisPoints <= 10_000, "bps>100%");
        taxBps = basisPoints;
        emit TaxBpsSet(basisPoints);
    }

    /// @inheritdoc IAutoCompoundPositionHook
    function withdrawLiquidity(address recipient) external onlyOwner {
        require(recipient != address(0), "bad recipient");

        (uint128 liq,,) =
            poolManager.getPositionInfo(poolId, address(this), tickLower, tickUpper, positionSalt);
        require(liq > 0, "no liquidity");

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liq)),
                salt: positionSalt
            }),
            ""
        );

        (uint256 out0, uint256 out1) = _takePositiveDeltaToRecipient(delta, recipient);
        emit LiquidityWithdrawn(recipient, liq, out0, out1);
    }

    // ============ Public Functions ============

    /// @inheritdoc IAutoCompoundPositionHook
    function poke() external {
        _tryCompound();
    }

    // ============ Hook Callbacks ============

    /// @notice Called after a swap to charge the hook fee and attempt compounding
    /// @dev Only processes swaps for the bound pool. When inactive, no fee is charged.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (PoolId.unwrap(PoolIdLibrary.toId(key)) != PoolId.unwrap(poolId)) return (this.afterSwap.selector, 0);

        // When inactive, behave like normal pool
        if (!active) return (this.afterSwap.selector, 0);

        uint256 feeAmount = 0;

        if (taxBps != 0) {
            // Unspecified currency mapping:
            // exactIn  => unspecified is output token (reduce output)
            // exactOut => unspecified is input token (increase input)
            bool exactIn = (params.amountSpecified < 0);

            bool outputIsToken0 = !params.zeroForOne;
            Currency feeCurrency;
            int256 taxableSigned;

            if (exactIn) {
                feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
                taxableSigned = outputIsToken0 ? delta.amount0() : delta.amount1();
            } else {
                bool inputIsToken0 = params.zeroForOne;
                feeCurrency = inputIsToken0 ? key.currency0 : key.currency1;
                taxableSigned = inputIsToken0 ? delta.amount0() : delta.amount1();
            }

            if (taxableSigned > 0) {
                uint256 taxable = uint256(taxableSigned);
                feeAmount = (taxable * taxBps) / 10_000;

                if (feeAmount != 0) {
                    // Pull fee into hook balance
                    poolManager.take(feeCurrency, address(this), feeAmount);
                }
            }
        }

        // Attempt compound on every swap
        _tryCompound();

        if (feeAmount == 0) return (this.afterSwap.selector, 0);

        require(feeAmount <= uint256(uint128(type(int128).max)), "fee too large");
        return (this.afterSwap.selector, int128(int256(feeAmount)));
    }

    // ============ Internal Functions ============

    /// @notice Attempts to compound collected fees into the hook's position
    /// @dev Only compounds when:
    ///      - Hook is active
    ///      - Current tick is strictly within position range
    ///      - Threshold token balance meets threshold amount
    function _tryCompound() internal {
        if (!active) return;

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);

        // Strictly in-range only
        if (tick <= tickLower || tick >= tickUpper) return;

        Currency c0 = _poolKey.currency0;
        Currency c1 = _poolKey.currency1;

        uint256 bal0 = _balanceOf(c0);
        uint256 bal1 = _balanceOf(c1);

        if (thresholdTokenIndex == 0) {
            if (bal0 < thresholdAmount) return;
        } else {
            if (bal1 < thresholdAmount) return;
        }

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liq;
        uint256 req0;
        uint256 req1;

        if (thresholdTokenIndex == 0) {
            liq = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtB, bal0);
            (req0, req1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liq);

            // If token1 is insufficient, fall back to max-liquidity using both balances
            if (req1 > bal1) {
                liq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, bal0, bal1);
                (req0, req1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liq);
            }
        } else {
            liq = LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtPriceX96, bal1);
            (req0, req1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liq);

            if (req0 > bal0) {
                liq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, bal0, bal1);
                (req0, req1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liq);
            }
        }

        if (liq == 0) return;

        (BalanceDelta d,) = poolManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liq)),
                salt: positionSalt
            }),
            ""
        );

        // Settle what we owe (negative deltas)
        _settleNegativeDelta(d);

        emit Compounded(req0, req1, liq);
    }

    /// @notice Returns the balance of a currency held by this contract
    function _balanceOf(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) return address(this).balance;
        return currency.balanceOf(address(this));
    }

    /// @notice Settles negative deltas by paying tokens to the pool manager
    function _settleNegativeDelta(BalanceDelta d) internal {
        int256 a0 = d.amount0();
        int256 a1 = d.amount1();

        if (a0 < 0) _pay(_poolKey.currency0, uint256(-a0));
        if (a1 < 0) _pay(_poolKey.currency1, uint256(-a1));
    }

    /// @notice Pays a currency amount to the pool manager
    function _pay(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Takes positive deltas from the pool and sends to recipient
    function _takePositiveDeltaToRecipient(BalanceDelta d, address recipient)
        internal
        returns (uint256 out0, uint256 out1)
    {
        int256 a0 = d.amount0();
        int256 a1 = d.amount1();

        if (a0 > 0) {
            out0 = uint256(a0);
            poolManager.take(_poolKey.currency0, recipient, out0);
        }
        if (a1 > 0) {
            out1 = uint256(a1);
            poolManager.take(_poolKey.currency1, recipient, out1);
        }
    }

    /// @notice Computes the token0 and token1 value for a given amount of liquidity
    /// @dev This is a local implementation since v4-periphery's LiquidityAmounts
    ///      doesn't include getAmountsForLiquidity
    function _getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = _getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = _getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = _getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = _getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity
    function _getAmount0ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION,
            sqrtPriceBX96 - sqrtPriceAX96,
            sqrtPriceBX96
        ) / sqrtPriceAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity
    function _getAmount1ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        return FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
    }

    /// @notice Validates that the poolKey.hooks matches this contract address
    /// @dev This function is virtual to allow testing scenarios where the hook
    ///      needs to be deployed at a specific address
    function _validatePoolKeyHooks(PoolKey memory poolKey_) internal view virtual {
        require(address(poolKey_.hooks) == address(this), "PoolKey.hooks != this");
    }

    /// @notice Allows the contract to receive native tokens
    receive() external payable {}
}
