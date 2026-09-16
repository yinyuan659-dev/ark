// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {Treasury} from "../src/Treasury.sol";

/// Weekly settlement of the protocol share (25% of the 1% pool fee): 76% → eco reserve (multisig), 20% → buyback
/// fund (multisig, burns done by hand there), 4% → dev team. In trade terms that is 0.19% / 0.05% / 0.01%, plus the
/// creator's 0.75%. All three payout addresses are fixed in the constructor (`eco`, `buybackFund`, `dev` in Base).
contract TreasuryTest is Base {
    function _fund(uint256 amt) internal {
        usdc.mint(address(treasury), amt);
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
        assertEq(treasury.buybackFund(), buybackFund);
        assertEq(treasury.devFund(), dev);
        assertEq(factory.feeRecipient(), eco, "creation fees go to the same multisig");
        assertEq(locker.treasury(), address(treasury));
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), address(0), buybackFund, dev, owner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), eco, address(0), dev, owner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), eco, buybackFund, address(0), owner);
    }

    function test_treasury_executePaysAllThree() public {
        _fund(100e6);

        treasury.execute();
        assertEq(usdc.balanceOf(eco), 76e6, "76% to the eco multisig");
        assertEq(usdc.balanceOf(buybackFund), 20e6, "20% to the buyback multisig");
        assertEq(usdc.balanceOf(dev), 4e6, "4% to the dev team");
        assertEq(usdc.balanceOf(address(treasury)), 0, "fully settled");
        assertEq(treasury.pendingRevenue(), 0);
        assertEq(treasury.totalToEco(), 76e6);
        assertEq(treasury.totalToBuyback(), 20e6);
        assertEq(treasury.totalToDev(), 4e6);
    }

    function test_treasury_anyoneCanExecute() public {
        _fund(10e6);
        vm.prank(buyer);
        treasury.execute();
        assertEq(usdc.balanceOf(buybackFund), 2e6);
    }

    function test_treasury_weeklyCadenceEnforced() public {
        _fund(10e6);
        treasury.execute();

        _fund(10e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, block.timestamp + 7 days));
        treasury.execute();

        vm.warp(block.timestamp + 7 days);
        treasury.execute();
        assertEq(usdc.balanceOf(eco), 15.2e6);
        assertEq(usdc.balanceOf(buybackFund), 4e6);
        assertEq(usdc.balanceOf(dev), 0.8e6);
    }

    function test_treasury_nothingToDoReverts() public {
        vm.expectRevert(Treasury.NothingToDo.selector);
        treasury.execute();
    }

    function test_treasury_roundingDustCarriesOver() public {
        _fund(33); // 76% = 25, 20% = 6, 4% = 1 → 32 paid, 1 left
        treasury.execute();
        assertEq(usdc.balanceOf(eco), 25);
        assertEq(usdc.balanceOf(buybackFund), 6);
        assertEq(usdc.balanceOf(dev), 1);
        assertEq(usdc.balanceOf(address(treasury)), 1, "dust waits for the next cycle");
    }
}
