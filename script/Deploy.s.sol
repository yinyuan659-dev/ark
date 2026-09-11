// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SimpleDescriptor} from "../src/periphery/SimpleDescriptor.sol";
import {Treasury} from "../src/Treasury.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";

/// Deploys our own Uniswap V3 (official bytecode) plus the ArcLaunch contracts.
///   USDC     — native USDC ERC-20 interface on Arc: 0x3600000000000000000000000000000000000000
///   OWNER    — admin (defaults to deployer); transferOwnership to the Safe once mainnet checks pass
///   ECO_FUND — ecosystem multisig (defaults to deployer). IMMUTABLE: receives 76% of protocol revenue (0.19% of
///              every trade) and every creation fee; nobody can change it after deployment → on mainnet the Safe.
///   DEV_FUND — development team wallet, single address. IMMUTABLE: receives 4% of protocol revenue (0.01% of every
///              trade). Defaults to the team's address below (same on testnet and mainnet, per the boss 2026-09-07).
contract Deploy is Script {
    address internal constant DEV_TEAM = 0x14EDF5b1D23FA8A66a533fdd7EBFDe5C87d706d3;

    struct Cfg {
        address deployer;
        address usdc;
        address owner;
        address ecoFund;
        address devFund;
    }

    struct Out {
        address uniFactory;
        address nfpm;
        address router;
        address quoter;
        address treasury;
        address locker;
        address factory;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Cfg memory c;
        c.deployer = vm.addr(pk);
        c.usdc = vm.envOr("USDC", address(0x3600000000000000000000000000000000000000));
        c.owner = vm.envOr("OWNER", c.deployer);
        c.ecoFund = vm.envOr("ECO_FUND", c.deployer);
        c.devFund = vm.envOr("DEV_FUND", DEV_TEAM);

        vm.startBroadcast(pk);
        Out memory o = _deploy(c);
        vm.stopBroadcast();

        _write(c, o, vm.envOr("OUT_FILE", string("deployments/arc-testnet.json")));
    }

    function _deploy(Cfg memory c) internal returns (Out memory o) {
        o.uniFactory = deployCode("vendor/uniswap-v3/UniswapV3Factory.json");
        address descriptor = address(new SimpleDescriptor());
        o.nfpm = deployCode(
            "vendor/uniswap-v3/NonfungiblePositionManager.json", abi.encode(o.uniFactory, c.usdc, descriptor)
        );
        o.router = deployCode("vendor/uniswap-v3/SwapRouter.json", abi.encode(o.uniFactory, c.usdc));
        o.quoter = deployCode("vendor/uniswap-v3/QuoterV2.json", abi.encode(o.uniFactory, c.usdc));

        o.treasury = address(new Treasury(c.usdc, o.router, o.uniFactory, c.ecoFund, c.devFund, c.owner));
        FeeLocker locker = new FeeLocker(o.nfpm, o.router, o.treasury, c.owner);
        o.locker = address(locker);
        o.factory = address(
            new LaunchFactory(o.uniFactory, o.nfpm, o.router, c.usdc, o.locker, o.treasury, c.ecoFund, c.owner)
        );
        // owner == deployer for the testnet run; on mainnet the Safe calls setFactory.
        if (c.owner == c.deployer) locker.setFactory(o.factory);
    }

    function _write(Cfg memory c, Out memory o, string memory outFile) internal {
        string memory j = "d";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", c.deployer);
        vm.serializeAddress(j, "owner", c.owner);
        vm.serializeAddress(j, "ecoFund", c.ecoFund);
        vm.serializeAddress(j, "devFund", c.devFund);
        vm.serializeAddress(j, "usdc", c.usdc);
        vm.serializeAddress(j, "uniswapV3Factory", o.uniFactory);
        vm.serializeAddress(j, "positionManager", o.nfpm);
        vm.serializeAddress(j, "swapRouter", o.router);
        vm.serializeAddress(j, "quoterV2", o.quoter);
        vm.serializeAddress(j, "treasury", o.treasury);
        vm.serializeAddress(j, "feeLocker", o.locker);
        vm.serializeUint(j, "deployBlock", block.number);
        string memory out = vm.serializeAddress(j, "launchFactory", o.factory);
        vm.writeJson(out, outFile);

        console2.log("UniswapV3Factory ", o.uniFactory);
        console2.log("PositionManager  ", o.nfpm);
        console2.log("SwapRouter       ", o.router);
        console2.log("QuoterV2         ", o.quoter);
        console2.log("Treasury         ", o.treasury);
        console2.log("FeeLocker        ", o.locker);
        console2.log("LaunchFactory    ", o.factory);
        console2.log("ecoFund (immutable)", c.ecoFund);
        console2.log("devFund (immutable)", c.devFund);
    }
}
