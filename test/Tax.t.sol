// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "./Base.t.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ISwapRouter} from "../src/interfaces/IUniswapV3.sol";

/// Tax mode: creator-set buy/sell tax, fixed at launch, V3-compatible ("tax on top" for sells), proceeds
/// sold for USDC and split between the marketing and team wallets.
contract TaxTest is Base {
    bytes32 constant TAX_DISTRIBUTED = keccak256("TaxDistributed(address,uint256,address,uint256,address,uint256,bool)");

    function _afterWindow() internal {
        vm.roll(block.number + 30);
    }

    // ------------------------------------------------------------ configuration

    function test_tax_paramsAreImmutableAndReadable() public {
        (address token,) = doLaunchTaxed(creator, "TAX", 300, 500, 6_000);
        LaunchToken t = LaunchToken(token);
        assertEq(t.buyTaxBps(), 300);
        assertEq(t.sellTaxBps(), 500);
        assertEq(t.marketingWallet(), marketing);
        assertEq(t.teamWallet(), team);
        assertEq(t.marketingBps(), 6_000);
        assertEq(t.taxSink(), address(locker));
        assertTrue(t.isTaxToken());
        // no setter exists on the token or the factory (compile-time guarantee); the cap is a constant
        assertEq(factory.maxTaxBps(), 1_000);
        assertEq(t.sellTaxBps(), 500);
    }

    function test_tax_walletsDefaultToDeployer() public {
        LaunchFactory.LaunchParams memory p = launchParams("DEF", 0);
        p.buyTaxBps = 200;
        p.marketingBps = 5_000;
        vm.prank(creator);
        (address token,,) = factory.launch(p);
        assertEq(LaunchToken(token).marketingWallet(), creator);
        assertEq(LaunchToken(token).teamWallet(), creator);
    }

    function test_tax_standardTokenHasZeroTax() public {
        (address token,) = doLaunch(creator, "STD", 0);
        assertFalse(LaunchToken(token).isTaxToken());
        _afterWindow();
        uint256 out = buy(buyer, token, 100e6);
        assertEq(LaunchToken(token).balanceOf(buyer), out, "standard token: buyer gets the full pool output");
    }

    function test_tax_capEnforced() public {
        LaunchFactory.LaunchParams memory p = launchParams("CAP", 0);
        p.buyTaxBps = 1_001; // cap is 10%
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.TaxOutOfRange.selector);
        factory.launch(p);

        p.buyTaxBps = 0;
        p.sellTaxBps = 1_001;
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.TaxOutOfRange.selector);
        factory.launch(p);

        p.sellTaxBps = 100;
        p.marketingBps = 10_001;
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.TaxOutOfRange.selector);
        factory.launch(p);

        // exactly at the constant cap is allowed
        p.marketingBps = 0;
        p.sellTaxBps = 1_000;
        vm.prank(creator);
        factory.launch(p);
    }

    // ------------------------------------------------------------ buys

    function test_tax_buyDeductsFromOutputIntoSink() public {
        (address token, address pool) = doLaunchTaxed(creator, "TB", 500, 0, 5_000); // 5% buy
        _afterWindow();
        uint256 poolBefore = LaunchToken(token).balanceOf(pool);
        uint256 out = buy(buyer, token, 1_000e6);

        uint256 tax = (out * 500) / 10_000;
        assertEq(LaunchToken(token).balanceOf(buyer), out - tax, "buyer receives output minus tax");
        assertEq(LaunchToken(token).balanceOf(address(locker)), tax, "tax parked in the sink");
        assertEq(poolBefore - LaunchToken(token).balanceOf(pool), out, "pool paid exactly the swap output");
    }

    // ------------------------------------------------------------ sells (the V3 constraint)

    function test_tax_sellChargesOnTopAndPoolReceivesFullAmount() public {
        (address token, address pool) = doLaunchTaxed(creator, "TS", 0, 800, 5_000); // 8% sell
        _afterWindow();
        uint256 got = buy(buyer, token, 1_000e6); // no buy tax → buyer holds `got`

        uint256 sellAmt = got / 2;
        uint256 poolBefore = LaunchToken(token).balanceOf(pool);
        uint256 usdcOut = sell(buyer, token, sellAmt); // must NOT revert with IIA
        assertGt(usdcOut, 0);

        uint256 tax = (sellAmt * 800) / 10_000;
        assertEq(LaunchToken(token).balanceOf(pool) - poolBefore, sellAmt, "pool received the full amount (V3 check passes)");
        assertEq(LaunchToken(token).balanceOf(buyer), got - sellAmt - tax, "seller paid amount + tax");
        assertEq(LaunchToken(token).balanceOf(address(locker)), tax, "tax landed in the sink");
    }

    function test_tax_sellNeedsBalanceForAmountPlusTax() public {
        (address token,) = doLaunchTaxed(creator, "TS2", 0, 1_000, 5_000); // 10% sell
        _afterWindow();
        uint256 got = buy(buyer, token, 500e6);
        vm.startPrank(buyer);
        LaunchToken(token).approve(address(router), got);
        vm.expectRevert();
        router.exactInputSingle(_sellParams(token, buyer, got)); // whole balance: nothing left for the tax
        vm.stopPrank();
        uint256 maxSell = (got * 10_000) / 11_000; // balance / 1.10
        assertGt(sell(buyer, token, maxSell), 0);
    }

    // ------------------------------------------------------------ exemptions

    function test_tax_lockerSellsFeesWithoutTax_andCollectIsUntaxed() public {
        (address token,) = doLaunchTaxed(creator, "TX", 500, 500, 5_000);
        _afterWindow();
        buy(buyer, token, 2_000e6);
        assertGt(LaunchToken(token).balanceOf(address(locker)), 0);
        // collect (pool → locker) and the conversion sell (locker → pool) are both exempt; the sale is sliced
        drain(token);
        assertEq(LaunchToken(token).balanceOf(address(locker)), 0, "everything converted, nothing taxed on the way");
        assertEq(locker.unconvertedTax(token), 0);
        assertEq(locker.unconvertedTokenFees(token), 0);
    }

    // ------------------------------------------------------------ distribution: tax → marketing / team, fees 75/25

    function test_tax_distributeSplitsTaxToMarketingAndTeam_feesStill75_25() public {
        (address token,) = doLaunchTaxed(creator, "TD", 1_000, 0, 7_000); // 10% buy tax, 70/30 marketing/team
        _afterWindow();
        uint256 out = buy(buyer, token, 1_000e6);
        uint256 taxTokens = (out * 1_000) / 10_000;
        assertEq(LaunchToken(token).balanceOf(address(locker)), taxTokens);

        uint256[4] memory before = [usdc.balanceOf(creator), usdc.balanceOf(address(treasury)), usdc.balanceOf(marketing), usdc.balanceOf(team)];

        vm.recordLogs();
        (uint256 usdcCollected, uint256 usdcFromToken) = locker.distribute(token, 0);
        assertApproxEqAbs(usdcCollected, 10e6, 2); // 1% pool fee on a 1000 USDC buy, USDC side

        (uint256 conv, uint256 toMarketing, uint256 toTeam) = _taxEvent();
        assertGt(conv, 0, "a slice of the tax was converted");
        assertLe(conv, taxTokens);
        assertEq(locker.unconvertedTax(token), taxTokens - conv, "rest waits in the tax backlog");
        assertGt(toMarketing, 0);
        assertEq(toMarketing, ((toMarketing + toTeam) * 7_000) / 10_000, "70% to marketing");
        assertEq(usdc.balanceOf(marketing) - before[2], toMarketing);
        assertEq(usdc.balanceOf(team) - before[3], toTeam);

        uint256 feeTotal = usdcCollected + usdcFromToken;
        uint256 creatorFromFees = (feeTotal * 7_500) / 10_000;
        assertEq(usdc.balanceOf(address(treasury)) - before[1], feeTotal - creatorFromFees, "protocol: 25% of fees, 0 of tax");
        assertEq(usdc.balanceOf(creator) - before[0], creatorFromFees, "creator payout: 75% of fees only; tax went to the tax wallets");
    }

    /// @dev Decode the single TaxDistributed event from the recorded logs; also checks wallets and paid flag.
    function _taxEvent() internal returns (uint256 conv, uint256 toMarketing, uint256 toTeam) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != TAX_DISTRIBUTED) continue;
            (uint256 c, address m, uint256 um, address tm, uint256 ut, bool paid) =
                abi.decode(logs[i].data, (uint256, address, uint256, address, uint256, bool));
            assertEq(m, marketing);
            assertEq(tm, team);
            assertTrue(paid);
            return (c, um, ut);
        }
    }

    function test_tax_blocklistedTaxWalletIsParkedNotBlocking() public {
        // marketing wallet rejects USDC → parked as claimable; team still paid; distribute does not revert
        address badMarketing = makeAddr("blockedMarketing");
        LaunchFactory.LaunchParams memory p = launchParams("BL", 0);
        p.buyTaxBps = 1_000;
        p.marketingWallet = badMarketing;
        p.teamWallet = team;
        p.marketingBps = 5_000;
        vm.prank(creator);
        (address token,,) = factory.launch(p);
        usdc.setBlocked(badMarketing, true);
        _afterWindow();
        buy(buyer, token, 1_000e6);
        uint256 tm0 = usdc.balanceOf(team);
        locker.distribute(token, 0);
        assertGt(usdc.balanceOf(team) - tm0, 0, "team paid");
        assertGt(locker.claimable(badMarketing, address(usdc)), 0, "marketing share parked");
    }

    function test_tax_swapFailureKeepsBucketsSeparate() public {
        (address token,) = doLaunchTaxed(creator, "TF", 1_000, 0, 5_000);
        _afterWindow();
        uint256 out = buy(buyer, token, 1_000e6);
        uint256 taxTokens = (out * 1_000) / 10_000;

        locker.distribute(token, type(uint256).max); // impossible minOut → swap fails → backlog
        assertEq(locker.unconvertedTax(token), taxTokens, "tax backlog");
        assertEq(locker.unconvertedTokenFees(token), 0, "no token-side fees on a pure buy");

        uint256 out2 = buy(buyer, token, 500e6);
        uint256 tax2 = (out2 * 1_000) / 10_000;
        vm.recordLogs();
        locker.distribute(token, 0);
        (uint256 conv,,) = _taxEvent();
        assertGt(conv, 0, "backlog + new tax sold from one bucket");
        assertEq(locker.unconvertedTax(token), taxTokens + tax2 - conv, "remainder of both stays in the tax bucket");
        drain(token);
        assertEq(locker.unconvertedTax(token), 0);
    }

    // ------------------------------------------------------------ protection window still uses gross amounts

    function test_tax_protectionCapsUseGrossAmount() public {
        (address token,) = doLaunchTaxed(creator, "TP", 1_000, 0, 5_000);
        vm.roll(block.number + 1);
        vm.prank(buyer);
        vm.expectRevert(); // pool wraps the custom error as "TF"
        router.exactInputSingle(_buyParams(token, buyer, 500e6)); // ~9% of supply at $5k mcap
    }

    // ------------------------------------------------------------ helpers

    function _sellParams(address token, address who, uint256 amt) internal view returns (ISwapRouter.ExactInputSingleParams memory) {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: token, tokenOut: address(usdc), fee: 10_000, recipient: who, deadline: block.timestamp,
            amountIn: amt, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        });
    }

    function _buyParams(address token, address who, uint256 usdcIn) internal view returns (ISwapRouter.ExactInputSingleParams memory) {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc), tokenOut: token, fee: 10_000, recipient: who, deadline: block.timestamp,
            amountIn: usdcIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        });
    }
}
