// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {ISwapRouter, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

/// Live smoke test against the deployed testnet stack.
///   STEP=launch                 deploy a token with a first buy
///   STEP=trade  TOKEN=0x..      buy then sell half
///   STEP=fees   TOKEN=0x..      distribute fees
contract Smoke is Script {
    uint256 pk;
    address me;
    LaunchFactory factory;
    FeeLocker locker;
    ISwapRouter router;
    address usdc;
    address treasury;

    function setUp() public {
        pk = vm.envUint("PRIVATE_KEY");
        me = vm.addr(pk);
        string memory dep = vm.readFile("deployments/arc-testnet.json");
        factory = LaunchFactory(vm.parseJsonAddress(dep, ".launchFactory"));
        locker = FeeLocker(vm.parseJsonAddress(dep, ".feeLocker"));
        router = ISwapRouter(vm.parseJsonAddress(dep, ".swapRouter"));
        usdc = vm.parseJsonAddress(dep, ".usdc");
        treasury = vm.parseJsonAddress(dep, ".treasury");
    }

    function run() external {
        console2.log("me", me);
        console2.log("usdc balance", IERC20(usdc).balanceOf(me));
        bytes32 step = keccak256(bytes(vm.envOr("STEP", string("launch"))));
        if (step == keccak256("launch")) _launch();
        else if (step == keccak256("trade")) _trade(vm.envAddress("TOKEN"));
        else if (step == keccak256("fees")) _fees(vm.envAddress("TOKEN"));
    }

    function _params(uint256 firstBuy) internal view returns (LaunchFactory.LaunchParams memory p) {
        p = LaunchFactory.LaunchParams({
            name: vm.envOr("NAME", string("Arc Cat")),
            symbol: vm.envOr("SYMBOL", string("ACAT")),
            logo: "https://arcaaaa.com/brand/logo-navy.png",
            description: "First cat on Arc. Smoke test token.",
            socials: LaunchToken.Socials({website: "https://arcaaaa.com", twitter: "https://x.com/arclaunch_", telegram: "https://t.me/ArcLaunchCommunity", discord: "", farcaster: ""}),
            payout: address(0),
            buyTaxBps: 0,
            sellTaxBps: 0,
            marketingWallet: address(0),
            teamWallet: address(0),
            marketingBps: 0,
            initialBuyUsdc: firstBuy,
            minTokensOut: 0
        });
    }

    function _launch() internal {
        uint256 firstBuy = vm.envOr("FIRST_BUY", uint256(3e6));
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        bool isToken0 = predicted < usdc;
        console2.log("platform start mcap usdc6", factory.startMcapUsdc());
        LaunchFactory.LaunchParams memory p = _params(firstBuy);
        uint256 need = factory.creationFee() + firstBuy;

        vm.startBroadcast(pk);
        IERC20(usdc).approve(address(factory), need);
        (address token, address pool, uint256 posId) = factory.launch(p);
        vm.stopBroadcast();

        console2.log("TOKEN", token);
        console2.log("POOL ", pool);
        console2.log("POS  ", posId);
        console2.log("isToken0", isToken0);
        console2.log("predicted ok", token == predicted);
        console2.log("creator tokens", IERC20(token).balanceOf(me));
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        console2.log("spot mcap usdc6", PriceMath.mcapFromSqrtPriceX96(sqrtP, isToken0));
    }

    function _trade(address token) internal {
        uint256 buyUsdc = vm.envOr("BUY_USDC", uint256(2e6));
        vm.startBroadcast(pk);
        IERC20(usdc).approve(address(router), buyUsdc);
        uint256 out = _swap(usdc, token, buyUsdc);
        IERC20(token).approve(address(router), out / 2);
        uint256 back = _swap(token, usdc, out / 2);
        vm.stopBroadcast();
        console2.log("bought tokens", out);
        console2.log("sold half for usdc", back);
        (uint256 paired, uint256 threshold, bool grad) = factory.graduationStatus(token);
        console2.log("paired usdc", paired);
        console2.log("threshold", threshold);
        console2.log("graduated", grad);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        return router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 10_000,
                recipient: me,
                deadline: block.timestamp + 600,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _fees(address token) internal {
        (uint256 tOwed, uint256 qOwed) = locker.pendingOwed(token);
        console2.log("owed token", tOwed);
        console2.log("owed usdc", qOwed);
        uint256 meBefore = IERC20(usdc).balanceOf(me);
        uint256 trBefore = IERC20(usdc).balanceOf(treasury);
        vm.startBroadcast(pk);
        (uint256 q, uint256 fromToken) = locker.distribute(token, 0);
        vm.stopBroadcast();
        console2.log("collected usdc", q);
        console2.log("usdc from token-side fees", fromToken);
        console2.log("creator +usdc", IERC20(usdc).balanceOf(me) - meBefore);
        console2.log("treasury +usdc", IERC20(usdc).balanceOf(treasury) - trBefore);
    }
}
