# Security

This document records the static-analysis baseline for CLAMM and the reasoning
behind every suppressed finding. It is written to be read by an auditor: each
finding is either fixed or justified, and "the tool is wrong" is never asserted
without an argument for *why*.

## Running the analysis

```bash
pip install slither-analyzer
solc-select install 0.8.24 && solc-select use 0.8.24
slither . --filter-paths "lib|test" --exclude-dependencies
```

## Baseline

Slither 0.11.6, solc 0.8.24, 44 contracts analysed with 102 detectors.
**53 results.** Every one is triaged below.

| Severity | Count | Fixed | Accepted |
|---|---|---|---|
| High | 13 | 0 | 13 |
| Medium | 19 | 0 | 19 |
| Low | 15 | 0 | 15 |
| Informational | 6 | 0 | 6 |

No finding required a code change. The reasoning for each class follows.

---

## High

### `arbitrary-send-erc20` — 3 findings — **accepted (false positive)**

`SwapRouter.clammSwapCallback` and `NonfungiblePositionManager.clammMintCallback`
both call `safeTransferFrom(token, decoded.payer, msg.sender, amount)` where
`payer` is decoded from callback data. Slither flags any `transferFrom` whose
`from` is not `msg.sender`.

This is the canonical AMM payment pattern, and it is only safe if the callback
verifies that the caller is a real pool. Both do:

- **`SwapRouter`** (`SwapRouter.sol:75-78`) resolves the pool through the factory
  for the `(tokenIn, tokenOut, fee)` triple carried in the callback data and
  requires `msg.sender` to equal it. An attacker cannot forge a `payer`, because
  reaching the transfer requires *being* the canonical pool for the pair they
  named.
- **`NonfungiblePositionManager`** (`NonfungiblePositionManager.sol:168`) uses a
  guard variable, `_expectedCallbackPool`, set immediately before
  `pool.mint(...)` and cleared immediately after (`:203`, `:212`). Outside that
  window the guard is `address(0)`, and the check additionally requires
  `msg.sender != address(0)`, so the callback is unreachable when no mint is in
  flight.

`payer` is always set to `msg.sender` at the call site
(`SwapRouter.sol:109`, `:138`; `NonfungiblePositionManager.sol:210`) and is never
caller-controlled.

> **Design note.** The two contracts verify differently on purpose. The router is
> stateless and can afford a factory `SLOAD` per swap. The position manager is
> already mid-call with the pool address in memory, so a guard is cheaper than a
> second factory lookup. Uniswap V3 instead recomputes the pool address via
> CREATE2 (`CallbackValidation`), which is cheaper still; that is a deliberate
> trade-off here in favour of not hardcoding an init-code hash that changes
> whenever the pool is recompiled. See *Known improvements* below.

### `reentrancy-balance` — 10 findings — **accepted (false positive)**

All ten are inside `swap`, `mint`, `flash`, `collect`, and `collectProtocol`,
where the pool transfers tokens or invokes a callback before writing state.

The pool's protection is not check-effects-interactions; it is the `lock`
modifier, which is set on entry and cleared on exit of every state-mutating
external function. Slither does not model the modifier as a reentrancy guard
because it is a bespoke `slot0.unlocked` bit rather than a recognised
`ReentrancyGuard`.

The balance-based accounting Slither objects to is the *point* of the design: the
pool records `balanceBefore`, invokes the callback, then requires the balance to
have increased by the owed amount (`CLAMMPool.sol:316-317` for mint,
`:606-648` for flash). A reentrant call cannot satisfy two such checks with one
payment, and the `lock` makes the question moot.

Covered by `test/Features.t.sol` (reentrancy attempts against `swap`, `mint`, and
`flash` all revert with `LOK`) and by the randomised solvency invariant in
`test/Invariant.t.sol`.

---

## Medium

### `reentrancy-no-eth` — 6 findings — **accepted**

Same root cause as `reentrancy-balance`: the `lock` modifier. No ETH is handled
anywhere in the protocol; the pool is ERC-20-only.

### `unused-return` — 8 findings — **accepted (intentional)**

Three distinct cases:

