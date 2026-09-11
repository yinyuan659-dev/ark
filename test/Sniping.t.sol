// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {ISwapRouter} from "../src/interfaces/IUniswapV3.sol";

/// @notice Adversarial scenarios: what a sniper / MEV bot can and cannot do against a launch.
///         Each test states the outcome plainly so the results double as documentation.
contract SnipingTest is Base {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant MAX_HOLD = (SUPPLY * 500) / 10_000; // 5%
    uint256 constant MAX_BUY = (SUPPLY * 550) / 10_000; // 5.5%
    /// @dev Our token's custom errors fire inside the pool's `safeTransfer`, which Uniswap V3 wraps as "TF".
    bytes constant BLOCKED_BY_TOKEN = bytes("TF");

    address[] bots;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 10; ++i) {
            address b = makeAddr(string.concat("bot", vm.toString(i)));
            bots.push(b);
            usdc.mint(b, 1_000_000e6);
            vm.prank(b);
            usdc.approve(address(router), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ launch block

    /// @dev Block 0: nobody but the creator can receive tokens from the pool, no matter how many wallets.
    function test_snipe_launchBlockIsCreatorOnlyForEveryWallet() public {
        (address token,) = doLaunch(creator, "SNP", 3e6);
        for (uint256 i; i < bots.length; ++i) {
            vm.expectRevert(BLOCKED_BY_TOKEN); // LaunchBlockOnlyCreator
            buy(bots[i], token, 10e6);
        }
        // creator's first buy already landed inside the launch tx
        assertGt(LaunchToken(token).balanceOf(creator), 0);
    }

    /// @dev The creator's privileged first buy is still capped: they cannot snipe their own launch.
    function test_snipe_creatorCannotOverbuyOwnLaunch() public {
        vm.prank(creator);
        vm.expectRevert(BLOCKED_BY_TOKEN); // ExceedsMaxBuy
        factory.launch(launchParams("OWN", 5_000e6)); // $5k into a $5k pool ≫ 5.5% of supply
        // a sane first buy works and stays under the cap
        (address token,) = doLaunch(creator, "OWN2", 200e6);
        assertLe(LaunchToken(token).balanceOf(creator), MAX_BUY);
    }

    // ------------------------------------------------------------ protection window

    /// @dev One wallet cannot exceed 5.5% per buy or 5% total during the window, however it splits orders.
    function test_snipe_singleWalletCappedDuringWindow() public {
        (address token,) = doLaunch(creator, "CAP", 0);
        vm.roll(block.number + 1);
        address bot = bots[0];

        vm.expectRevert(BLOCKED_BY_TOKEN); // ExceedsMaxBuy
        buy(bot, token, 3_000e6);

        // salami slicing: many small buys still stop at the 5% hold cap
        uint256 bought;
        for (uint256 i; i < 20; ++i) {
            uint256 bal = LaunchToken(token).balanceOf(bot);
            if (bal + 20_000_000e18 > MAX_HOLD) break; // next 20M-token buy would cross 5%
            buy(bot, token, 20e6);
            bought++;
        }
        assertLe(LaunchToken(token).balanceOf(bot), MAX_HOLD);
        vm.expectRevert(BLOCKED_BY_TOKEN); // ExceedsMaxHold
        buy(bot, token, 150e6);
        assertGt(bought, 0);
    }

    /// @dev Known limitation, stated on purpose: the cap is per address. Ten wallets can each take ~5%,
    ///      and transfers are never restricted, so they can consolidate afterwards. The window lowers
    ///      concentration; it does not make a whale impossible. Documented so nobody oversells it.
    function test_snipe_multiWalletCanAggregateButEachIsCapped() public {
        (address token,) = doLaunch(creator, "MW", 0);
        vm.roll(block.number + 1);
        LaunchToken t = LaunchToken(token);

        uint256 total;
        for (uint256 i; i < bots.length; ++i) {
            buy(bots[i], token, 100e6);
            uint256 bal = t.balanceOf(bots[i]);
            assertLe(bal, MAX_HOLD, "each wallet stays under 5%");
            total += bal;
        }
        // 10 × 100 USDC into a $5k pool ≈ 17% of supply spread over ten addresses
        assertGt(total, (SUPPLY * 10) / 100);
        assertLt(total, (SUPPLY * 50) / 100, "still far below what ten uncapped wallets could take");

        // consolidation is possible (transfers are unrestricted) — the cap only guards buys from the pool
        for (uint256 i = 1; i < bots.length; ++i) {
            uint256 bal = t.balanceOf(bots[i]);
            vm.prank(bots[i]);
            t.transfer(bots[0], bal);
        }
        assertGt(t.balanceOf(bots[0]), MAX_HOLD);
    }

    /// @dev Once the window closes, the caps are gone; a normal buyer is not affected by bot activity.
    function test_snipe_windowEndsHumanBuysFreely() public {
        (address token,) = doLaunch(creator, "HUM", 0);
        vm.roll(block.number + 1);
        for (uint256 i; i < 5; ++i) buy(bots[i], token, 100e6);
        vm.roll(block.number + 25);
        uint256 out = buy(buyer, token, 3_000e6);
        assertGt(out, MAX_BUY, "after the window a large buy is allowed");
    }

    /// @dev Selling is never restricted: a bot that got in during the window can dump, but it dumps into the
    ///      same curve everyone else buys from — no hidden exit.
    function test_snipe_sellNeverRestricted() public {
        (address token,) = doLaunch(creator, "SEL", 0);
        vm.roll(block.number + 1);
        buy(bots[0], token, 100e6);
        uint256 got = sell(bots[0], token, LaunchToken(token).balanceOf(bots[0]));
        assertGt(got, 0);
        assertLt(got, 100e6, "round trip inside the window loses the 1% fee twice");
    }

    // ------------------------------------------------------------ MEV on the fee conversion

    /// @dev The keeper quotes the token→USDC conversion first and passes 97% as minOut. A bot that dumps in
    ///      front of the keeper tx makes the conversion fail (deferred), but the USDC payout still happens and
    ///      the bot only paid fees for nothing.
    function test_mev_sandwichAgainstKeeperMinOutFailsSafely() public {
        (address token,) = doLaunch(creator, "MEV", 0);
        vm.roll(block.number + 30);
        uint256 out = buy(buyer, token, 5_000e6);
        sell(buyer, token, out / 2); // token-side fees accrue

        address attacker = bots[0];
        uint256 atkTokens = buy(attacker, token, 3_000e6);

        // keeper dry-run (same as indexer/keeper.ts): learn expected usdcFromToken, take 97%
        uint256 snap = vm.snapshotState();
        (, uint256 expected) = locker.distribute(token, 0);
        vm.revertToState(snap);
        assertGt(expected, 0);
        uint256 minOut = (expected * 97) / 100;

        // attacker front-runs: dumps everything to crash the price
        uint256 atkUsdc = sell(attacker, token, atkTokens);

        uint256 cU = usdc.balanceOf(creator);
        vm.expectEmit(true, false, false, false);
        emit FeeLocker.TokenFeesDeferred(token, 0);
        (uint256 usdcCollected, uint256 usdcFromToken) = locker.distribute(token, minOut);
        assertEq(usdcFromToken, 0, "conversion refused at the manipulated price");
        assertGt(locker.unconvertedTokenFees(token), 0, "tokens kept for later");
        assertEq(usdc.balanceOf(creator) - cU, (usdcCollected * 7_500) / 10_000, "USDC part still paid");

        // attacker back-runs: buys back with the USDC he got — ends with fewer tokens than he started with
        uint256 back = buy(attacker, token, atkUsdc);
        assertLt(back, atkTokens, "sandwich attempt lost money");

        // price is back to normal; the deferred tokens convert on the next runs (sliced by the impact cap)
        (, uint256 f2) = locker.distribute(token, 0);
        assertGt(f2, 0);
        drain(token);
        assertEq(locker.unconvertedTokenFees(token), 0);
    }

    /// @dev distribute is permissionless, so a bot can call it with minOut=0 inside its own sandwich — in ONE
    ///      transaction, no mempool needed. The on-chain TWAP floor makes that pointless: the conversion is
    ///      refused at the manipulated spot price and deferred; once the price is back it converts normally.
    function test_mev_permissionlessMinOutZeroSandwichIsRefusedOnChain() public {
        (address token,) = doLaunch(creator, "MEV0", 0);
        vm.roll(block.number + 30);
        vm.warp(block.timestamp + 60);
        uint256 out = buy(buyer, token, 5_000e6);
        sell(buyer, token, out / 2);
        address attacker = bots[1];
        uint256 atkTokens = buy(attacker, token, 2_000e6);
        vm.warp(block.timestamp + 15 minutes); // let the TWAP settle at the honest price

        uint256 atkUsdc = sell(attacker, token, atkTokens); // front-run (same block): crashes the spot price
        uint256 backlog0 = locker.unconvertedTokenFees(token);

        (uint256 usdcCollected, uint256 fromToken) = locker.distribute(token, 0); // attacker passes minOut = 0
        assertEq(fromToken, 0, "guard refused the sale at the manipulated price");
        assertGt(locker.unconvertedTokenFees(token), backlog0, "tokens kept for later");
        assertGt(usdcCollected, 0, "USDC part still distributed");

        buy(attacker, token, atkUsdc); // back-run finds nothing to profit from
        vm.warp(block.timestamp + 15 minutes);
        (, uint256 f2) = locker.distribute(token, 0);
        assertGt(f2, 0, "converts once the price is honest again");
    }

    /// @dev A user's own buy can be sandwiched on any AMM; that is why the frontend sets amountOutMinimum
    ///      from a fresh quote. Here we show the slippage guard rejecting a manipulated price.
    function test_mev_userSlippageGuardRejectsManipulatedPrice() public {
        (address token,) = doLaunch(creator, "SLP", 0);
        vm.roll(block.number + 30);
        // honest quote: how much would 500 USDC buy right now
        uint256 snap = vm.snapshotState();
        uint256 quoted = buy(buyer, token, 500e6);
        vm.revertToState(snap);

        // attacker front-runs with a big buy
        buy(bots[2], token, 5_000e6);

        // user's tx demands ≥99% of the quoted amount → reverts instead of overpaying
        vm.prank(buyer);
        vm.expectRevert(); // "Too little received"
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: token,
                fee: 10_000,
                recipient: buyer,
                deadline: block.timestamp,
                amountIn: 500e6,
                amountOutMinimum: (quoted * 99) / 100,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
