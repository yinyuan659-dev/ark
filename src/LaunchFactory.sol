// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {FeeLocker} from "./FeeLocker.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {SwapGuard} from "./libraries/SwapGuard.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3SwapCallback,
    INonfungiblePositionManager,
    ISwapRouter
} from "./interfaces/IUniswapV3.sol";

/// @title LaunchFactory
/// @notice One transaction: deploy a fixed-supply token, create its USDC pool on Uniswap V3, seed the
///         entire supply as single-sided liquidity, lock the LP position forever, optionally execute the
///         creator's first buy. No bonding curve, no migration: the pool created here is the market.
/// @dev Fair launch: every token opens at the same market cap (`startMcapUsdc`, admin-set, applies to
///      new launches only). The creator cannot choose the opening price.
///
///      Griefing resistance: the token address is derived with CREATE2 from a salt that includes the previous
///      block hash, so nobody can pre-create the Uniswap pool for a future launch; and if a pool for the token
///      already exists (same-block front-run) the launch still succeeds — an empty pool is re-priced with a
///      zero-liquidity swap, a pool that somehow holds liquidity makes the launch revert (`PoolTampered`) and
///      the next attempt gets a fresh address.
contract LaunchFactory is Ownable, ReentrancyGuard, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- immutables
    uint24 public constant POOL_FEE = 10_000; // 1%
    int24 public constant MIN_TICK = -887_272;
    int24 public constant MAX_TICK = 887_272;
    /// @dev Creator share of swap fees, snapshotted into each lock. Immutable by design.
    uint16 public constant CREATOR_SHARE_BPS = 7_500;

    IUniswapV3Factory public immutable uniFactory;
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter public immutable router;
    address public immutable usdc;
    FeeLocker public immutable locker;
    address public immutable treasury;

    // ---------------------------------------------------------------- fixed economics
    /// @dev Creation fee, 1 USDC, charged to every launch. Constant: no switch, no waiver list, no setter.
    uint256 public constant creationFee = 1e6;
    /// @dev Cap for creator-set buy / sell taxes (each). Constant. 1000 = 10%.
    uint16 public constant maxTaxBps = 1_000;
    /// @dev Where creation fees are sent (the ecosystem multisig). Fixed at deployment.
    address public immutable feeRecipient;

    // ---------------------------------------------------------------- launch params (owner-tunable, new launches only)
    // Every one of these is bounded so that even a compromised owner key can only make future launches less
    // attractive, never break trading or touch anyone's money. See setLaunchParams.
    uint256 public graduationThreshold = 10_000e6; // USDC in pool
    uint256 public protectionBlocks = 20; // ~10s on Arc
    uint16 public maxHoldBps = 500; // 5%
    uint16 public maxBuyBps = 550; // 5.5%
    /// @dev Opening market cap for every new launch, in USDC (6 decimals).
    uint256 public startMcapUsdc = 5_000e6;
    uint256 public constant MIN_START_MCAP = 500e6;
    uint256 public constant MAX_START_MCAP = 10_000_000e6;
    uint256 public constant MIN_GRADUATION = 1_000e6;
    /// @dev Anti-snipe window can never exceed ~1 hour of Arc blocks, so caps always lift.
    uint256 public constant MAX_PROTECTION_BLOCKS = 7_200;
    /// @dev Caps can never be set so low that a launch (or its creator's first buy) becomes untradeable.
    uint16 public constant MIN_CAP_BPS = 100; // 1%

    // ---------------------------------------------------------------- state
    struct Launch {
        address token;
        address deployer;
        address pool;
        uint256 positionId;
        bool isToken0;
        uint256 launchBlock;
        uint256 restrictionsEndBlock;
        uint256 graduationThreshold;
        uint256 initialBuyUsdc;
        bool graduated;
        bool exists;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string logo;
        string description;
        LaunchToken.Socials socials;
        address payout; // optional fee wallet for the creator share; address(0) = msg.sender
        // tax mode (0/0 = standard token). Fixed forever once launched. The tax is sold for USDC by the
        // FeeLocker and split `marketingBps` / rest between the two wallets (same for buys and sells).
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        address marketingWallet; // address(0) = msg.sender
        address teamWallet; // address(0) = msg.sender
        uint16 marketingBps; // share of the tax to marketing; 10000 − marketingBps to team
        uint256 initialBuyUsdc; // optional first buy, pulled from msg.sender
        uint256 minTokensOut; // slippage guard for the first buy
    }

    mapping(address => Launch) public launches;
    address[] public allTokens;

    event TokenLaunched(
        address indexed token,
        address indexed deployer,
        address indexed pool,
        uint256 positionId,
        bool isToken0,
        uint256 restrictionsEndBlock,
        uint256 graduationThreshold,
        uint256 initialBuyUsdc,
        uint256 creationFeePaid
    );
    event Graduated(address indexed token, uint256 pairedUsdc, uint256 threshold);
    /// @dev Emitted for tax-mode launches only, right after TokenLaunched.
    event TaxConfigured(
        address indexed token, uint16 buyTaxBps, uint16 sellTaxBps, address marketingWallet, address teamWallet, uint16 marketingBps
    );
    event ParamsUpdated();

    error StartMcapOutOfRange(uint256 mcap);
    error ParamOutOfRange();
    error TaxOutOfRange();
    error ZeroAddress();
    error NoLiquidity();
    error PoolTampered();
    error NotPool();
    error UnknownToken();
    error AlreadyGraduated();
    error NotGraduated();

    constructor(
        address uniFactory_,
        address positionManager_,
        address router_,
        address usdc_,
        address locker_,
        address treasury_,
        address feeRecipient_,
        address owner_
    ) Ownable(owner_) {
        if (
            uniFactory_ == address(0) || positionManager_ == address(0) || router_ == address(0) || usdc_ == address(0)
                || locker_ == address(0) || treasury_ == address(0) || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        uniFactory = IUniswapV3Factory(uniFactory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        router = ISwapRouter(router_);
        usdc = usdc_;
        locker = FeeLocker(locker_);
        treasury = treasury_;
        feeRecipient = feeRecipient_;
    }

    // ---------------------------------------------------------------- admin (affects new launches only)

    /// @notice The only tunable knobs. Bounded on purpose: a hostile owner can at worst make new launches open at
    ///         an odd market cap or keep the anti-snipe caps for an hour — never block trading of an existing token,
    ///         never move funds. Existing tokens snapshot these values at launch and are unaffected.
    function setLaunchParams(
        uint256 graduationThreshold_,
        uint256 protectionBlocks_,
        uint16 maxHoldBps_,
        uint16 maxBuyBps_,
        uint256 startMcapUsdc_
    ) external onlyOwner {
        if (maxHoldBps_ < MIN_CAP_BPS || maxHoldBps_ > 10_000 || maxBuyBps_ < MIN_CAP_BPS || maxBuyBps_ > 10_000) {
            revert ParamOutOfRange();
        }
        if (protectionBlocks_ > MAX_PROTECTION_BLOCKS || graduationThreshold_ < MIN_GRADUATION) revert ParamOutOfRange();
        if (startMcapUsdc_ < MIN_START_MCAP || startMcapUsdc_ > MAX_START_MCAP) revert StartMcapOutOfRange(startMcapUsdc_);
        graduationThreshold = graduationThreshold_;
        protectionBlocks = protectionBlocks_;
        maxHoldBps = maxHoldBps_;
        maxBuyBps = maxBuyBps_;
        startMcapUsdc = startMcapUsdc_;
        emit ParamsUpdated();
    }

    // ---------------------------------------------------------------- launch

    function launch(LaunchParams calldata p) external nonReentrant returns (address token, address pool, uint256 positionId) {
        if (p.buyTaxBps > maxTaxBps || p.sellTaxBps > maxTaxBps || p.marketingBps > 10_000) revert TaxOutOfRange();

        // 1) creation fee (constant 1 USDC) → fee recipient (ecosystem multisig)
        uint256 fee = creationFee;
        IERC20(usdc).safeTransferFrom(msg.sender, feeRecipient, fee);

        // 2) token (entire supply minted to this factory)
        token = _deployToken(p);
        bool isToken0 = token < usdc;

        // 3) pool at the platform-wide opening market cap (same for every launch)
        pool = _preparePool(token, isToken0);
        LaunchToken(token).setPool(pool);

        // 4) + 5) single-sided range on the token side of the price, minted straight into the locker
        positionId = _mintLocked(token, pool, isToken0);
        locker.register(token, usdc, pool, positionId, msg.sender, p.payout == address(0) ? msg.sender : p.payout, CREATOR_SHARE_BPS);

        // 6) optional first buy, executed inside the launch block (only the deployer may receive here)
        if (p.initialBuyUsdc > 0) _initialBuy(token, p.initialBuyUsdc, p.minTokensOut);

        uint256 endBlock = LaunchToken(token).restrictionsEndBlock();
        launches[token] = Launch({
            token: token,
            deployer: msg.sender,
            pool: pool,
            positionId: positionId,
            isToken0: isToken0,
            launchBlock: block.number,
            restrictionsEndBlock: endBlock,
            graduationThreshold: graduationThreshold,
            initialBuyUsdc: p.initialBuyUsdc,
            graduated: false,
            exists: true
        });
        allTokens.push(token);

        emit TokenLaunched(token, msg.sender, pool, positionId, isToken0, endBlock, graduationThreshold, p.initialBuyUsdc, fee);
        if (p.buyTaxBps > 0 || p.sellTaxBps > 0) {
            emit TaxConfigured(token, p.buyTaxBps, p.sellTaxBps, _orSender(p.marketingWallet), _orSender(p.teamWallet), p.marketingBps);
        }
    }

    function _orSender(address a) internal view returns (address) {
        return a == address(0) ? msg.sender : a;
    }

    /// @dev CREATE2 salt: unknowable before the previous block is sealed, so a future token's pool cannot be
    ///      pre-created; unique per (creator, launch count) inside a block.
    function _salt() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, allTokens.length, blockhash(block.number - 1)));
    }

    /// @dev Returns a pool for (token, USDC, 1%) priced at the opening market cap, whether or not one exists.
    function _preparePool(address token, bool isToken0) internal returns (address pool) {
        uint160 target = PriceMath.sqrtPriceX96ForMcap(startMcapUsdc, isToken0);
        pool = uniFactory.getPool(token, usdc, POOL_FEE);
        if (pool == address(0)) {
            pool = uniFactory.createPool(token, usdc, POOL_FEE);
            IUniswapV3Pool(pool).initialize(target);
        } else {
            (uint160 current,,,,,,) = IUniswapV3Pool(pool).slot0();
            if (current == 0) IUniswapV3Pool(pool).initialize(target);
            else if (current != target) _repriceEmptyPool(pool, current, target);
        }
        // oracle depth for the TWAP guard used by FeeLocker / Treasury swaps
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(SwapGuard.OBSERVATIONS);
    }

    /// @dev A pool someone else created and initialized at an arbitrary price. Nobody can have added liquidity
    ///      (the token did not exist yet), so a swap towards `target` crosses no liquidity and moves nothing but
    ///      the price. If anything would be owed, the callback reverts with PoolTampered.
    function _repriceEmptyPool(address pool, uint160 current, uint160 target) internal {
        if (IUniswapV3Pool(pool).liquidity() != 0) revert PoolTampered();
        _repricing = pool;
        IUniswapV3Pool(pool).swap(address(this), target < current, 1, target, "");
        _repricing = address(0);
        (uint160 after_,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (after_ != target) revert PoolTampered();
    }

    address private _repricing;

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external view {
        if (msg.sender != _repricing || _repricing == address(0)) revert NotPool();
        if (amount0Delta > 0 || amount1Delta > 0) revert PoolTampered();
    }

    function _deployToken(LaunchParams calldata p) internal returns (address) {
        address[] memory exempt = new address[](3);
        exempt[0] = address(locker);
        exempt[1] = address(positionManager);
        exempt[2] = treasury;
        return address(
            new LaunchToken{salt: _salt()}(
                LaunchToken.Init({
                    name: p.name,
                    symbol: p.symbol,
                    logo: p.logo,
                    description: p.description,
                    socials: p.socials,
                    deployer: msg.sender,
                    protectionBlocks: protectionBlocks,
                    maxHoldBps: maxHoldBps,
                    maxBuyBps: maxBuyBps,
                    buyTaxBps: p.buyTaxBps,
                    sellTaxBps: p.sellTaxBps,
                    marketingWallet: _orSender(p.marketingWallet),
                    teamWallet: _orSender(p.teamWallet),
                    marketingBps: p.marketingBps,
                    taxSink: address(locker),
                    exempt: exempt
                })
            )
        );
    }

    /// @dev Range strictly on the token side of the current tick, so the mint is single-sided.
    function _range(address pool, bool isToken0) internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 spacing = IUniswapV3Pool(pool).tickSpacing();
        if (isToken0) {
            tickLower = _floorTick(tick, spacing) + spacing; // first tick strictly above price
            tickUpper = _floorTick(MAX_TICK, spacing);
        } else {
            tickLower = _ceilTick(MIN_TICK, spacing);
            tickUpper = _floorTick(tick, spacing); // last tick at/below price
        }
    }

    function _mintLocked(address token, address pool, bool isToken0) internal returns (uint256 positionId) {
        (int24 tickLower, int24 tickUpper) = _range(pool, isToken0);
        uint256 supply = LaunchToken(token).SUPPLY();
        IERC20(token).forceApprove(address(positionManager), supply);
        uint128 liquidity;
        (positionId, liquidity,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: isToken0 ? token : usdc,
                token1: isToken0 ? usdc : token,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: isToken0 ? supply : 0,
                amount1Desired: isToken0 ? 0 : supply,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
        if (liquidity == 0) revert NoLiquidity();
        // rounding dust the position could not absorb
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(treasury, dust);
    }

    function _initialBuy(address token, uint256 usdcIn, uint256 minOut) internal {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        IERC20(usdc).forceApprove(address(router), usdcIn);
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: usdc,
                tokenOut: token,
                fee: POOL_FEE,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: usdcIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ---------------------------------------------------------------- graduation

    /// @notice USDC currently paired in the pool vs. the threshold snapshotted at launch.
    function graduationStatus(address token) public view returns (uint256 paired, uint256 threshold, bool graduated) {
        Launch memory l = launches[token];
        if (!l.exists) revert UnknownToken();
        paired = IERC20(usdc).balanceOf(l.pool);
        threshold = l.graduationThreshold;
        graduated = l.graduated || paired >= threshold;
    }

    /// @notice Permissionless: persist the graduated flag once the threshold is crossed (emits once).
    function markGraduated(address token) external {
        Launch storage l = launches[token];
        if (!l.exists) revert UnknownToken();
        if (l.graduated) revert AlreadyGraduated();
        uint256 paired = IERC20(usdc).balanceOf(l.pool);
        if (paired < l.graduationThreshold) revert NotGraduated();
        l.graduated = true;
        emit Graduated(token, paired, l.graduationThreshold);
    }

    function totalLaunches() external view returns (uint256) {
        return allTokens.length;
    }

    // ---------------------------------------------------------------- tick helpers

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        return c * spacing;
    }

    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 f = _floorTick(tick, spacing);
        return f == tick ? f : f + spacing;
    }
}
