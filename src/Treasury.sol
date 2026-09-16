// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "./interfaces/IUniswapV3.sol";

/// @title Treasury
/// @notice Collects the protocol share of swap fees (0.25% of every trade, i.e. 25% of the 1% pool fee) in USDC
///         and settles it on a fixed weekly cycle to three fixed addresses:
///           - ECO_BPS (76%  = 0.19% of the trade) → the ecosystem reserve (a multisig);
///           - BUYBACK_BPS (20% = 0.05% of the trade) → the buyback fund (a multisig run by the project; whatever
///             it buys back and burns is done there by hand and recorded off-chain);
///           - DEV_BPS (4% = 0.01% of the trade) → the development team wallet.
///         Together with the creator's 75% that is the whole 1% pool fee: 75 / 19 / 5 / 1.
///         The split, the cadence and all three payout addresses are immutable. There is no on-chain buyback any
///         more (v2.10): the contract never swaps on its own, so there is nothing to sandwich and no platform token
///         to configure.
/// @dev `execute` is permissionless; a keeper calls it on schedule. Contracts cannot schedule themselves, so the
///      interval is enforced here and the trigger comes from outside.
contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant ECO_BPS = 7_600; // 76% of the protocol share → ecosystem reserve (multisig)
    uint16 public constant BUYBACK_BPS = 2_000; // 20% → buyback fund (multisig)
    uint16 public constant DEV_BPS = 400; // 4% → development team
    uint256 public constant INTERVAL = 7 days;

    address public immutable usdc;
    ISwapRouter public immutable router;
    /// @dev The ecosystem multisig. Fixed at deployment; nobody (owner included) can redirect it.
    address public immutable ecoFund;
    /// @dev The buyback multisig. Fixed at deployment.
    address public immutable buybackFund;
    /// @dev The development team wallet (single address). Fixed at deployment.
    address public immutable devFund;

    uint256 public lastExecutedAt;

    uint256 public totalToEco;
    uint256 public totalToBuyback;
    uint256 public totalToDev;

    /// @dev Weekly settlement.
    event Executed(uint256 usdcToEco, uint256 usdcToBuyback, uint256 usdcToDev);
    event Converted(address indexed token, uint256 amountIn, uint256 usdcOut);

    error TooSoon(uint256 nextAt);
    error NothingToDo();
    error ZeroAddress();

    constructor(address usdc_, address router_, address ecoFund_, address buybackFund_, address devFund_, address owner_)
        Ownable(owner_)
    {
        if (
            usdc_ == address(0) || router_ == address(0) || ecoFund_ == address(0) || buybackFund_ == address(0)
                || devFund_ == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        router = ISwapRouter(router_);
        ecoFund = ecoFund_;
        buybackFund = buybackFund_;
        devFund = devFund_;
    }

    function usdcBalance() public view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    /// @notice Earliest timestamp at which `execute` may run again (0 = never ran, may run now).
    function nextExecuteAt() public view returns (uint256) {
        return lastExecutedAt == 0 ? 0 : lastExecutedAt + INTERVAL;
    }

    /// @notice USDC that arrived since the last cycle (everything held; nothing is ever reserved).
    function pendingRevenue() public view returns (uint256) {
        return usdcBalance();
    }

    /// @notice Weekly settlement. Permissionless. 76% of new revenue → eco reserve, 20% → buyback fund,
    ///         4% → dev team. Rounding dust stays for the next cycle.
    function execute() external nonReentrant {
        // first cycle runs immediately; afterwards at most once per INTERVAL
        if (lastExecutedAt != 0 && block.timestamp < lastExecutedAt + INTERVAL) revert TooSoon(lastExecutedAt + INTERVAL);

        uint256 fresh = pendingRevenue();
        uint256 toEco = (fresh * ECO_BPS) / 10_000;
        uint256 toBuyback = (fresh * BUYBACK_BPS) / 10_000;
        uint256 toDev = (fresh * DEV_BPS) / 10_000;
        if (toEco == 0 && toBuyback == 0 && toDev == 0) revert NothingToDo();

        lastExecutedAt = block.timestamp;
        if (toEco > 0) {
            IERC20(usdc).safeTransfer(ecoFund, toEco);
            totalToEco += toEco;
        }
        if (toBuyback > 0) {
            IERC20(usdc).safeTransfer(buybackFund, toBuyback);
            totalToBuyback += toBuyback;
        }
        if (toDev > 0) {
            IERC20(usdc).safeTransfer(devFund, toDev);
            totalToDev += toDev;
        }
        emit Executed(toEco, toBuyback, toDev);
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
