import { expect } from "chai";
import { ethers } from "hardhat";
import { MAX_SQRT_RATIO, MIN_SQRT_RATIO, FeeAmount, TICK_SPACINGS } from "./helpers";

/**
 * Randomized (but deterministic, seeded) solvency test.
 *
 * Runs a session of random mints, swaps, flashes and partial burns against a
 * pool, then exits every position and collects everything including protocol
 * fees. The pool must survive the full exit without a failed transfer (which
 * would mean its accounting credited more than it holds) and be left with only
 * rounding dust, all of it in the pool's favour.
 */

const U256 = 2n ** 256n;
const MAX_UINT128 = 2n ** 128n - 1n;

function makeRng(seedInit: bigint) {
  let seed = seedInit;
  const rnd = (): bigint => {
    seed = (seed * 6364136223846793005n + 1442695040888963407n) % U256;
    return seed >> 16n;
  };
  const range = (lo: bigint, hi: bigint): bigint => lo + (rnd() % (hi - lo + 1n));
  const int = (lo: number, hi: number): number => Number(range(BigInt(lo), BigInt(hi)));
  return { rnd, range, int };
}

const ACTIONS = 60;
const SEEDS = [42n, 7n];

describe("pool solvency invariant", () => {
  for (const seed of SEEDS) {
    it(`survives a random session and full exit (seed ${seed})`, async () => {
      const { rnd, range, int } = makeRng(seed);
      const [owner] = await ethers.getSigners();

      const Token = await ethers.getContractFactory("TestERC20");
      const tokenA = await Token.deploy("A", "A");
      const tokenB = await Token.deploy("B", "B");
      const [token0, token1] =
        (await tokenA.getAddress()).toLowerCase() < (await tokenB.getAddress()).toLowerCase()
          ? [tokenA, tokenB]
          : [tokenB, tokenA];

      const factory = await (await ethers.getContractFactory("CLAMMFactory")).deploy();
      const spacing = TICK_SPACINGS[FeeAmount.MEDIUM];
      await factory.createPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM);
      const poolAddr = await factory.getPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM);
      const pool = await ethers.getContractAt("CLAMMPool", poolAddr);

      const callee = await (await ethers.getContractFactory("PoolTestCallee")).deploy();

      const supply = 2n ** 120n;
      await token0.mint(owner.address, supply);
      await token1.mint(owner.address, supply);
      await token0.approve(callee.getAddress(), supply);
      await token1.approve(callee.getAddress(), supply);

      // Random initial price within ±40 powers of two around 1.
      const shift = int(-40, 40);
      const initPrice = shift >= 0 ? 2n ** 96n << BigInt(shift) : 2n ** 96n >> BigInt(-shift);
      await pool.initialize(initPrice);

      if (rnd() % 2n === 0n) {
        await pool.setFeeProtocol(int(4, 10), int(4, 10));
      }

      type Pos = { tickLower: number; tickUpper: number; liq: bigint };
      const positions: Pos[] = [];

      for (let i = 0; i < ACTIONS; i++) {
        const action = int(0, 9);
        try {
          if (action <= 2 || positions.length === 0) {
            const lo = int(-800, 799) * spacing;
            const hi = int(Math.floor(lo / spacing) + 1, 800) * spacing;
            const liq = range(10n ** 6n, 10n ** 21n);
            await callee.mint(poolAddr, owner.address, lo, hi, liq);
            positions.push({ tickLower: lo, tickUpper: hi, liq });
          } else if (action <= 6) {
            const zeroForOne = rnd() % 2n === 0n;
            const exactIn = rnd() % 2n === 0n;
            const amt = range(10n ** 3n, 10n ** 19n);
            const limit = zeroForOne ? MIN_SQRT_RATIO + 1n : MAX_SQRT_RATIO - 1n;
            await callee.swap(poolAddr, owner.address, zeroForOne, exactIn ? amt : -amt, limit);
          } else if (action === 7) {
            await callee.flash(poolAddr, callee.getAddress(), range(0n, 10n ** 15n), range(0n, 10n ** 15n));
          } else {
            const p = positions[int(0, positions.length - 1)];
            if (p.liq > 1n) {
              const part = range(1n, p.liq);
              await pool.burn(p.tickLower, p.tickUpper, part);
              p.liq -= part;
            }
          }
        } catch {
          // Some random actions legitimately revert (swapping past all
          // liquidity, flashing an empty pool, ...); the invariant is about
          // the exit below, not about every action landing.
        }
      }

      // Merge duplicate ranges: the pool keys positions by (owner, range).
      const byKey = new Map<string, Pos>();
      for (const p of positions) {
        const k = `${p.tickLower}:${p.tickUpper}`;
        const cur = byKey.get(k);
        if (cur) cur.liq += p.liq;
        else byKey.set(k, { ...p });
      }

      // Full exit: every burn, collect and protocol collect must succeed.
      for (const p of byKey.values()) {
        if (p.liq > 0n) {
          await pool.burn(p.tickLower, p.tickUpper, p.liq);
        }
        await pool.collect(owner.address, p.tickLower, p.tickUpper, MAX_UINT128, MAX_UINT128);
      }
      await pool.collectProtocol(owner.address, MAX_UINT128, MAX_UINT128);

      expect(await pool.liquidity()).to.equal(0n);

      // Whatever remains is rounding dust in the pool's favour (plus the one
      // wei per token collectProtocol leaves to keep its slot warm).
      const dustLimit = 10n ** 6n;
      expect(await token0.balanceOf(poolAddr)).to.be.lessThanOrEqual(dustLimit);
      expect(await token1.balanceOf(poolAddr)).to.be.lessThanOrEqual(dustLimit);
    });
  }
});
