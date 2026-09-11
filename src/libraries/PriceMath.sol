// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Start-price helpers for a 1e9 × 1e18 supply token quoted in 6-decimal USDC.
/// @dev price_raw = usdcRaw / tokenRaw. With market cap M (USDC, 6 decimals): price_raw = M / 1e27.
library PriceMath {
    uint256 internal constant SUPPLY_RAW = 1_000_000_000e18;
    uint256 internal constant SCALE = 1e27; // 1e9 tokens × 1e18 / 1e6 → M(6dec)/1e27 = price_raw

    /// @param mcapUsdc target market cap in USDC (6 decimals)
    /// @param tokenIsToken0 whether the launch token sorts below USDC
    function sqrtPriceX96ForMcap(uint256 mcapUsdc, bool tokenIsToken0) internal pure returns (uint160) {
        require(mcapUsdc > 0, "mcap");
        uint256 s;
        if (tokenIsToken0) {
            // sqrt(M/1e27) · 2^96 = sqrt((M << 128) / 1e27) << 32
            s = Math.sqrt((mcapUsdc << 128) / SCALE) << 32;
        } else {
            // price_raw = 1e27 / M
            s = Math.sqrt((SCALE << 128) / mcapUsdc) << 32;
        }
        require(s > 0 && s < type(uint160).max, "sqrtP");
        return uint160(s);
    }

    /// @notice Spot market cap in USDC (6 decimals) from a pool sqrt price.
    function mcapFromSqrtPriceX96(uint160 sqrtPriceX96, bool tokenIsToken0) internal pure returns (uint256) {
        // price_raw = (sqrtP / 2^96)^2 ; mcap = price_raw · 1e27 (token0) or 1e27 / price_raw (token1)
        uint256 p = uint256(sqrtPriceX96);
        if (tokenIsToken0) {
            // (p^2 · 1e27) / 2^192, computed as ((p·p) >> 64 · 1e27) >> 128 to avoid overflow for small p
            uint256 pp = Math.mulDiv(p, p, 1 << 64);
            return Math.mulDiv(pp, SCALE, 1 << 128);
        } else {
            uint256 pp = Math.mulDiv(p, p, 1 << 64); // price_raw · 2^128
            return Math.mulDiv(SCALE, 1 << 128, pp);
        }
    }
}
