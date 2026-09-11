// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {SwapGuard} from "./libraries/SwapGuard.sol";

/// @title Treasury
/// @notice Collects the protocol share of swap fees (0.25% of every trade, i.e. 25% of the 1% pool fee) in USDC
///         and settles it on a fixed weekly cycle. Of that share:
///           - ECO_BPS (76%  = 0.19% of the trade) is transferred to the ecosystem reserve (a multisig);
///           - BUYBACK_BPS (20% = 0.05% of the trade) is earmarked for buying the platform token and sending it to
///             the dead address (Arc forbids transfers to the zero address, so 0x…dEaD is the burn sink);
///           - DEV_BPS (4% = 0.01% of the trade) is transferred to the development team wallet.
///         Together with the creator's 75% that is the whole 1% pool fee: 75 / 19 / 5 / 1.
///         The buyback is executed in guarded slices: each `buyback` call spends at most what moves the pool
///         ~1.5% and never fills below the pool TWAP minus a tolerance (see SwapGuard), with a cooldown between
///         slices. A permissionless swap of the full weekly amount in one go could be sandwiched; sliced this way
///         a sandwich is unprofitable and a manipulated price makes the slice revert instead of filling.
///         Until the platform token is configured the buyback share simply accumulates as a reserve. The split,
///         the cadence and both payout addresses are immutable; the platform token can be set exactly once.
/// @dev `execute` and `buyback` are permissionless; a keeper calls them on schedule. Contracts cannot schedule
///      themselves, so the interval / cooldown are enforced here and the trigger comes from outside.
contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant ECO_BPS = 7_600; // 76% of the protocol share → ecosystem reserve (multisig)
    uint16 public constant BUYBACK_BPS = 2_000; // 20% → buy & burn the platform token
    uint16 public constant DEV_BPS = 400; // 4% → development team
    uint256 public constant INTERVAL = 7 days;
    uint256 public constant BUYBACK_COOLDOWN = 10 minutes;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable usdc;
    ISwapRouter public immutable router;
    IUniswapV3Factory public immutable uniFactory;
    /// @dev The ecosystem multisig. Fixed at deployment; nobody (owner included) can redirect it.
    address public immutable ecoFund;
    /// @dev The development team wallet (single address). Fixed at deployment.
    address public immutable devFund;

    address public platformToken;
    uint24 public platformPoolFee;
    IUniswapV3Pool public platformPool;

    uint256 public lastExecutedAt;
    uint256 public lastBuybackAt;
    /// @dev USDC earmarked for buybacks but not yet spent.
    uint256 public buybackReserve;

    uint256 public totalBoughtBack; // USDC spent on buybacks
    uint256 public totalBurned; // platform tokens burned
    uint256 public totalToEco;
    uint256 public totalToDev;

    event Configured(address platformToken, uint24 poolFee, address pool);
    /// @dev Weekly settlement. `usdcSpent` / `tokensBurned` describe the first buyback slice taken in the same call.
    event Executed(uint256 usdcToEco, uint256 usdcToDev, uint256 usdcSpent, uint256 tokensBurned, uint256 reserveLeft);
    /// @dev A standalone buyback slice (between settlements).
    event BoughtBack(uint256 usdcSpent, uint256 tokensBurned, uint256 reserveLeft);
    event Converted(address indexed token, uint256 amountIn, uint256 usdcOut);

    error AlreadyConfigured();
    error NotConfigured();
    error NoPool();
    error TooSoon(uint256 nextAt);
    error NothingToDo();
    error ZeroAddress();

    constructor(address usdc_, address router_, address uniFactory_, address ecoFund_, address devFund_, address owner_)
        Ownable(owner_)
    {
        if (
            usdc_ == address(0) || router_ == address(0) || uniFactory_ == address(0) || ecoFund_ == address(0)
                || devFund_ == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        router = ISwapRouter(router_);
        uniFactory = IUniswapV3Factory(uniFactory_);
        ecoFund = ecoFund_;
        devFund = devFund_;
    }

    /// @notice Sets the platform token once it exists (it is launched through the factory, so it cannot be a
    ///         constructor argument). Write-once: after this call nothing about the contract can be changed.
    function configure(address platformToken_, uint24 poolFee_) external onlyOwner {
        if (platformToken != address(0)) revert AlreadyConfigured();
        if (platformToken_ == address(0)) revert ZeroAddress();
        address pool = uniFactory.getPool(platformToken_, usdc, poolFee_);
        if (pool == address(0)) revert NoPool();
        platformToken = platformToken_;
        platformPoolFee = poolFee_;
        platformPool = IUniswapV3Pool(pool);
        emit Configured(platformToken_, poolFee_, pool);
    }

    function usdcBalance() public view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    /// @notice Earliest timestamp at which `execute` may run again (0 = never ran, may run now).
    function nextExecuteAt() public view returns (uint256) {
        return lastExecutedAt == 0 ? 0 : lastExecutedAt + INTERVAL;
    }

    /// @notice Earliest timestamp at which the next buyback slice may run.
    function nextBuybackAt() public view returns (uint256) {
        return lastBuybackAt == 0 ? 0 : lastBuybackAt + BUYBACK_COOLDOWN;
    }

    /// @notice USDC that arrived since the last cycle (everything held that is not already reserved).
    function pendingRevenue() public view returns (uint256) {
        uint256 bal = usdcBalance();
        return bal > buybackReserve ? bal - buybackReserve : 0;
    }

    /// @notice How much USDC the next buyback slice would spend right now (0 = nothing / no liquidity).
    function nextBuybackAmount() public view returns (uint256) {
        return _sliceAmount(buybackReserve);
    }

    function _sliceAmount(uint256 reserve) internal view returns (uint256) {
        if (platformToken == address(0) || reserve == 0) return 0;
        uint256 cap = SwapGuard.maxAmountInForImpact(platformPool, usdc < platformToken);
        return cap < reserve ? cap : reserve;
    }

    /// @notice Weekly settlement. Permissionless. 76% of new revenue → eco reserve, 4% → dev team, 20% → buyback
    ///         reserve, then the first buyback slice is taken immediately (if the platform token is live).
    /// @param minTokensOut extra slippage guard for that slice, on top of the TWAP floor.
    function execute(uint256 minTokensOut) external nonReentrant {
        // first cycle runs immediately; afterwards at most once per INTERVAL
        if (lastExecutedAt != 0 && block.timestamp < lastExecutedAt + INTERVAL) revert TooSoon(lastExecutedAt + INTERVAL);

        uint256 fresh = pendingRevenue();
        uint256 toEco = (fresh * ECO_BPS) / 10_000;
        uint256 toDev = (fresh * DEV_BPS) / 10_000;
        uint256 newReserve = buybackReserve + (fresh - toEco - toDev);
        if (toEco == 0 && toDev == 0 && _sliceAmount(newReserve) == 0) revert NothingToDo();

        buybackReserve = newReserve;
        lastExecutedAt = block.timestamp;
        if (toEco > 0) {
            IERC20(usdc).safeTransfer(ecoFund, toEco);
            totalToEco += toEco;
        }
        if (toDev > 0) {
            IERC20(usdc).safeTransfer(devFund, toDev);
            totalToDev += toDev;
        }
        (uint256 spent, uint256 burned) = _buybackSlice(minTokensOut);
        emit Executed(toEco, toDev, spent, burned, buybackReserve);
    }

    /// @notice One buyback slice from the reserve. Permissionless, at most once per BUYBACK_COOLDOWN.
    /// @param minTokensOut extra slippage guard on top of the TWAP floor.
    function buyback(uint256 minTokensOut) external nonReentrant {
        if (platformToken == address(0)) revert NotConfigured();
        if (block.timestamp < nextBuybackAt()) revert TooSoon(nextBuybackAt());
        if (nextBuybackAmount() == 0) revert NothingToDo();
        (uint256 spent, uint256 burned) = _buybackSlice(minTokensOut);
        emit BoughtBack(spent, burned, buybackReserve);
    }

    /// @dev Spends min(reserve, impact cap) on the platform token and sends it to the burn address. Output must
    ///      clear both the caller's `minTokensOut` and the TWAP floor. No-op when nothing can be bought.
    function _buybackSlice(uint256 minTokensOut) internal returns (uint256 spent, uint256 burned) {
        spent = nextBuybackAmount();
        if (spent == 0) return (0, 0);
        bool zeroForOne = usdc < platformToken;
        uint256 floor_ = SwapGuard.twapMinOut(platformPool, spent, zeroForOne);
        if (floor_ > minTokensOut) minTokensOut = floor_;

        IERC20(usdc).forceApprove(address(router), spent);
        burned = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: usdc,
                tokenOut: platformToken,
                fee: platformPoolFee,
                recipient: BURN_ADDRESS,
                deadline: block.timestamp,
                amountIn: spent,
                amountOutMinimum: minTokensOut,
                sqrtPriceLimitX96: 0
            })
        );
        buybackReserve -= spent;
        lastBuybackAt = block.timestamp;
        totalBoughtBack += spent;
        totalBurned += burned;
    }

    /// @notice Convert protocol-share launch tokens into USDC (owner-gated because of slippage).
    function convert(address token, uint24 poolFee, uint256 amountIn, uint256 minUsdcOut) external nonReentrant onlyOwner {
        IERC20(token).forceApprove(address(router), amountIn);
        uint256 out = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: usdc,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minUsdcOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit Converted(token, amountIn, out);
    }
}