1. **`Quoter._quote`** (3 findings) ignores `pool.swap(...)`'s return because the
   call is *expected to revert*. The quoter executes the real swap and aborts
   from inside the callback with the amounts in the revert data, then decodes
   them. A return value is unreachable by construction — that is the mechanism.
2. **Destructured tuples** where only some members are needed — `slot0()` for the
   price, `positions()` for fee growth. Solidity has no syntax to request a
   subset, so the unused members are elided with `,,,`.
3. **`ICLAMMPool.burn(lower, upper, 0)`** in `NonfungiblePositionManager.collect`
   — a zero-liquidity burn called purely for its side effect of poking fee
   growth up to date before collecting. The returned amounts are always `(0, 0)`.

### `uninitialized-local` — 5 findings — **accepted (false positive)**

`flippedLower`, `flippedUpper`, `balance0Before`, `balance1Before`, and the
`StepComputations step` struct are all assigned before their first read. Solidity
zero-initialises them; the detector reports the absence of an explicit
initialiser, not an actual read-before-write. Writing `= false` / `= 0` would add
bytecode for no semantic change.

---

## Low and Informational

| Detector | Count | Disposition |
|---|---|---|
| `reentrancy-events` | 8 | Accepted. Events emitted after transfers. Event *ordering* under reentrancy is not a security property here, and the `lock` prevents reentrancy regardless. |
| `shadowing-local` | 3 | Accepted. Locals named after inherited getters (e.g. `factory`) inside functions that do not reference the getter. |
| `reentrancy-benign` | 2 | Accepted. `lock` modifier, as above. |
| `missing-zero-check` | 1 | Accepted. `CLAMMFactory.setOwner` — a zero owner is a valid way to permanently renounce fee governance, and the pool operates correctly with no owner set. |
| `calls-loop` | 1 | Accepted. `Multicall` delegatecalls into `address(this)` only; the loop bound is caller-supplied and gas-limited by the block. |
| `assembly` | 3 | Accepted. Quoter revert-data encode/decode and Multicall's bubbled revert. Both need raw `revert`/`returndata` access unavailable in Solidity. |
| `cyclomatic-complexity` | 1 | Accepted. `CLAMMPool.swap` scores 27. The swap loop is irreducibly branchy (direction, exact-in/out, tick crossing, limit hit, protocol fee). Splitting it would push locals across a call boundary and worsen stack pressure under via-IR. |
| `low-level-calls` | 1 | Accepted. `Multicall`'s `delegatecall` — required for batching. |
| `naming-convention` | 1 | Accepted. `_owner` parameter in `setOwner`, matching the storage variable it assigns. |

---

## What static analysis does not cover

Slither finds none of the bugs this protocol is actually most at risk from. The
following are covered by tests, not by the tool:

- **Rounding direction.** Every division is directed against the caller. Asserted
  by round-trip mint→burn tests that require the position to lose ≤ 1 wei, and by
  the solvency invariant.
- **Tick bitmap correctness.** An off-by-one in `nextInitializedTickWithinOneWord`
  silently skips liquidity rather than reverting. Covered in `test/Math.t.sol`.
- **Fee-growth accounting across tick crossings.** The `feeGrowthInside`
  subtraction relies on deliberate `uint256` underflow; the wrap is correct but
  unprovable statically. Covered in `test/Pool.t.sol`.
- **Protocol solvency.** `test/Invariant.t.sol` runs randomised
  mint/swap/flash/burn sequences (64 runs × 32 calls locally, 256 × 64 in CI),
  then fully exits every position and the protocol fees and asserts the pool
  holds nothing but sub-1e6-wei dust.

## Known improvements

- `_expectedCallbackPool` is a storage variable. The project targets Cancun, so
  `TSTORE`/`TLOAD` would make the guard materially cheaper and auto-clearing.
  Not yet changed because it would need its own gas-snapshot comparison.
- No `forge coverage` numbers. Coverage requires `--ir-minimum`, which fails on
  `NonfungiblePositionManager` with a Yul stack-too-deep — a known limitation of
  coverage instrumentation on via-IR projects.
- Echidna/Medusa property testing would strengthen the invariant suite beyond
  Foundry's bounded sequences.
