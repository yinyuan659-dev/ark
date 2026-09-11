// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {TickMath} from "./TickMath.sol";

/// @title SwapGuard
/// @notice Two defences for swaps the protocol executes on behalf of others (fee conversion in the FeeLocker,
///         the platform-token buyback in the Treasury), both of which are *permissionless* and therefore can be
///         wrapped in a single attacker transaction (push price → call us → unwind):
///
///         1. `twapMinOut` — a floor on the output derived from the pool's own time-weighted price over the
///            last `window` seconds (or as far back as the pool's observations reach). An atomic sandwich only
///            moves the spot price; the TWAP barely moves, so the swap reverts / is deferred instead of filling
///            at the manipulated price. Every launch pool gets `OBSERVATIONS` slots so the window has depth.
///         2. `maxAmountInForImpact` — a cap on how much we sell in one call so our own price impact stays under
///            `impactBps`. Sandwiching a trade whose impact is below the pool's round-trip fee (2 × 1%) cannot
///            be profitable, whatever the attacker does. The remainder waits for the next call.
library SwapGuard {
    /// @dev Observation slots requested for every launch pool (one-off cost at launch, ~20k gas per slot).
    uint16 internal constant OBSERVATIONS = 50;
    /// @dev TWAP lookback. Short enough that volatile tokens don't trip the guard, long enough that holding a
    ///      manipulated price across the window costs real money against the 1% pool fee.
    uint32 internal constant WINDOW = 10 minutes;
    /// @dev Accept at most this much below the TWAP-implied output (covers the 1% pool fee, our own impact
    ///      cap and normal drift inside the window).
    uint16 internal constant TOLERANCE_BPS = 1_000; // 10%
    /// @dev Own-impact cap per call; strictly below the 2% an attacker pays in fees to sandwich us.
    uint16 internal constant MAX_IMPACT_BPS = 150; // 1.5%

    /// @notice Time-weighted sqrt price over min(WINDOW, available history). Falls back to spot when the pool
    ///         has no history older than this block (only right after launch).
    function twapSqrtPriceX96(IUniswapV3Pool pool) internal view returns (uint160 sqrtPriceX96, uint32 window) {
        (uint160 spot,, uint16 index, uint16 cardinality,,,) = pool.slot0();
        (uint32 oldestTs,,, bool initialized) = pool.observations((uint256(index) + 1) % cardinality);
        if (!initialized) (oldestTs,,,) = pool.observations(0);
        uint32 available = uint32(block.timestamp) - oldestTs;
        window = available < WINDOW ? available : WINDOW;
        if (window == 0) return (spot, 0);

        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        (int56[] memory tc,) = pool.observe(ago);
        int56 delta = tc[1] - tc[0];
        int24 meanTick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) meanTick--; // round toward -inf like OracleLibrary
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(meanTick);
    }

    /// @notice Output `amountIn` would fetch at `sqrtPriceX96` with no fee and no impact.
    function quoteAtSqrtPrice(uint160 sqrtPriceX96, uint256 amountIn, bool zeroForOne) internal pure returns (uint256) {
        uint256 p = uint256(sqrtPriceX96);
        if (zeroForOne) {
            // token0 in → token1 out: out = in · P, P = (sqrtP / 2^96)^2
            return Math.mulDiv(Math.mulDiv(amountIn, p, 1 << 96), p, 1 << 96);
        }
        // token1 in → token0 out: out = in / P
        return Math.mulDiv(Math.mulDiv(amountIn, 1 << 96, p), 1 << 96, p);
    }

    /// @notice Minimum acceptable output for selling `amountIn` right now: TWAP quote minus tolerance.
    function twapMinOut(IUniswapV3Pool pool, uint256 amountIn, bool zeroForOne) internal view returns (uint256) {
        (uint160 twap,) = twapSqrtPriceX96(pool);
        uint256 fair = quoteAtSqrtPrice(twap, amountIn, zeroForOne);
        return (fair * (10_000 - TOLERANCE_BPS)) / 10_000;
    }

    /// @dev How many tick-spacings we look ahead for liquidity when none is in range (launch pools sit exactly
    ///      at the edge of their single position until the first trade).
    uint256 internal constant LOOKAHEAD_SPACINGS = 8;

    /// @notice Liquidity the next trade in direction `zeroForOne` would meet: the in-range liquidity, or — when
    ///         the price sits just outside every position (fresh launch, or everything sold back to the floor) —
    ///         the liquidity of the first initialized tick ahead.
    function liquidityAhead(IUniswapV3Pool pool, bool zeroForOne) internal view returns (uint128 L) {
        L = pool.liquidity();
        if (L != 0) return L;
        (, int24 tick,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--; // floor
        int24 base = c * spacing;
        for (uint256 i; i < LOOKAHEAD_SPACINGS; ++i) {
            // going down (zeroForOne) the first candidate is the floor itself; going up it is the next spacing
            int24 t = zeroForOne ? base - int24(int256(i)) * spacing : base + int24(int256(i + 1)) * spacing;
            (uint128 gross,,,,,,, bool init) = pool.ticks(t);
            if (init) return gross;
        }
    }

    /// @notice Largest input that moves the pool price by at most `MAX_IMPACT_BPS`, using the liquidity the
    ///         trade would meet (exact for our single-position pools while the trade stays inside the position).
    /// @return 0 when there is no liquidity ahead (nothing can be sold anyway).
    function maxAmountInForImpact(IUniswapV3Pool pool, bool zeroForOne) internal view returns (uint256) {
        uint128 L = liquidityAhead(pool, zeroForOne);
        if (L == 0) return 0;
        (uint160 sqrtP,,,,,,) = pool.slot0();
        // price moves by `impact` ⇒ sqrt price moves by ≈ impact / 2
        if (zeroForOne) {
            // Δx = L · Δ(1/√P) = L · 2^96 / √P · (impact / 2)
            return (Math.mulDiv(L, 1 << 96, sqrtP) * MAX_IMPACT_BPS) / 20_000;
        }
        // Δy = L · Δ√P / 2^96 = L · √P / 2^96 · (impact / 2)
        return (Math.mulDiv(L, sqrtP, 1 << 96) * MAX_IMPACT_BPS) / 20_000;
    }
}
