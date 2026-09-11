// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INonfungiblePositionManager, ISwapRouter, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {SwapGuard} from "./libraries/SwapGuard.sol";

/// @dev The slice of LaunchToken the locker needs; kept as an interface to avoid a circular import.
interface ILaunchTokenTax {
    function taxConfig()
        external
        view
        returns (uint16 buyBps, uint16 sellBps, address marketing, address team, uint16 marketingShareBps);
}

/// @title FeeLocker
/// @notice Holds every launch's LP position forever and splits collected swap fees between the creator
///         and the protocol treasury. There is no function that can move a position out.
/// @dev `distribute` is permissionless; a keeper calls it on a schedule, but anyone (including the
///      creator) can trigger it. Creator payouts that revert (e.g. USDC blocklist on Arc) are parked
///      in `claimable` so a single bad address can never wedge the pool or the protocol share.
///
///      Payouts are USDC-only: the token-side fees a V3 position accrues are sold back into the same
///      pool inside `distribute` and the proceeds join the USDC split. If that swap fails (slippage
///      guard, paused token, ...) the tokens stay here and are retried on the next distribution, so a
///      bad swap can never block the USDC payout.
///
///      Because `distribute` is permissionless the sale is guarded (see SwapGuard): the output must be at
///      least the pool TWAP quote minus a tolerance regardless of what the caller passes, and at most an
///      amount that moves the price ~1.5% is sold per call — a sandwich can therefore neither fill us at a
///      manipulated price nor be profitable. Anything not sold stays in the backlog for the next call.
///
///      The creator payout address can only be rotated by the current payout address itself. There is no
///      owner path to change it (the former 48h "community takeover" proposal flow was removed in v2.9).
contract FeeLocker is IERC721Receiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        uint256 tokenId;
        address token; // launch token
        address quote; // USDC
        address pool; // the token/USDC 1% pool (for the swap guard)
        address creator; // original deployer (immutable record)
        address payout; // where creator share is sent; only the current payout address can rotate it
        uint16 creatorShareBps; // snapshotted at launch, never changes
        bool exists;
    }

    uint24 public constant POOL_FEE = 10_000; // every launch pool is the 1% tier

    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter public immutable router;
    address public factory;
    /// @dev Where the protocol share goes. Fixed at deployment.
    address public immutable treasury;

    mapping(address token => Lock) public locks;
    /// @dev claimable[account][asset] — creator share that could not be pushed.
    mapping(address => mapping(address => uint256)) public claimable;
    /// @dev Token-side fees collected but not yet converted to USDC (swap failed); retried next time.
    mapping(address token => uint256) public unconvertedTokenFees;
    /// @dev Tax tokens (tax-mode launches push their creator share here) not yet converted; retried next time.
    ///      Anything held beyond `unconvertedTokenFees + unconvertedTax` is freshly accrued tax.
    mapping(address token => uint256) public unconvertedTax;

    event Locked(address indexed token, uint256 indexed tokenId, address indexed creator, address payout, uint16 creatorShareBps);
    event FeesDistributed(
        address indexed token,
        uint256 quoteToCreator,
        uint256 quoteToProtocol,
        uint256 tokenConverted,
        uint256 usdcFromToken,
        bool creatorPaid
    );
    event TokenFeesDeferred(address indexed token, uint256 amount);
    /// @dev Tax proceeds (no protocol share) paid in the same distribute call to the token's two tax wallets.
    event TaxDistributed(
        address indexed token,
        uint256 tokenConverted,
        address marketingWallet,
        uint256 usdcToMarketing,
        address teamWallet,
        uint256 usdcToTeam,
        bool allPaid
    );
    event Claimed(address indexed account, address indexed asset, uint256 amount);
    event PayoutChanged(address indexed token, address indexed oldPayout, address indexed newPayout);
    event FactorySet(address factory);

    error OnlyFactory();
    error AlreadyLocked();
    error UnknownToken();
    error NothingToClaim();
    error ZeroAddress();
    error NotCreator();

    constructor(address positionManager_, address router_, address treasury_, address owner_) Ownable(owner_) {
        if (positionManager_ == address(0) || router_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        positionManager = INonfungiblePositionManager(positionManager_);
        router = ISwapRouter(router_);
        treasury = treasury_;
    }

    // ------------------------------------------------------------------ admin

    /// @notice One-time wiring; the factory is deployed after the locker.
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadyLocked();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    // ------------------------------------------------------------------ payout address

    /// @notice Creator wallet rotation. Only the current payout address may move it, and it takes
    ///         effect immediately. The owner has no path to change a creator's payout.
    function setPayout(address token, address newPayout) external {
        Lock storage l = locks[token];
        if (!l.exists) revert UnknownToken();
        if (msg.sender != l.payout) revert NotCreator();
        if (newPayout == address(0)) revert ZeroAddress();
        emit PayoutChanged(token, l.payout, newPayout);
        l.payout = newPayout;
    }

    // ------------------------------------------------------------------ factory hook

    /// @dev Called by the factory after it has transferred the position NFT to this contract.
    ///      `payout` is where the creator share goes from day one (the creator may pick a separate fee wallet).
    function register(
        address token,
        address quote,
        address pool,
        uint256 tokenId,
        address creator,
        address payout,
        uint16 creatorShareBps
    ) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (locks[token].exists) revert AlreadyLocked();
        if (payout == address(0) || pool == address(0)) revert ZeroAddress();
        require(positionManager.ownerOf(tokenId) == address(this), "position not held");
        locks[token] = Lock({
            tokenId: tokenId,
            token: token,
            quote: quote,
            pool: pool,
            creator: creator,
            payout: payout,
            creatorShareBps: creatorShareBps,
            exists: true
        });
        emit Locked(token, tokenId, creator, payout, creatorShareBps);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ distribution

    /// @notice Collect accrued swap fees for `token`, convert the token side to USDC and split the USDC.
    ///         Anyone may call.
    /// @param minUsdcOut slippage guard for the token→USDC swap (0 = accept any; the keeper passes a
    ///        quote-based value). If the swap reverts the tokens are kept and retried next time.
    /// @return usdcCollected USDC fees collected from the position
    /// @return usdcFromToken USDC obtained by selling the token-side fees (0 if deferred)
    function distribute(address token, uint256 minUsdcOut)
        external
        nonReentrant
        returns (uint256 usdcCollected, uint256 usdcFromToken)
    {
        Lock memory l = locks[token];
        if (!l.exists) revert UnknownToken();

        // tax-mode tokens push the creator share of every tax here; anything beyond the two backlogs is new
        uint256 held = IERC20(token).balanceOf(address(this));
        uint256 backlog = unconvertedTokenFees[token] + unconvertedTax[token];
        uint256 taxAccrued = held > backlog ? held - backlog : 0;

        uint256 tokenCollected;
        (tokenCollected, usdcCollected) = _collect(l);

        Conversion memory c = _convert(l, tokenCollected, taxAccrued, minUsdcOut);
        usdcFromToken = c.usdcFromFees;

        _split(l, usdcCollected + c.usdcFromFees, c.feeConverted, c.usdcFromFees);
        if (c.taxConverted > 0) _payTax(l, c.taxConverted, c.usdcFromTax);
    }

    struct Conversion {
        uint256 feePart; // fee tokens available (collected + backlog)
        uint256 taxPart; // tax tokens available (accrued + backlog)
        uint256 feeConverted;
        uint256 usdcFromFees;
        uint256 taxConverted;
        uint256 usdcFromTax;
    }

    /// @dev Tax USDC → the token's marketing / team wallets in the immutable split set at launch.
    function _payTax(Lock memory l, uint256 taxConverted, uint256 usdcFromTax) internal {
        (,, address marketing, address team, uint16 marketingBps) = ILaunchTokenTax(l.token).taxConfig();
        uint256 toMarketing = (usdcFromTax * marketingBps) / 10_000;
        uint256 toTeam = usdcFromTax - toMarketing;
        bool paid = true;
        if (toMarketing > 0) paid = _push(l.quote, marketing, toMarketing) && paid;
        if (toTeam > 0) paid = _push(l.quote, team, toTeam) && paid;
        emit TaxDistributed(l.token, taxConverted, marketing, toMarketing, team, toTeam, paid);
    }

    function _collect(Lock memory l) internal returns (uint256 tokenCollected, uint256 usdcCollected) {
        (uint256 a0, uint256 a1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: l.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        return l.token < l.quote ? (a0, a1) : (a1, a0);
    }

    /// @dev Sells freshly collected token fees + tax + both backlogs in ONE guarded swap, then attributes the
    ///      USDC pro rata to the fee part (split 75/25 later) and the tax part (100% creator wallets).
    ///      Sells at most `SwapGuard.maxAmountInForImpact` and never below the TWAP floor; whatever is not
    ///      sold (cap, or the swap failing) stays in the two backlogs for next time.
    function _convert(Lock memory l, uint256 tokenCollected, uint256 taxAccrued, uint256 minUsdcOut)
        internal
        returns (Conversion memory c)
    {
        c.feePart = tokenCollected + unconvertedTokenFees[l.token];
        c.taxPart = taxAccrued + unconvertedTax[l.token];
        uint256 total = c.feePart + c.taxPart;
        if (total == 0) return c;

        (bool ok, uint256 sell, uint256 out) = _guardedSell(l, total, minUsdcOut);
        if (!ok) {
            unconvertedTokenFees[l.token] = c.feePart;
            unconvertedTax[l.token] = c.taxPart;
            emit TokenFeesDeferred(l.token, total);
            return c;
        }
        // pro-rata attribution of what was sold; the rest of each bucket waits
        c.feeConverted = (sell * c.feePart) / total;
        c.taxConverted = sell - c.feeConverted;
        unconvertedTokenFees[l.token] = c.feePart - c.feeConverted;
        unconvertedTax[l.token] = c.taxPart - c.taxConverted;
        if (sell < total) emit TokenFeesDeferred(l.token, total - sell);
        c.usdcFromTax = (out * c.taxConverted) / sell;
        c.usdcFromFees = out - c.usdcFromTax;
    }

    /// @dev Sell min(total, impact cap) of the token with the TWAP floor applied. ok=false when nothing sold.
    function _guardedSell(Lock memory l, uint256 total, uint256 minUsdcOut)
        internal
        returns (bool ok, uint256 sell, uint256 out)
    {
        bool zeroForOne = l.token < l.quote;
        sell = SwapGuard.maxAmountInForImpact(IUniswapV3Pool(l.pool), zeroForOne);
        if (sell > total) sell = total;
        if (sell == 0) return (false, 0, 0);
        uint256 floor_ = SwapGuard.twapMinOut(IUniswapV3Pool(l.pool), sell, zeroForOne);
        (ok, out) = _sellForUsdc(l.token, l.quote, sell, minUsdcOut > floor_ ? minUsdcOut : floor_);
    }

    function _split(Lock memory l, uint256 total, uint256 tokenConverted, uint256 usdcFromToken) internal {
        uint256 toCreator = (total * l.creatorShareBps) / 10_000;
        uint256 toProtocol = total - toCreator;
        bool paid = true;
        if (toCreator > 0) paid = _push(l.quote, l.payout, toCreator);
        if (toProtocol > 0) _push(l.quote, treasury, toProtocol);
        emit FeesDistributed(l.token, toCreator, toProtocol, tokenConverted, usdcFromToken, paid);
    }

    /// @notice Withdraw parked amounts (only used when an automatic push failed).
    function claim(address asset) external nonReentrant {
        uint256 amt = claimable[msg.sender][asset];
        if (amt == 0) revert NothingToClaim();
        claimable[msg.sender][asset] = 0;
        IERC20(asset).safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, asset, amt);
    }

    /// @dev Sell `amountIn` of `token` for `quote` through the launch pool. Never reverts.
    function _sellForUsdc(address token, address quote, uint256 amountIn, uint256 minOut)
        internal
        returns (bool ok, uint256 out)
    {
        IERC20(token).forceApprove(address(router), amountIn);
        try router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: quote,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut) {
            ok = true;
            out = amountOut;
        } catch {
            IERC20(token).forceApprove(address(router), 0);
        }
    }

    /// @dev Push `amount` of `asset` to `to`; on any failure, park it as claimable. Returns whether pushed.
    function _push(address asset, address to, uint256 amount) internal returns (bool ok) {
        // low-level call so a reverting/blocklisted recipient cannot block distribution
        (bool success, bytes memory ret) = asset.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        ok = success && (ret.length == 0 || abi.decode(ret, (bool)));
        if (!ok) claimable[to][asset] += amount;
    }

    // ------------------------------------------------------------------ views

    /// @notice Fees accrued but not yet collected (from the position's `tokensOwed`), plus uncollected
    ///         growth is not included — good enough for keeper thresholds; call `distribute` to realize.
    function pendingOwed(address token) external view returns (uint256 tokenOwed, uint256 quoteOwed) {
        Lock memory l = locks[token];
        if (!l.exists) revert UnknownToken();
        (,,,,,,,,,, uint128 owed0, uint128 owed1) = positionManager.positions(l.tokenId);
        return l.token < l.quote ? (owed0, owed1) : (owed1, owed0);
    }
}
