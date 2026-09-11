// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Treasury} from "../src/Treasury.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {SwapGuard} from "../src/libraries/SwapGuard.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

/// @notice Griefing / MEV hardening: pool pre-creation cannot block launches, and the protocol's own swaps
///         (fee conversion, buyback) can neither be filled at a manipulated price nor be profitably sandwiched.
contract GuardTest is Base {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        usdc.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        usdc.approve(address(router), type(uint256).max);
        vm.warp(1_700_000_000);
        vm.roll(1000);
    }

    // ------------------------------------------------------------ TickMath port

    /// @dev Our 0.8 TickMath must agree with the tick the (official, vendored) pool bytecode derives from a price:
    ///      ratio(tick) <= sqrtP < ratio(tick + 1), across orientations, market caps and after trades.
    function test_tickMath_matchesPoolAcrossPrices() public {
        uint256[4] memory mcaps = [uint256(500e6), 5_000e6, 1_000_000e6, 10_000_000e6];
        for (uint256 i; i < mcaps.length; ++i) {
            setStartMcap(mcaps[i]);
            for (uint256 k; k < 3; ++k) {
                (address token, address pool) = doLaunch(creator, string.concat("TM", vm.toString(i * 3 + k)), 0);
                _assertTickConsistent(pool);
                vm.roll(block.number + 30);
                buy(buyer, token, 200e6 + k * 700e6);
                _assertTickConsistent(pool);
                vm.roll(block.number + 1);
            }
        }
    }

    function _assertTickConsistent(address pool) internal view {
        (uint160 sqrtP, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        assertLe(TickMath.getSqrtRatioAtTick(tick), sqrtP, "ratio(tick) <= price");
        assertGt(TickMath.getSqrtRatioAtTick(tick + 1), sqrtP, "price < ratio(tick+1)");
    }

    // ------------------------------------------------------------ pool pre-creation griefing

    function test_grief_preCreatedPoolDoesNotBlockLaunch() public {
        LaunchFactory.LaunchParams memory p = launchParams("PRE", 0);
        address predicted = predictToken(creator, p);
        vm.prank(attacker);
        address griefPool = uni.createPool(predicted, address(usdc), 10_000);

        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);
        assertEq(token, predicted);
        assertEq(pool, griefPool, "reused the pre-created pool");
        assertApproxEqRel(spotMcap(token, pool), 5_000e6, 0.03e18, "opened at the platform mcap");
        vm.roll(block.number + 30);
        assertGt(buy(buyer, token, 100e6), 0);
    }

    function test_grief_preInitializedPoolIsRepricedBothDirections() public {
        // 100x too expensive
        _preInitAndLaunch("HI", 500_000e6);
        vm.roll(block.number + 1);
        // 100x too cheap (would let the griefer buy the whole supply for nothing if we accepted it)
        _preInitAndLaunch("LO", 50e6);
    }

    function _preInitAndLaunch(string memory sym, uint256 wrongMcap) internal {
        LaunchFactory.LaunchParams memory p = launchParams(sym, 0);
        address predicted = predictToken(creator, p);
        bool isToken0 = predicted < address(usdc);
        vm.startPrank(attacker);
        address griefPool = uni.createPool(predicted, address(usdc), 10_000);
        IUniswapV3Pool(griefPool).initialize(PriceMath.sqrtPriceX96ForMcap(wrongMcap, isToken0));
        vm.stopPrank();

        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);
        assertEq(pool, griefPool);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(sqrtP, PriceMath.sqrtPriceX96ForMcap(factory.startMcapUsdc(), isToken0), "exactly the target price");
        assertApproxEqRel(spotMcap(token, pool), 5_000e6, 0.03e18);
        vm.roll(block.number + 30);
        uint256 out = buy(buyer, token, 100e6);
        assertGt(out, 0);
        // ~100 USDC into a $5k mcap pool buys roughly 2% of supply — i.e. the honest price, not the griefer's
        assertLt(out, (LaunchToken(token).SUPPLY() * 3) / 100);
        assertGt(out, (LaunchToken(token).SUPPLY() * 1) / 100);
    }

    function test_grief_nextBlockGetsFreshAddress() public {
        LaunchFactory.LaunchParams memory p = launchParams("FRESH", 0);
        address a = predictToken(creator, p);
        vm.roll(block.number + 1);
        vm.setBlockhash(block.number - 1, keccak256("some other block"));
        address b = predictToken(creator, p);
        assertTrue(a != b, "address depends on the previous block hash");
    }

    function test_grief_swapCallbackRejectsStrangers() public {
        vm.expectRevert(LaunchFactory.NotPool.selector);
        factory.uniswapV3SwapCallback(1, 0, "");
    }

    // ------------------------------------------------------------ FeeLocker: impact cap + TWAP floor

    /// @dev A large token backlog (here: tokens pushed to the locker like a tax) is sold in slices that each move
    ///      the price by at most ~1.5%; the rest waits.
    function test_locker_sellsInImpactCappedSlices() public {
        (address token, address pool) = doLaunch(creator, "CAP", 0);
        vm.roll(block.number + 30);
        vm.warp(block.timestamp + 60);
        uint256 got = buy(buyer, token, 3_000e6);
        vm.prank(buyer);
        LaunchToken(token).transfer(address(locker), got / 2); // ~1% of supply lands in the locker
        vm.warp(block.timestamp + 15 minutes);

        uint256 m0 = spotMcap(token, pool);
        locker.distribute(token, 0);
        uint256 m1 = spotMcap(token, pool);
        assertGt(m1 * 10_000, m0 * 9_800, "one slice moves the price < 2%");
        uint256 left = locker.unconvertedTax(token);
        assertGt(left, 0, "remainder deferred");
        assertLt(left, got / 2, "but something was sold");

        // keeps draining on later calls, never more than the cap per call
        for (uint256 i; i < 40 && locker.unconvertedTax(token) > 0; ++i) {
            vm.warp(block.timestamp + 5 minutes);
            uint256 before = spotMcap(token, pool);
            locker.distribute(token, 0);
            assertGt(spotMcap(token, pool) * 10_000, before * 9_800);
        }
        assertEq(locker.unconvertedTax(token), 0, "fully drained over time");
    }

    // ------------------------------------------------------------ Treasury: sliced buyback + TWAP floor

    function _platformToken() internal returns (address token, address pool) {
        (token, pool) = doLaunch(creator, "ARCL", 0);
        vm.roll(block.number + 30);
        vm.prank(owner);
        treasury.configure(token, 10_000);
    }

    function test_treasury_buybackIsSlicedWithCooldown() public {
        (address token, address pool) = _platformToken();
        usdc.mint(address(treasury), 2_000e6);
        vm.warp(block.timestamp + 60);

        uint256 m0 = spotMcap(token, pool);
        treasury.execute(0); // 1520 → eco, 80 → dev, 400 reserved, first slice bought
        assertEq(usdc.balanceOf(eco), 1_520e6 + 1e6); // + the ARCL creation fee
        assertEq(usdc.balanceOf(dev), 80e6);
        uint256 firstSlice = treasury.totalBoughtBack();
        assertGt(firstSlice, 0);
        assertLt(firstSlice, 400e6, "not everything in one go");
        assertEq(treasury.buybackReserve(), 400e6 - firstSlice);
        // first trade ever also crosses the ~2% gap between the opening tick and the position's lower tick
        assertLt(spotMcap(token, pool) * 10_000, m0 * 10_400, "first slice: 2% launch gap + <2% impact");

        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, block.timestamp + 10 minutes));
        treasury.buyback(0);

        uint256 slices = 1;
        while (treasury.buybackReserve() > 0) {
            vm.warp(block.timestamp + 10 minutes);
            uint256 before = spotMcap(token, pool);
            treasury.buyback(0);
            assertLt(spotMcap(token, pool) * 10_000, before * 10_250, "each slice moves the price < 2.5%");
            slices++;
        }
        assertGt(slices, 3, "the 400 USDC took several slices");
        assertEq(treasury.totalBoughtBack(), 400e6);
        assertGt(LaunchToken(token).balanceOf(DEAD), 0);

        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(Treasury.NothingToDo.selector);
        treasury.buyback(0);
    }

    function test_treasury_buybackRefusesManipulatedPrice() public {
        (address token,) = _platformToken();
        usdc.mint(address(treasury), 500e6);
        vm.warp(block.timestamp + 60);
        treasury.execute(0);
        assertGt(treasury.buybackReserve(), 0);
        vm.warp(block.timestamp + 15 minutes); // TWAP at the honest price

        // attacker pumps the price 3x inside its own tx, then calls buyback(0) hoping we buy high
        buy(attacker, token, 8_000e6);
        vm.expectRevert(); // router: Too little received (TWAP floor)
        treasury.buyback(0);

        // unwind; once the price is honest again the slice goes through
        vm.warp(block.timestamp + 15 minutes);
        sell(attacker, token, LaunchToken(token).balanceOf(attacker));
        vm.warp(block.timestamp + 15 minutes);
        uint256 r0 = treasury.buybackReserve();
        treasury.buyback(0);
        assertLt(treasury.buybackReserve(), r0);
    }

    function test_treasury_configureNeedsOurPool() public {
        vm.prank(owner);
        vm.expectRevert(Treasury.NoPool.selector);
        treasury.configure(makeAddr("random"), 10_000);
    }

    // ------------------------------------------------------------ SwapGuard math sanity

    function test_guard_quoteAtSqrtPriceRoundTrips() public pure {
        // price 4 (sqrt 2): 100 token0 → 400 token1, 400 token1 → 100 token0
        uint160 sqrtP = uint160(2 << 96);
        assertEq(SwapGuard.quoteAtSqrtPrice(sqrtP, 100, true), 400);
        assertEq(SwapGuard.quoteAtSqrtPrice(sqrtP, 400, false), 100);
    }
}
