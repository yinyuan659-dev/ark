// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {SimpleDescriptor} from "../src/periphery/SimpleDescriptor.sol";
import {Treasury} from "../src/Treasury.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {IUniswapV3Factory, INonfungiblePositionManager, ISwapRouter, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

abstract contract Base is Test {
    MockUSDC usdc;
    IUniswapV3Factory uni;
    INonfungiblePositionManager nfpm;
    ISwapRouter router;
    address quoter;

    Treasury treasury;
    FeeLocker locker;
    LaunchFactory factory;

    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address eco = makeAddr("eco");
    address dev = makeAddr("dev");

    function setUp() public virtual {
        usdc = new MockUSDC();

        // Official Uniswap V3 bytecode (v3-core 1.0.1 / v3-periphery 1.4.4).
        uni = IUniswapV3Factory(deployCode("vendor/uniswap-v3/UniswapV3Factory.json"));
        address descriptor = address(new SimpleDescriptor());
        nfpm = INonfungiblePositionManager(
            deployCode("vendor/uniswap-v3/NonfungiblePositionManager.json", abi.encode(address(uni), address(usdc), descriptor))
        );
        router = ISwapRouter(deployCode("vendor/uniswap-v3/SwapRouter.json", abi.encode(address(uni), address(usdc))));
        quoter = deployCode("vendor/uniswap-v3/QuoterV2.json", abi.encode(address(uni), address(usdc)));

        treasury = new Treasury(address(usdc), address(router), address(uni), eco, dev, owner);
        locker = new FeeLocker(address(nfpm), address(router), address(treasury), owner);
        factory = new LaunchFactory(
            address(uni), address(nfpm), address(router), address(usdc), address(locker), address(treasury), eco, owner
        );
        vm.prank(owner);
        locker.setFactory(address(factory));

        usdc.mint(creator, 100_000e6);
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(creator);
        usdc.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers

    /// @dev Predict the CREATE2 token address `who` would get for `p` in the current block (mirrors
    ///      LaunchFactory._salt / _deployToken). Used to pick the right orientation and to pre-grief pools.
    function predictToken(address who, LaunchFactory.LaunchParams memory p) internal view returns (address) {
        address[] memory exempt = new address[](3);
        exempt[0] = address(locker);
        exempt[1] = address(nfpm);
        exempt[2] = address(treasury);
        LaunchToken.Init memory init = LaunchToken.Init({
            name: p.name,
            symbol: p.symbol,
            logo: p.logo,
            description: p.description,
            socials: p.socials,
            deployer: who,
            protectionBlocks: factory.protectionBlocks(),
            maxHoldBps: factory.maxHoldBps(),
            maxBuyBps: factory.maxBuyBps(),
            buyTaxBps: p.buyTaxBps,
            sellTaxBps: p.sellTaxBps,
            marketingWallet: p.marketingWallet == address(0) ? who : p.marketingWallet,
            teamWallet: p.teamWallet == address(0) ? who : p.teamWallet,
            marketingBps: p.marketingBps,
            taxSink: address(locker),
            exempt: exempt
        });
        bytes32 salt = keccak256(abi.encodePacked(who, factory.totalLaunches(), blockhash(block.number - 1)));
        bytes32 initHash = keccak256(abi.encodePacked(type(LaunchToken).creationCode, abi.encode(init)));
        return vm.computeCreate2Address(salt, initHash, address(factory));
    }

    function nextTokenAddress(address who, string memory sym) internal view returns (address) {
        return predictToken(who, launchParams(sym, 0));
    }

    function launchParams(string memory sym, uint256 initialBuy)
        internal
        pure
        returns (LaunchFactory.LaunchParams memory p)
    {
        p = LaunchFactory.LaunchParams({
            name: string.concat("Token ", sym),
            symbol: sym,
            logo: "ipfs://logo",
            description: "test token",
            socials: LaunchToken.Socials({website: "", twitter: "https://x.com/t", telegram: "", discord: "", farcaster: ""}),
            payout: address(0),
            buyTaxBps: 0,
            sellTaxBps: 0,
            marketingWallet: address(0),
            teamWallet: address(0),
            marketingBps: 0,
            initialBuyUsdc: initialBuy,
            minTokensOut: 0
        });
    }

    address marketing = makeAddr("marketing");
    address team = makeAddr("team");

    /// @dev Tax-mode launch with explicit marketing / team wallets and split.
    function doLaunchTaxed(address who, string memory sym, uint16 buyTax, uint16 sellTax, uint16 marketingBps)
        internal
        returns (address token, address pool)
    {
        LaunchFactory.LaunchParams memory p = launchParams(sym, 0);
        p.buyTaxBps = buyTax;
        p.sellTaxBps = sellTax;
        p.marketingWallet = marketing;
        p.teamWallet = team;
        p.marketingBps = marketingBps;
        vm.prank(who);
        (token, pool,) = factory.launch(p);
    }

    function doLaunch(address who, string memory sym, uint256 initialBuy) internal returns (address token, address pool) {
        LaunchFactory.LaunchParams memory p = launchParams(sym, initialBuy);
        vm.prank(who);
        (token, pool,) = factory.launch(p);
    }

    /// @dev Admin helper: change only the opening market cap, keep the other params at their defaults.
    function setStartMcap(uint256 mcapUsdc) internal {
        uint256 thr = factory.graduationThreshold();
        uint256 prot = factory.protectionBlocks();
        uint16 hold = factory.maxHoldBps();
        uint16 buyCap = factory.maxBuyBps();
        vm.prank(owner);
        factory.setLaunchParams(thr, prot, hold, buyCap, mcapUsdc);
    }

    function buy(address who, address token, uint256 usdcIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: token,
                fee: 10_000,
                recipient: who,
                deadline: block.timestamp,
                amountIn: usdcIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function sell(address who, address token, uint256 tokensIn) internal returns (uint256 out) {
        vm.startPrank(who);
        LaunchToken(token).approve(address(router), tokensIn);
        out = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(usdc),
                fee: 10_000,
                recipient: who,
                deadline: block.timestamp,
                amountIn: tokensIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    /// @dev Conversions are sliced (impact cap): call distribute repeatedly, 5 minutes apart, until both
    ///      token backlogs are empty. Returns the number of calls it took.
    function drain(address token) internal returns (uint256 calls) {
        for (; calls < 100; ++calls) {
            locker.distribute(token, 0);
            if (locker.unconvertedTokenFees(token) == 0 && locker.unconvertedTax(token) == 0) return calls + 1;
            vm.warp(block.timestamp + 5 minutes);
        }
        revert("drain: not converged");
    }

    function spotMcap(address token, address pool) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        return PriceMath.mcapFromSqrtPriceX96(sqrtP, token < address(usdc));
    }
}
