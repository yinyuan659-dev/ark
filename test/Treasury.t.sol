// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {Treasury} from "../src/Treasury.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// Weekly settlement of the protocol share (25% of the 1% pool fee): 76% → eco reserve (multisig), 4% → dev team,
/// 20% → buy the platform token and burn it. In trade terms that is 0.19% / 0.01% / 0.05%, plus the creator's 0.75%.
/// Both payout addresses are fixed in the constructor (`eco`, `dev` in Base); the platform token is write-once.
contract TreasuryTest is Base {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function _fund(uint256 amt) internal {
        usdc.mint(address(treasury), amt);
    }

    function _launchPlatformToken() internal returns (address token) {
        (token,) = doLaunch(creator, "ARCL", 0);
        vm.roll(block.number + 30);
    }

    function test_treasury_splitIsImmutableConstants() public view {
        assertEq(treasury.ECO_BPS(), 7_600);
        assertEq(treasury.BUYBACK_BPS(), 2_000);
        assertEq(treasury.DEV_BPS(), 400);
        assertEq(treasury.ECO_BPS() + treasury.BUYBACK_BPS() + treasury.DEV_BPS(), 10_000, "splits the whole share");
        assertEq(treasury.INTERVAL(), 7 days);
        // of the 1% pool fee: 75 creator / 19 eco / 5 buyback / 1 dev
        assertEq((25 * uint256(treasury.ECO_BPS())) / 10_000, 19);
        assertEq((25 * uint256(treasury.BUYBACK_BPS())) / 10_000, 5);
        assertEq((25 * uint256(treasury.DEV_BPS())) / 10_000, 1);
    }

    function test_treasury_addressesFixedAtDeploy() public {
        assertEq(treasury.ecoFund(), eco);
        assertEq(treasury.devFund(), dev);
        assertEq(factory.feeRecipient(), eco, "creation fees go to the same multisig");
        assertEq(locker.treasury(), address(treasury));
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), address(uni), address(0), dev, owner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), address(uni), eco, address(0), owner);
    }

    function test_treasury_platformTokenIsWriteOnce() public {
        address arcl = _launchPlatformToken();
        vm.prank(owner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.configure(address(0), 10_000);

        vm.prank(owner);
        treasury.configure(arcl, 10_000);
        assertEq(treasury.platformToken(), arcl);

        vm.prank(owner);
        vm.expectRevert(Treasury.AlreadyConfigured.selector);
        treasury.configure(makeAddr("other"), 10_000);

        vm.prank(creator);
        vm.expectRevert();
        treasury.configure(makeAddr("other"), 10_000);
    }

    function test_treasury_beforePlatformToken_paysEcoDevAndReservesBuyback() public {
        _fund(100e6);

        treasury.execute(0);
        assertEq(usdc.balanceOf(eco), 76e6, "76% to the multisig");
        assertEq(usdc.balanceOf(dev), 4e6, "4% to the dev team");
        assertEq(treasury.buybackReserve(), 20e6, "20% parked as reserve");
        assertEq(usdc.balanceOf(address(treasury)), 20e6);
        assertEq(treasury.pendingRevenue(), 0, "reserve is not counted as new revenue");
        assertEq(treasury.totalToEco(), 76e6);
        assertEq(treasury.totalToDev(), 4e6);
    }

    function test_treasury_weeklyCadenceEnforced() public {
        _fund(10e6);
        treasury.execute(0);

        _fund(10e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, block.timestamp + 7 days));
        treasury.execute(0);

        vm.warp(block.timestamp + 7 days);
        treasury.execute(0);
        assertEq(usdc.balanceOf(eco), 15.2e6);
        assertEq(usdc.balanceOf(dev), 0.8e6);
    }

    function test_treasury_nothingToDoReverts() public {
        vm.expectRevert(Treasury.NothingToDo.selector);
        treasury.execute(0);
    }

    function test_treasury_afterPlatformToken_buysAndBurnsIncludingReserve() public {
        _fund(100e6);
        treasury.execute(0); // eco 76, dev 4, reserve = 20

        address arcl = _launchPlatformToken(); // its 1 USDC creation fee goes straight to `eco`, not here
        vm.prank(owner);
        treasury.configure(arcl, 10_000);

        vm.warp(block.timestamp + 7 days);
        _fund(50e6); // new revenue this cycle: 50 → 38 eco, 2 dev, 10 buyback (+20 reserve = 30)
        uint256 deadBefore = LaunchToken(arcl).balanceOf(DEAD);
        treasury.execute(0);

        assertEq(usdc.balanceOf(eco), 76e6 + 38e6 + 1e6, "eco gets 76% of each cycle + the creation fee");
        assertEq(usdc.balanceOf(dev), 4e6 + 2e6, "dev gets 4% of each cycle");
        assertEq(treasury.buybackReserve(), 0, "reserve spent (30 USDC fits in one slice at a $5k pool)");
        assertEq(treasury.totalBoughtBack(), 30e6, "reserve + this week's 20%");
        assertGt(LaunchToken(arcl).balanceOf(DEAD) - deadBefore, 0, "tokens landed in the burn address");
        assertEq(treasury.totalBurned(), LaunchToken(arcl).balanceOf(DEAD) - deadBefore);
        assertEq(usdc.balanceOf(address(treasury)), 0, "treasury fully settled");
    }

    function test_treasury_slippageGuardReverts() public {
        address arcl = _launchPlatformToken();
        vm.prank(owner);
        treasury.configure(arcl, 10_000);
        _fund(100e6);
        vm.expectRevert(); // router: Too little received
        treasury.execute(type(uint256).max);
    }

    function test_treasury_burnAddressIsDead() public view {
        assertEq(treasury.BURN_ADDRESS(), DEAD);
    }
}
