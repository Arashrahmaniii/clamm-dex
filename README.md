# CLAMM — Concentrated-Liquidity AMM

A from-scratch implementation of a **concentrated-liquidity DEX** (Uniswap V3-style) in Solidity 0.8, with tick-based liquidity, Q64.96 fixed-point sqrt-price accounting, ERC-721 liquidity positions, flash loans, protocol fees, a TWAP oracle, and an off-chain quoter. Built with Hardhat + TypeScript and covered by 70 unit, integration and invariant tests.

> ⚠️ **Educational / portfolio project.** The contracts compile cleanly and the full test suite passes, but the code has **not been audited** and must not be used to hold real funds.

## Why concentrated liquidity?

Classic constant-product AMMs (x·y=k) spread liquidity across the entire price curve from 0 to ∞, so most capital sits at prices that will never trade. Concentrated liquidity lets an LP allocate capital to a chosen price range `[P_lower, P_upper]`, multiplying capital efficiency — the same depth around the current price for a fraction of the capital.

The core mechanics implemented here:

- **Ticks** — the price axis is discretised into ticks where price = 1.0001^tick. Positions are ranges between two initialized ticks; net liquidity deltas are stored per tick and applied as the price crosses them.
- **Q64.96 sqrt-price** — the pool tracks √P as a fixed-point number. Swaps integrate along the curve using `L` and `√P`, which turns amount math into multiplications/divisions with controlled rounding (always in the pool's favour).
- **Tick bitmap** — initialized ticks are indexed in a packed bitmap so the swap loop can find the next tick with bit tricks instead of iteration.
- **Fee growth accounting** — fees accrue as Q128.128 "growth per unit of liquidity" globals, with per-tick "outside" snapshots that make per-position fee computation O(1).
- **TWAP oracle** — the pool maintains a `tick × seconds` accumulator (advanced lazily at the start of each swap), so the time-weighted average tick between any two `observe()` samples is one subtraction and one division.

## Architecture

```
contracts/
├── core/
│   ├── CLAMMFactory.sol          # Pool registry + fee-tier governance
│   ├── CLAMMPoolDeployer.sol     # CREATE2 deployment with transient parameters
│   └── CLAMMPool.sol             # The AMM: mint/burn/swap/collect/flash
├── periphery/
│   ├── NonfungiblePositionManager.sol  # ERC-721 wrapper over pool positions
│   ├── SwapRouter.sol                  # Deadline + slippage protected swaps
│   ├── Quoter.sol                      # eth_call swap quotes via revert-and-catch
│   ├── base/Multicall.sol              # Atomic batching (create+init+mint, ...)
│   └── libraries/LiquidityAmounts.sol
├── libraries/
│   ├── TickMath.sol              # tick ⇄ sqrtPriceX96 (fixed-point exp/log)
│   ├── SqrtPriceMath.sol         # price/amount deltas with directional rounding
│   ├── SwapMath.sol              # single swap-step computation
│   ├── FullMath.sol              # 512-bit mulDiv (no phantom overflow)
│   ├── TickBitmap.sol            # packed initialized-tick index
│   ├── Tick.sol / Position.sol   # storage libraries + fee accounting
│   └── BitMath / FixedPoint / SafeCast / LiquidityMath / TransferHelper
└── interfaces/                   # Pool, factory, and callback interfaces
```

### Design decisions

- **Callback-based payment** (like Uniswap V3): `mint`/`swap`/`flash` send output first, then require payment inside a callback verified by balance checks. This enables composability (routers, aggregators, flash accounting) without approvals to the pool itself.
- **CREATE2 pools without constructor args**: the deployer stores parameters transiently, so the pool init code hash is constant and pool addresses are deterministic.
- **Reentrancy**: the pool uses a `slot0.unlocked` mutex on every state-mutating entrypoint — mandatory because payment verification is balance-based.
- **Rounding discipline**: every division rounds against the user (up for amounts owed to the pool, down for amounts paid out). The test suite asserts round-trip mint→burn loses at most 1 wei to rounding.
- **Callback validation in periphery**: the position manager pins the expected pool address for the in-flight mint; the router derives the canonical pool from the factory and rejects any other caller.
- **Protocol fees**: 0 or 1/4 … 1/10 of swap fees per token, gated to the factory owner, matching the V3 governance surface.
- **Single-accumulator oracle instead of a ring buffer**: `observe()` extrapolates one `(tickCumulative, timestamp)` pair to the current block. Consumers that need historical windows sample it themselves (e.g. from a keeper), which keeps swap-path gas overhead to two warm storage writes instead of V3's observation array.
- **Quoter via revert-and-catch**: quotes execute the real swap against the real pool and abort from the callback with the amounts encoded in the revert data — zero drift from the actual swap path, no state mutation, usable with `eth_call`/`callStatic`.

### Scope notes

Deliberately out of scope to keep the audit surface small: multi-hop routing, native-ETH (WETH) handling in the periphery, permit-based approvals, and fee-on-transfer token support. Each is a well-understood extension and would be the natural next milestone.

## Getting started

```bash
npm install
npm run build     # hardhat compile
npm test          # 70 unit + integration + invariant tests
npm run lint      # solhint
REPORT_GAS=true npx hardhat test   # gas report
```

## Test coverage highlights

- **TickMath** verified against closed-form `sqrt(1.0001^tick)·2^96` reference values, exact boundary constants (`MIN/MAX_SQRT_RATIO`), monotonicity, and full round-trips of `getTickAtSqrtRatio(getSqrtRatioAtTick(t))`.
- **FullMath** phantom-overflow cases (`2^200 · 2^100 / 2^150`) and exact bigint cross-checks.
- **Pool lifecycle**: initialize-once, in-range/out-of-range mints, tick-spacing enforcement, exact-input and exact-output swaps in both directions, price-limit partial fills, tick crossing deactivating liquidity, fee accrual to the exact expected 0.30%, protocol fee split and collection, flash loans, and 1-wei-max rounding loss on principal exit.
- **Periphery**: ERC-721 authorization (owner/approved-operator), slippage and deadline reverts, callback caller validation, and a full LP-earns-fees-and-exits integration journey.
- **Oracle & quoter**: accumulator advances only when the price can move, TWAP reconstruction across a swap, and quoter outputs asserted equal-to-the-wei against subsequently executed swaps.
- **Solvency invariant**: seeded randomized sessions (mints, both-direction exact-in/out swaps, flashes, partial burns) followed by a full exit of every position and the protocol fees — the pool must honour every withdrawal and end holding nothing but sub-1e6-wei rounding dust.

## Security considerations

| Vector | Mitigation |
|---|---|
| Reentrancy via token hooks | Pool-wide mutex (`lock`), checks-effects-interactions in periphery |
| Callback spoofing | Pool address pinned (NPM) / derived from factory (router) before paying |
| Phantom overflow in price math | 512-bit `FullMath.mulDiv` throughout |
| Rounding drift | All roundings directed against the caller; asserted in tests |
| Non-standard ERC20 return values | `TransferHelper` tolerates empty return data |
| Tick spacing / bitmap overflow | Factory caps `tickSpacing < 16384` |

## License

MIT. The tick/sqrt-price algorithms follow the approach pioneered by Uniswap V3 (also MIT/GPL-licensed); this is an independent implementation written for learning and demonstration.
