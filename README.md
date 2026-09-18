# ARK Launch — contracts

Fair-launch token launchpad on [Arc](https://www.arc.io) (Circle's USDC-gas Layer 1, chainId 5042).

One transaction deploys a fixed-supply ERC-20, creates a USDC/token Uniswap V3 pool (1% fee tier), seeds the whole supply as single-sided liquidity and locks the LP position forever. There is no bonding curve and no migration step: the Uniswap pool is the market from the first block. Trading fees are converted to USDC and paid out on-chain — 75% to the token creator, 25% to the protocol.

App: https://ark-ai.xyz

## Contracts

| Contract | Role |
|---|---|
| `src/LaunchFactory.sol` | `launch()`: deploys a `LaunchToken` (CREATE2), creates and initialises the Uniswap V3 pool at a fixed opening market cap, mints the single-sided position, hands the LP NFT to the `FeeLocker`, takes the 1 USDC creation fee and an optional creator first buy. Tracks graduation (pool USDC ≥ threshold). |
| `src/LaunchToken.sol` | Fixed 1,000,000,000 supply ERC-20 with on-chain metadata (logo, description, socials). Short anti-snipe window after launch (20 blocks, max buy 5.5% / max hold 5%). Optional immutable buy/sell tax (≤ 10%) collected on pool transfers only. |
| `src/FeeLocker.sol` | Holds every LP NFT permanently — there is no withdrawal function. Permissionless `distribute(token, minUsdcOut)` collects pool fees, sells the token side into USDC behind a TWAP / price-impact guard and pays 75% to the creator's payout address and 25% to the `Treasury`. Tax proceeds go 100% to the creator's marketing / team wallets. |
| `src/Treasury.sol` | Accumulates the protocol share. Permissionless `execute()` once every 7 days transfers 76% to `ecoFund`, 20% to `buybackFund`, 4% to `devFund`. |
| `src/libraries/SwapGuard.sol` | TWAP floor + per-call price-impact cap used by every protocol-side swap, so permissionless callers cannot sandwich the conversion. |
| `src/libraries/PriceMath.sol`, `TickMath.sol` | Opening-price / tick maths for the single-sided position. |

Every economic parameter (pool fee, creator share, creation fee, opening market cap, graduation threshold, anti-snipe limits, tax cap, treasury split and the three payout addresses) is a `constant` or `immutable`. The contracts have no upgrade path and no owner function that can move funds or change a creator's payout address.

## Fee model

Per trade, the Uniswap pool charges 1% of the quote side. After conversion to USDC:

| Recipient | Share of the 1% fee |
|---|---|
| Token creator (payout address) | 75% |
| Reserve multisig (`ecoFund`) | 19% |
| Buyback multisig (`buybackFund`) | 5% |
| Development wallet (`devFund`) | 1% |

Creation fee: 1 USDC per launch, paid to `ecoFund` at launch time. Tax tokens: the creator-set tax (≤ 10% each way) is paid entirely to the creator's marketing / team wallets; the protocol keeps none of it.

## Deployments

Arc mainnet (chainId 5042, deploy block 21170619, 2026-09-16) — built on the official Uniswap V3 deployment:

| Contract | Address |
|---|---|
| LaunchFactory | `0x9B9A136d04E8E19a934de062F0FBB929b3C7AEdb` |
| FeeLocker | `0x4982E02eF7a31a7a0cdD3a9935f3c856EffA5190` |
| Treasury | `0xd217DB3226A31fA9035BF98531f282DF95A79730` |
| USDC (native ERC-20 interface) | `0x3600000000000000000000000000000000000000` |
| UniswapV3Factory | `0xf0db7b58379503491d857dB50AC9ece64c653918` |
| NonfungiblePositionManager | `0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377` |
| SwapRouter | `0x6c511d8634aeCC53AF1397536Cd8266E8d05e4a1` |
| QuoterV2 | `0x2D3aB496B8eDeDFD680db40Df4cB5FB65B74f7EB` |

The full set, including the payout addresses and the first-generation factory (own Uniswap V3 core, still serving the tokens it launched), is in [`deployments/arc-mainnet.json`](deployments/arc-mainnet.json). Testnet (chainId 5042002) addresses are in [`deployments/arc-testnet.json`](deployments/arc-testnet.json).

All contracts, and every token launched through the factory, are source-verified on [Sourcify](https://sourcify.dev) (chain 5042). Explorer: https://explorer.arc.io

## Build and test

Requires [Foundry](https://book.getfoundry.sh).

```bash
git clone https://github.com/yinyuan659-dev/ark
cd ark
git submodule update --init --recursive
forge build
forge test
```

Uniswap V3 core / periphery are deployed in tests from the official artifacts in `vendor/uniswap-v3/`. `script/Deploy.s.sol` reads `ECO_FUND`, `BUYBACK_FUND`, `DEV_FUND` and, to reuse an existing Uniswap deployment, `UNI_FACTORY` / `UNI_NFPM`; `foundry.toml` maps `ARC_RPC_URL` to the `arc_testnet` RPC alias.

## Links

- App: https://ark-ai.xyz · Integration guide: https://ark-ai.xyz/integrate
- X: https://x.com/ARKwbe4 · Telegram: https://t.me/ArkLaunchOfficial
- DefiLlama: [TVL adapter](https://github.com/DefiLlama/DefiLlama-Adapters/pull/21106) · [fees / volume adapter](https://github.com/DefiLlama/dimension-adapters/pull/9517)
- Token list (Uniswap Token Lists format): https://ark-ai.xyz/tokenlist.json

## Security

The contracts have not been audited by a third party. Source is verified on Sourcify; static analysis (Slither) and the Foundry test suite (`test/`) cover launches, fee distribution, tax tokens, anti-snipe limits, pool pre-creation attacks and the swap guard. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
