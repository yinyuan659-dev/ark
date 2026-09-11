// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC20 with on-chain metadata, a short anti-snipe window after launch and an
///         optional creator-set trading tax that is fixed forever at deployment.
/// @dev Restrictions only apply to transfers *out of the pool* (i.e. buys). Sells and wallet-to-wallet
///      transfers are never restricted. Everything is lifted once `restrictionsEndBlock` passes.
///
///      Tax ("tax mode", `buyTaxBps`/`sellTaxBps` > 0) applies only to transfers between the pool and a
///      non-exempt wallet, and is written so the Uniswap V3 pool never sees a short transfer:
///        - buy  (pool → wallet): the pool sends `value`; the wallet receives `value − tax`, the tax is
///          routed from that same amount, so the pool's balance drops by exactly `value`.
///        - sell (wallet → pool): the pool receives the full `value`; the tax is charged *on top*, from the
///          seller's remaining balance. The seller therefore needs `value + tax` to sell `value`.
///      Every tax goes to `taxSink` (the FeeLocker), which sells it for USDC and pays two creator-chosen
///      wallets — "marketing" and "team" — in the fixed `marketingBps` / (10000 − marketingBps) split. The
///      same two wallets and split apply to buys and sells.
///      All tax parameters are immutable — nobody, including the platform, can change them after launch.
contract LaunchToken is ERC20 {
    struct Socials {
        string website;
        string twitter;
        string telegram;
        string discord;
        string farcaster;
    }

    uint256 public constant SUPPLY = 1_000_000_000e18;

    address public immutable factory;
    address public immutable deployer;
    string public logo;
    string public description;
    Socials private _socials;

    address public liquidityPool;
    uint256 public immutable launchBlock;
    uint256 public immutable restrictionsEndBlock;
    /// @dev Basis points of SUPPLY. 10_000 = 100%.
    uint16 public immutable maxHoldBps;
    uint16 public immutable maxBuyBps;

    /// @dev Trading tax in basis points of the traded amount; 0/0 = standard token.
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    /// @dev Where the FeeLocker sends the USDC proceeds of the tax: `marketingBps` to marketing, rest to team.
    address public immutable marketingWallet;
    address public immutable teamWallet;
    uint16 public immutable marketingBps;
    address public immutable taxSink;

    event TaxCharged(address indexed payer, bool isBuy, uint256 amount);

    /// @dev Addresses that may receive from the pool during the launch block (creator's initial buy)
    ///      and are never subject to hold caps (factory, locker, position manager).
    mapping(address => bool) public exempt;

    event PoolSet(address indexed pool);

    error OnlyFactory();
    error PoolAlreadySet();
    error ZeroAddress();
    error LaunchBlockOnlyCreator();
    error ExceedsMaxBuy();
    error ExceedsMaxHold();
    error TaxOutOfRange();

    struct Init {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address deployer;
        uint256 protectionBlocks;
        uint16 maxHoldBps;
        uint16 maxBuyBps;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        address marketingWallet;
        address teamWallet;
        uint16 marketingBps;
        address taxSink;
        address[] exempt;
    }

    constructor(Init memory i) ERC20(i.name, i.symbol) {
        // the factory validates the caps; this only guards against a nonsensical configuration
        if (i.marketingBps > 10_000) revert TaxOutOfRange();
        if (i.buyTaxBps > 0 || i.sellTaxBps > 0) {
            if (i.taxSink == address(0) || i.marketingWallet == address(0) || i.teamWallet == address(0)) revert ZeroAddress();
        }
        factory = msg.sender;
        deployer = i.deployer;
        logo = i.logo;
        description = i.description;
        _socials = i.socials;
        launchBlock = block.number;
        restrictionsEndBlock = block.number + i.protectionBlocks;
        maxHoldBps = i.maxHoldBps;
        maxBuyBps = i.maxBuyBps;
        buyTaxBps = i.buyTaxBps;
        sellTaxBps = i.sellTaxBps;
        marketingWallet = i.marketingWallet;
        teamWallet = i.teamWallet;
        marketingBps = i.marketingBps;
        taxSink = i.taxSink;
        for (uint256 k; k < i.exempt.length; ++k) exempt[i.exempt[k]] = true;
        exempt[msg.sender] = true;
        _mint(msg.sender, SUPPLY);
    }

    function isTaxToken() public view returns (bool) {
        return buyTaxBps > 0 || sellTaxBps > 0;
    }

    function socials()
        external
        view
        returns (string memory website, string memory twitter, string memory telegram, string memory discord, string memory farcaster)
    {
        return (_socials.website, _socials.twitter, _socials.telegram, _socials.discord, _socials.farcaster);
    }

    /// @notice Set once by the factory right after the pool is created.
    function setPool(address pool) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (liquidityPool != address(0)) revert PoolAlreadySet();
        if (pool == address(0)) revert ZeroAddress();
        liquidityPool = pool;
        exempt[pool] = true;
        emit PoolSet(pool);
    }

    function restrictionsActive() public view returns (bool) {
        return block.number <= restrictionsEndBlock;
    }

    function _update(address from, address to, uint256 value) internal override {
        address pool = liquidityPool;
        bool isBuy = pool != address(0) && from == pool && !exempt[to];
        bool isSell = pool != address(0) && to == pool && !exempt[from];

        // Buys = tokens leaving the pool. Only these are guarded, and only during the window.
        if (isBuy && block.number <= restrictionsEndBlock) {
            if (block.number == launchBlock && to != deployer) revert LaunchBlockOnlyCreator();
            if (value > (SUPPLY * maxBuyBps) / 10_000) revert ExceedsMaxBuy();
            if (balanceOf(to) + value > (SUPPLY * maxHoldBps) / 10_000) revert ExceedsMaxHold();
        }

        if (isBuy && buyTaxBps > 0) {
            // pool pays `value` in full; the buyer receives value − tax, the tax goes to the sink
            uint256 tax = (value * buyTaxBps) / 10_000;
            super._update(from, to, value - tax);
            if (tax > 0) super._update(from, taxSink, tax);
            emit TaxCharged(to, true, tax);
            return;
        }
        if (isSell && sellTaxBps > 0) {
            // pool receives `value` in full (V3 checks this); the tax is charged on top from the seller
            uint256 tax = (value * sellTaxBps) / 10_000;
            super._update(from, to, value);
            if (tax > 0) super._update(from, taxSink, tax);
            emit TaxCharged(from, false, tax);
            return;
        }
        super._update(from, to, value);
    }

    /// @notice Tax destination in one call (for the FeeLocker and integrators).
    function taxConfig()
        external
        view
        returns (uint16 buyBps, uint16 sellBps, address marketing, address team, uint16 marketingShareBps)
    {
        return (buyTaxBps, sellTaxBps, marketingWallet, teamWallet, marketingBps);
    }
}
