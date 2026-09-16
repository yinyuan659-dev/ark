// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

contract LaunchTest is Base {
    uint256 constant SUPPLY = 1_000_000_000e18;

    // ------------------------------------------------------------ launch

    function test_launch_createsPoolLocksLpAndChargesFee() public {
        uint256 ecoBefore = usdc.balanceOf(eco);
        (address token, address pool) = doLaunch(creator, "AAA", 0);

        LaunchToken t = LaunchToken(token);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.liquidityPool(), pool);
        assertEq(uni.getPool(token, address(usdc), 10_000), pool);

        (uint256 tokenId,,,,,,, bool exists) = locker.locks(token);
        assertTrue(exists);
        assertEq(nfpm.ownerOf(tokenId), address(locker));

        // whole supply is in the pool (minus dust sent to treasury)
        uint256 inPool = t.balanceOf(pool);
        uint256 dust = t.balanceOf(address(treasury));
        assertEq(inPool + dust, SUPPLY);
        assertLt(dust, 1e18, "dust should be negligible");
        assertEq(t.balanceOf(address(factory)), 0);

        // 1 USDC creation fee went straight to the ecosystem multisig
        assertEq(usdc.balanceOf(eco) - ecoBefore, 1e6);

        // spot mcap ≈ platform opening mcap (within 1 tick ≈ 0.01% + spacing 2%)
        assertApproxEqRel(spotMcap(token, pool), factory.startMcapUsdc(), 0.03e18);
    }

    function test_launch_creationFeeRecipientIsImmutable() public {
        assertEq(factory.feeRecipient(), eco, "fixed at deployment to the multisig");
        uint256 t0 = usdc.balanceOf(address(treasury));
        doLaunch(creator, "FEE", 0);
        assertEq(usdc.balanceOf(eco), 1e6, "fee straight to the multisig");
        assertEq(usdc.balanceOf(address(treasury)), t0, "treasury untouched");
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(
            address(uni), address(nfpm), address(router), address(usdc), address(locker), address(treasury), address(0), owner
        );
    }

    /// @dev The creation fee is a constant: every launch pays exactly 1 USDC, no switch, no waiver list.
    function test_launch_creationFeeIsConstant() public {
        assertEq(factory.creationFee(), 1e6);
        uint256 before = usdc.balanceOf(eco);
        doLaunch(creator, "BBB", 0);
        doLaunch(creator, "CCC", 0);
        assertEq(usdc.balanceOf(eco) - before, 2e6);
        // a wallet without USDC cannot launch at all
        address broke = makeAddr("broke");
        vm.prank(broke);
        usdc.approve(address(factory), type(uint256).max);
        LaunchFactory.LaunchParams memory p = launchParams("NOFEE", 0);
        vm.prank(broke);
        vm.expectRevert();
        factory.launch(p);
    }

    /// @dev v2.11 (boss 9.16): launch params are constants — no setter exists, the owner has no function left on
    ///      the factory, and the values are exactly what the docs promise.
    function test_launch_paramsAreConstants() public {
        assertEq(factory.graduationThreshold(), 10_000e6);
        assertEq(factory.protectionBlocks(), 20);
        assertEq(factory.maxHoldBps(), 500);
        assertEq(factory.maxBuyBps(), 550);
        assertEq(factory.startMcapUsdc(), 5_000e6);
        // the old setter selector is gone: the call hits no function and reverts
        vm.prank(owner);
        (bool ok,) = address(factory).call(
            abi.encodeWithSignature("setLaunchParams(uint256,uint256,uint16,uint16,uint256)", 1_000e6, 20, 500, 550, 5_000e6)
        );
        assertFalse(ok);
        assertEq(factory.startMcapUsdc(), 5_000e6);
    }

    function test_launch_initialBuyGoesToCreator() public {
        (address token,) = doLaunch(creator, "DDD", 100e6);
        uint256 bal = LaunchToken(token).balanceOf(creator);
        assertGt(bal, 0);
        // 100 USDC into a $5k mcap pool: roughly 2% of supply, under the 5.5% cap
        assertLt(bal, (SUPPLY * 550) / 10_000);
    }

    /// @dev Fair launch: the creator has no price input; every token opens at the same market cap.
    function test_launch_everyTokenOpensAtSameMcap() public {
        uint256 target = factory.startMcapUsdc();
        assertEq(target, 5_000e6);
        for (uint256 i; i < 6; ++i) {
            (address token, address pool) = doLaunch(creator, string.concat("S", vm.toString(i)), 0);
            assertApproxEqRel(spotMcap(token, pool), target, 0.03e18);
        }
    }

    /// @dev Token addresses come from CREATE2 (salt = creator, count, prev blockhash), so orientation flips
    ///      pseudo-randomly. Ensure both work and that the prediction helper matches the factory.
    function test_launch_bothOrientations() public {
        bool seen0;
        bool seen1;
        for (uint256 i; i < 40 && !(seen0 && seen1); ++i) {
            string memory sym = string.concat("T", vm.toString(i));
            address predicted = nextTokenAddress(creator, sym);
            bool isToken0 = predicted < address(usdc);
            (address token, address pool) = doLaunch(creator, sym, 0);
            assertEq(token, predicted, "CREATE2 prediction");
            assertEq(token < address(usdc), isToken0);
            assertApproxEqRel(spotMcap(token, pool), 5_000e6, 0.03e18);
            // buy works in either orientation
            vm.roll(block.number + 30);
            uint256 out = buy(buyer, token, 50e6);
            assertGt(out, 0);
            if (isToken0) seen0 = true;
            else seen1 = true;
        }
        assertTrue(seen0 && seen1, "need both orientations covered");
    }

    // ------------------------------------------------------------ trading & price

    function test_trade_buyRaisesPriceSellLowers() public {
        (address token, address pool) = doLaunch(creator, "FFF", 0);
        vm.roll(block.number + 30);
        uint256 m0 = spotMcap(token, pool);
        uint256 out = buy(buyer, token, 500e6);
        uint256 m1 = spotMcap(token, pool);
        assertGt(m1, m0);
        sell(buyer, token, out / 2);
        uint256 m2 = spotMcap(token, pool);
        assertLt(m2, m1);
        assertGt(m2, m0);
    }

    // ------------------------------------------------------------ launch protection

    function test_protection_launchBlockOnlyCreator() public {
        (address token,) = doLaunch(creator, "GGG", 0);
        // same block: a stranger cannot buy
        vm.expectRevert();
        buy(buyer, token, 10e6);
        // the creator can
        uint256 out = buy(creator, token, 10e6);
        assertGt(out, 0);
    }

    function test_protection_capsDuringWindowThenLifted() public {
        (address token,) = doLaunch(creator, "HHH", 0);
        vm.roll(block.number + 1);
        // 5.5% of supply at $5k mcap ≈ $275+ of USDC; buying $2,000 would exceed maxBuy
        vm.expectRevert();
        buy(buyer, token, 2_000e6);
        // small buys fine
        buy(buyer, token, 100e6);
        // accumulate past 5% hold cap → revert
        vm.expectRevert();
        buy(buyer, token, 400e6);
        // sells are never restricted
        sell(buyer, token, LaunchToken(token).balanceOf(buyer) / 2);
        // after the window everything is allowed
        vm.roll(block.number + 25);
        uint256 out = buy(buyer, token, 5_000e6);
        assertGt(out, (SUPPLY * 550) / 10_000);
    }

    // ------------------------------------------------------------ fees

    /// @dev Creator and protocol receive USDC only; the token-side fee is sold into the pool first.
    function test_fees_distributeSplits75_25_usdcOnly() public {
        (address token,) = doLaunch(creator, "III", 0);
        vm.roll(block.number + 30);
        uint256 out = buy(buyer, token, 1_000e6); // 1% fee = 10 USDC accrues to the position
        sell(buyer, token, out / 2); // token-side fee accrues too

        uint256 cU = usdc.balanceOf(creator);
        uint256 tU = usdc.balanceOf(address(treasury));
        uint256 cT = LaunchToken(token).balanceOf(creator);
        uint256 lockerTokens = LaunchToken(token).balanceOf(address(locker));

        (uint256 usdcCollected, uint256 usdcFromToken) = locker.distribute(token, 0);
        assertApproxEqAbs(usdcCollected, 10e6, 2); // 1% of 1,000 USDC
        assertGt(usdcFromToken, 0, "token-side fee was converted");

        uint256 total = usdcCollected + usdcFromToken;
        uint256 share = (total * 7_500) / 10_000;
        assertEq(usdc.balanceOf(creator) - cU, share);
        assertEq(usdc.balanceOf(address(treasury)) - tU, total - share);

        // nobody received launch tokens, and none are stuck in the locker
        assertEq(LaunchToken(token).balanceOf(creator), cT);
        assertEq(LaunchToken(token).balanceOf(address(locker)), lockerTokens);
        assertEq(locker.unconvertedTokenFees(token), 0);

        // second distribute: no new USDC fees; the only thing left is the 1% pool fee our own conversion
        // swap just generated (a tail ~1% of the previous conversion), and it must not revert
        (uint256 q2, uint256 f2) = locker.distribute(token, 0);
        assertEq(q2, 0);
        assertLt(f2, usdcFromToken / 50);
    }

    /// @dev If the token→USDC swap fails the slippage guard, the tokens are kept and the USDC payout still happens.
    function test_fees_swapFailureDefersTokensButPaysUsdc() public {
        (address token,) = doLaunch(creator, "JJ2", 0);
        vm.roll(block.number + 30);
        uint256 out = buy(buyer, token, 1_000e6);
        sell(buyer, token, out / 2);

        uint256 cU = usdc.balanceOf(creator);
        // absurd minOut → swap reverts inside try/catch
        vm.expectEmit(true, false, false, false);
        emit FeeLocker.TokenFeesDeferred(token, 0);
        (uint256 usdcCollected, uint256 usdcFromToken) = locker.distribute(token, type(uint256).max);
        assertGt(usdcCollected, 0);
        assertEq(usdcFromToken, 0);
        assertGt(locker.unconvertedTokenFees(token), 0);
        // USDC part was still paid 75/25
        assertEq(usdc.balanceOf(creator) - cU, (usdcCollected * 7_500) / 10_000);

        // next run with a sane guard converts the backlog
        uint256 backlog = locker.unconvertedTokenFees(token);
        (, uint256 f2) = locker.distribute(token, 0);
        assertGt(f2, 0);
        assertEq(locker.unconvertedTokenFees(token), 0);
        assertGt(backlog, 0);
    }

    function test_fees_blocklistedCreatorParkedAsClaimable() public {
        (address token,) = doLaunch(creator, "JJJ", 0);
        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);

        usdc.setBlocked(creator, true);
        uint256 tU = usdc.balanceOf(address(treasury));
        (uint256 q, uint256 f) = locker.distribute(token, 0); // must NOT revert
        uint256 share = ((q + f) * 7_500) / 10_000;
        assertEq(locker.claimable(creator, address(usdc)), share);
        assertEq(usdc.balanceOf(address(treasury)) - tU, (q + f) - share, "protocol still paid");

        // once unblocked, creator claims
        usdc.setBlocked(creator, false);
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        locker.claim(address(usdc));
        assertEq(usdc.balanceOf(creator) - before, share);
        assertEq(locker.claimable(creator, address(usdc)), 0);
    }

    // ------------------------------------------------------------ payout address / community takeover

    function test_payout_creatorRotatesInstantly_strangerCannot() public {
        (address token,) = doLaunch(creator, "KKK", 0);
        address newWallet = makeAddr("newWallet");
        vm.prank(creator);
        locker.setPayout(token, newWallet);
        (,,,,, address payout,,) = locker.locks(token);
        assertEq(payout, newWallet);

        vm.prank(buyer);
        vm.expectRevert(FeeLocker.NotCreator.selector);
        locker.setPayout(token, buyer);

        // even the owner cannot use the instant path
        vm.prank(owner);
        vm.expectRevert(FeeLocker.NotCreator.selector);
        locker.setPayout(token, owner);

        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);
        uint256 before = usdc.balanceOf(newWallet);
        locker.distribute(token, 0);
        assertGt(usdc.balanceOf(newWallet) - before, 0);
    }

    function test_payout_creatorCanPickFeeWalletAtLaunch() public {
        address feeWallet = makeAddr("feeWallet");
        LaunchFactory.LaunchParams memory p = launchParams("FEE", 0);
        p.payout = feeWallet;
        vm.prank(creator);
        (address token,,) = factory.launch(p);

        (,,,, address recCreator, address payout,,) = locker.locks(token);
        assertEq(recCreator, creator, "deployer stays the creator of record");
        assertEq(payout, feeWallet, "share goes to the chosen wallet");

        // the fee wallet, not the deployer, now controls rotation
        vm.prank(creator);
        vm.expectRevert(FeeLocker.NotCreator.selector);
        locker.setPayout(token, creator);

        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);
        uint256 before = usdc.balanceOf(feeWallet);
        uint256 creatorBefore = usdc.balanceOf(creator);
        locker.distribute(token, 0);
        assertGt(usdc.balanceOf(feeWallet) - before, 0);
        assertEq(usdc.balanceOf(creator), creatorBefore, "deployer receives nothing");
    }

    /// v2.9: the owner has no path at all to a creator's payout — only the current payout address can rotate it.
    function test_payout_ownerCannotChangeCreatorPayout() public {
        (address token,) = doLaunch(creator, "NOCTO", 0);
        address community = makeAddr("community");

        vm.prank(owner);
        vm.expectRevert(FeeLocker.NotCreator.selector);
        locker.setPayout(token, community);

        vm.prank(buyer);
        vm.expectRevert(FeeLocker.NotCreator.selector);
        locker.setPayout(token, community);

        (,,,,, address payout,,) = locker.locks(token);
        assertEq(payout, creator, "unchanged");

        // the creator can still rotate, and the new wallet takes over control immediately
        address mine = makeAddr("mine");
        vm.prank(creator);
        locker.setPayout(token, mine);
        (,,,,, payout,,) = locker.locks(token);
        assertEq(payout, mine);
        vm.prank(creator);
        vm.expectRevert(FeeLocker.NotCreator.selector);
        locker.setPayout(token, creator);
    }

    function test_locker_positionCanNeverLeave() public {
        (address token,) = doLaunch(creator, "LLL", 0);
        (uint256 tokenId,,,,,,,) = locker.locks(token);
        // no function exists to transfer it; even the owner cannot move it via the NFT contract
        vm.prank(owner);
        vm.expectRevert();
        nfpm.safeTransferFrom(address(locker), owner, tokenId);
        assertEq(nfpm.ownerOf(tokenId), address(locker));
    }

    // ------------------------------------------------------------ graduation

    function test_graduation_flagAndEvent() public {
        (address token, address pool) = doLaunch(creator, "MMM", 0);

        (uint256 paired, uint256 threshold, bool graduated) = factory.graduationStatus(token);
        assertEq(threshold, 10_000e6); // constant since v2.11
        assertEq(paired, 0);
        assertFalse(graduated);
        vm.expectRevert(LaunchFactory.NotGraduated.selector);
        factory.markGraduated(token);

        vm.roll(block.number + 30);
        // after the window there are no caps, so one buyer can push the pool past the threshold
        buy(buyer, token, 12_000e6);
        (paired,, graduated) = factory.graduationStatus(token);
        assertGe(paired, 10_000e6);
        assertTrue(graduated);
        assertEq(usdc.balanceOf(pool), paired);

        vm.expectEmit(true, false, false, false);
        emit LaunchFactory.Graduated(token, 0, 0);
        factory.markGraduated(token);
        vm.expectRevert(LaunchFactory.AlreadyGraduated.selector);
        factory.markGraduated(token);

        // trading continues in the same pool after graduation
        uint256 out = buy(buyer, token, 100e6);
        assertGt(out, 0);
    }

    // ------------------------------------------------------------ price math

    function test_priceMath_roundTrip() public pure {
        uint256[4] memory mcaps = [uint256(1_000e6), 5_000e6, 25_000e6, 1_000_000e6];
        for (uint256 i; i < mcaps.length; ++i) {
            uint160 s0 = PriceMath.sqrtPriceX96ForMcap(mcaps[i], true);
            uint160 s1 = PriceMath.sqrtPriceX96ForMcap(mcaps[i], false);
            assertApproxEqRel(PriceMath.mcapFromSqrtPriceX96(s0, true), mcaps[i], 0.001e18);
            assertApproxEqRel(PriceMath.mcapFromSqrtPriceX96(s1, false), mcaps[i], 0.001e18);
        }
    }
}
