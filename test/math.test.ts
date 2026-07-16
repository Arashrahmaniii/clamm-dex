import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { Q96, MIN_TICK, MAX_TICK, MIN_SQRT_RATIO, MAX_SQRT_RATIO } from "./helpers";

describe("Math libraries", () => {
  async function deployFixture() {
    const MathTest = await ethers.getContractFactory("MathTest");
    const math = await MathTest.deploy();
    return { math };
  }

  describe("TickMath.getSqrtRatioAtTick", () => {
    it("returns exactly 2^96 at tick 0", async () => {
      const { math } = await loadFixture(deployFixture);
      expect(await math.getSqrtRatioAtTick(0)).to.equal(Q96);
    });

    it("returns MIN_SQRT_RATIO at MIN_TICK", async () => {
      const { math } = await loadFixture(deployFixture);
      expect(await math.getSqrtRatioAtTick(MIN_TICK)).to.equal(MIN_SQRT_RATIO);
      expect(await math.minSqrtRatio()).to.equal(MIN_SQRT_RATIO);
    });

    it("returns MAX_SQRT_RATIO at MAX_TICK", async () => {
      const { math } = await loadFixture(deployFixture);
      expect(await math.getSqrtRatioAtTick(MAX_TICK)).to.equal(MAX_SQRT_RATIO);
      expect(await math.maxSqrtRatio()).to.equal(MAX_SQRT_RATIO);
    });

    it("reverts for out-of-range ticks", async () => {
      const { math } = await loadFixture(deployFixture);
      await expect(math.getSqrtRatioAtTick(MIN_TICK - 1)).to.be.revertedWith("TickMath: T");
      await expect(math.getSqrtRatioAtTick(MAX_TICK + 1)).to.be.revertedWith("TickMath: T");
    });

    // Tolerance is bounded by the float64 reference computation, not the
    // contract: Math.pow(1.0001, ±887272) itself only carries ~1e-10 precision.
    it("matches the closed-form sqrt(1.0001^tick) * 2^96 within 1e-9 relative error", async () => {
      const { math } = await loadFixture(deployFixture);
      const ticks = [-887272, -500000, -100000, -50000, -1000, -42, -1, 1, 42, 1000, 50000, 100000, 500000, 887272];
      for (const tick of ticks) {
        const actual = await math.getSqrtRatioAtTick(tick);
        const expected = Math.sqrt(Math.pow(1.0001, tick)) * 2 ** 96;
        const relErr = Math.abs(Number(actual) - expected) / expected;
        expect(relErr, `tick ${tick}`).to.be.lessThan(1e-9);
      }
    });

    it("is strictly monotonically increasing across sample ticks", async () => {
      const { math } = await loadFixture(deployFixture);
      const ticks = [-887272, -100000, -1000, -1, 0, 1, 1000, 100000, 887272];
      let prev = 0n;
      for (const tick of ticks) {
        const ratio: bigint = await math.getSqrtRatioAtTick(tick);
        expect(ratio).to.be.greaterThan(prev);
        prev = ratio;
      }
    });
  });

  describe("TickMath.getTickAtSqrtRatio", () => {
    it("returns 0 at 2^96", async () => {
      const { math } = await loadFixture(deployFixture);
      expect(await math.getTickAtSqrtRatio(Q96)).to.equal(0);
    });

    it("reverts below MIN_SQRT_RATIO and at/above MAX_SQRT_RATIO", async () => {
      const { math } = await loadFixture(deployFixture);
      await expect(math.getTickAtSqrtRatio(MIN_SQRT_RATIO - 1n)).to.be.revertedWith("TickMath: R");
      await expect(math.getTickAtSqrtRatio(MAX_SQRT_RATIO)).to.be.revertedWith("TickMath: R");
    });

    it("round-trips getSqrtRatioAtTick for sample ticks", async () => {
      const { math } = await loadFixture(deployFixture);
      const ticks = [-887272, -123456, -60, -1, 0, 1, 60, 123456, 887271];
      for (const tick of ticks) {
        const ratio = await math.getSqrtRatioAtTick(tick);
        expect(await math.getTickAtSqrtRatio(ratio), `tick ${tick}`).to.equal(tick);
      }
    });

    it("returns tick such that ratio(tick) <= input < ratio(tick+1)", async () => {
      const { math } = await loadFixture(deployFixture);
      const samples = [MIN_SQRT_RATIO, Q96 - 1n, Q96 + 1n, Q96 * 2n, MAX_SQRT_RATIO - 1n];
      for (const ratio of samples) {
        const tick: bigint = await math.getTickAtSqrtRatio(ratio);
        expect(await math.getSqrtRatioAtTick(tick)).to.be.lessThanOrEqual(ratio);
        expect(await math.getSqrtRatioAtTick(tick + 1n)).to.be.greaterThan(ratio);
      }
    });
  });

  describe("FullMath.mulDiv", () => {
    it("computes without phantom-overflow loss", async () => {
      const { math } = await loadFixture(deployFixture);
      // (2^200 * 2^100) / 2^150 = 2^150 — intermediate overflows 256 bits.
      expect(await math.mulDiv(2n ** 200n, 2n ** 100n, 2n ** 150n)).to.equal(2n ** 150n);
    });

    it("matches exact bigint arithmetic on random-ish values", async () => {
      const { math } = await loadFixture(deployFixture);
      const cases: Array<[bigint, bigint, bigint]> = [
        [123456789n * 10n ** 18n, 987654321n * 10n ** 18n, 10n ** 18n],
        [2n ** 255n - 1n, 2n, 2n ** 200n],
        [7n, 3n, 2n],
      ];
      for (const [a, b, d] of cases) {
        expect(await math.mulDiv(a, b, d)).to.equal((a * b) / d);
        const floor = (a * b) / d;
        const expectedUp = (a * b) % d > 0n ? floor + 1n : floor;
        expect(await math.mulDivRoundingUp(a, b, d)).to.equal(expectedUp);
      }
    });

    it("reverts on zero denominator and on overflowing result", async () => {
      const { math } = await loadFixture(deployFixture);
      await expect(math.mulDiv(1n, 1n, 0n)).to.be.reverted;
      await expect(math.mulDiv(2n ** 255n, 4n, 2n)).to.be.reverted;
    });
  });

  describe("SqrtPriceMath", () => {
    it("moves price down for zeroForOne input and up for oneForZero input", async () => {
      const { math } = await loadFixture(deployFixture);
      const price = Q96;
      const liquidity = 10n ** 18n;
      const amount = 10n ** 15n;
      const down = await math.getNextSqrtPriceFromInput(price, liquidity, amount, true);
      const up = await math.getNextSqrtPriceFromInput(price, liquidity, amount, false);
      expect(down).to.be.lessThan(price);
      expect(up).to.be.greaterThan(price);
    });

    it("amount deltas round in the pool's favour", async () => {
      const { math } = await loadFixture(deployFixture);
      const a = Q96;
      const b = (Q96 * 101n) / 100n;
      const liquidity = 10n ** 18n;
      const up0 = await math.getAmount0Delta(a, b, liquidity, true);
      const down0 = await math.getAmount0Delta(a, b, liquidity, false);
      const up1 = await math.getAmount1Delta(a, b, liquidity, true);
      const down1 = await math.getAmount1Delta(a, b, liquidity, false);
      expect(up0).to.be.greaterThanOrEqual(down0);
      expect(up1).to.be.greaterThanOrEqual(down1);
      expect(up0 - down0).to.be.lessThanOrEqual(1n);
      expect(up1 - down1).to.be.lessThanOrEqual(1n);
    });
  });

  describe("SwapMath.computeSwapStep", () => {
    it("charges exactly the fee on an exact-input step that hits the target", async () => {
      const { math } = await loadFixture(deployFixture);
      const price = Q96;
      const target = (Q96 * 101n) / 100n; // +1% price target, oneForZero
      const liquidity = 2n * 10n ** 18n;
      const amount = 10n ** 18n;
      const feePips = 600n;

      const [sqrtQ, amountIn, amountOut, feeAmount] = await math.computeSwapStep(
        price,
        target,
        liquidity,
        amount,
        feePips
      );

      expect(sqrtQ).to.equal(target); // enough input to reach the target
      // Fee is amountIn * fee / (1e6 - fee), rounded up.
      const expectedFee = (amountIn * feePips + (10n ** 6n - feePips) - 1n) / (10n ** 6n - feePips);
      expect(feeAmount).to.equal(expectedFee);
      expect(amountIn + feeAmount).to.be.lessThanOrEqual(amount);
      expect(amountOut).to.be.greaterThan(0n);
    });

    it("consumes the entire input when the target is not reached", async () => {
      const { math } = await loadFixture(deployFixture);
      const price = Q96;
      const target = (Q96 * 2n); // far away
      const liquidity = 10n ** 24n;
      const amount = 10n ** 18n;
      const feePips = 3000n;

      const [sqrtQ, amountIn, , feeAmount] = await math.computeSwapStep(price, target, liquidity, amount, feePips);
      expect(sqrtQ).to.be.lessThan(target);
      expect(amountIn + feeAmount).to.equal(amount); // everything consumed
    });
  });
});
