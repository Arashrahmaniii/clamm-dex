import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import {
  Q96,
  FeeAmount,
  TICK_SPACINGS,
  MIN_SQRT_RATIO,
  MAX_SQRT_RATIO,
  encodePriceSqrt,
  getPositionKey,
} from "./helpers";

const SPACING = TICK_SPACINGS[FeeAmount.MEDIUM];
const LOWER = -60 * 10; // -600
const UPPER = 60 * 10; //  600
const LIQUIDITY = 10n ** 18n;
const INITIAL_BALANCE = 10n ** 24n;

describe("CLAMMFactory & CLAMMPool", () => {
  async function deployFixture() {
    const [deployer, lp, trader, other] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("CLAMMFactory");
    const factory = await Factory.deploy();

    const Token = await ethers.getContractFactory("TestERC20");
    const tokenA = await Token.deploy("Token A", "TKA");
    const tokenB = await Token.deploy("Token B", "TKB");
    const [token0, token1] =
      (await tokenA.getAddress()).toLowerCase() < (await tokenB.getAddress()).toLowerCase()
        ? [tokenA, tokenB]
        : [tokenB, tokenA];

    await factory.createPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM);
    const poolAddress = await factory.getPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM);
    const pool = await ethers.getContractAt("CLAMMPool", poolAddress);

    const Callee = await ethers.getContractFactory("PoolTestCallee");
    const callee = await Callee.deploy();

    for (const user of [lp, trader, other]) {
      await token0.mint(user.address, INITIAL_BALANCE);
      await token1.mint(user.address, INITIAL_BALANCE);
      await token0.connect(user).approve(callee.getAddress(), ethers.MaxUint256);
      await token1.connect(user).approve(callee.getAddress(), ethers.MaxUint256);
    }

    return { deployer, lp, trader, other, factory, token0, token1, pool, callee };
  }

  async function initializedPoolFixture() {
    const state = await deployFixture();
    await state.pool.initialize(Q96); // price = 1
    return state;
  }

  async function poolWithLiquidityFixture() {
    const state = await initializedPoolFixture();
    const { callee, pool, lp } = state;
    await callee.connect(lp).mint(pool.getAddress(), lp.address, LOWER, UPPER, LIQUIDITY);
    return state;
  }

  describe("factory", () => {
    it("deploys pools with the canonical fee tiers enabled", async () => {
      const { factory } = await loadFixture(deployFixture);
      expect(await factory.feeAmountTickSpacing(FeeAmount.LOW)).to.equal(10);
      expect(await factory.feeAmountTickSpacing(FeeAmount.MEDIUM)).to.equal(60);
      expect(await factory.feeAmountTickSpacing(FeeAmount.HIGH)).to.equal(200);
    });

    it("stores the pool under both token orderings", async () => {
      const { factory, token0, token1, pool } = await loadFixture(deployFixture);
      expect(await factory.getPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM)).to.equal(
        await pool.getAddress()
      );
      expect(await factory.getPool(token1.getAddress(), token0.getAddress(), FeeAmount.MEDIUM)).to.equal(
        await pool.getAddress()
      );
    });

    it("rejects duplicate pools, identical tokens and disabled fees", async () => {
      const { factory, token0, token1 } = await loadFixture(deployFixture);
      await expect(
        factory.createPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM)
      ).to.be.revertedWith("CLAMMFactory: POOL_EXISTS");
      await expect(
        factory.createPool(token0.getAddress(), token0.getAddress(), FeeAmount.MEDIUM)
      ).to.be.revertedWith("CLAMMFactory: SAME_TOKEN");
      await expect(factory.createPool(token0.getAddress(), token1.getAddress(), 1234)).to.be.revertedWith(
        "CLAMMFactory: FEE_NOT_ENABLED"
      );
    });

    it("only lets the owner enable fee amounts and transfer ownership", async () => {
      const { factory, other } = await loadFixture(deployFixture);
      await expect(factory.connect(other).enableFeeAmount(100, 1)).to.be.revertedWith("CLAMMFactory: NOT_OWNER");
      await expect(factory.connect(other).setOwner(other.address)).to.be.revertedWith("CLAMMFactory: NOT_OWNER");
      await factory.enableFeeAmount(100, 1);
      expect(await factory.feeAmountTickSpacing(100)).to.equal(1);
      await expect(factory.enableFeeAmount(100, 2)).to.be.revertedWith("CLAMMFactory: FEE_ALREADY_ENABLED");
    });

    it("configures the pool immutables correctly", async () => {
      const { pool, factory, token0, token1 } = await loadFixture(deployFixture);
      expect(await pool.factory()).to.equal(await factory.getAddress());
      expect(await pool.token0()).to.equal(await token0.getAddress());
      expect(await pool.token1()).to.equal(await token1.getAddress());
      expect(await pool.fee()).to.equal(FeeAmount.MEDIUM);
      expect(await pool.tickSpacing()).to.equal(SPACING);
      expect(await pool.maxLiquidityPerTick()).to.be.greaterThan(0n);
    });
  });

  describe("initialize", () => {
    it("sets price and tick, and can only run once", async () => {
      const { pool } = await loadFixture(deployFixture);
      await expect(pool.initialize(Q96)).to.emit(pool, "Initialize").withArgs(Q96, 0);
      const slot0 = await pool.slot0();
      expect(slot0.sqrtPriceX96).to.equal(Q96);
      expect(slot0.tick).to.equal(0);
      expect(slot0.unlocked).to.equal(true);
      await expect(pool.initialize(Q96)).to.be.revertedWith("CLAMMPool: AI");
    });

    it("derives the tick from a non-unity price", async () => {
      const { pool } = await loadFixture(deployFixture);
      const price = encodePriceSqrt(4n, 1n); // price 4 => tick ~ ln(4)/ln(1.0001) ≈ 13862.94
      await pool.initialize(price);
      const slot0 = await pool.slot0();
      // The tick satisfies the implementation invariant ratio(tick) <= price < ratio(tick + 1).
      const math = await (await ethers.getContractFactory("MathTest")).deploy();
      expect(await math.getSqrtRatioAtTick(slot0.tick)).to.be.lessThanOrEqual(price);
      expect(await math.getSqrtRatioAtTick(slot0.tick + 1n)).to.be.greaterThan(price);
      expect([13862n, 13863n]).to.include(slot0.tick);
    });

    it("blocks actions before initialization via the lock", async () => {
      const { pool, callee, lp } = await loadFixture(deployFixture);
      await expect(
        callee.connect(lp).mint(pool.getAddress(), lp.address, LOWER, UPPER, LIQUIDITY)
      ).to.be.revertedWith("CLAMMPool: LOK");
    });
  });

  describe("mint", () => {
    it("takes both tokens for an in-range position and records liquidity", async () => {
      const { pool, callee, lp, token0, token1 } = await loadFixture(initializedPoolFixture);

      const bal0Before = await token0.balanceOf(lp.address);
      const bal1Before = await token1.balanceOf(lp.address);
      await callee.connect(lp).mint(pool.getAddress(), lp.address, LOWER, UPPER, LIQUIDITY);
      const paid0 = bal0Before - (await token0.balanceOf(lp.address));
      const paid1 = bal1Before - (await token1.balanceOf(lp.address));

      // Symmetric range around price 1: both amounts equal.
      expect(paid0).to.be.greaterThan(0n);
      expect(paid0).to.equal(paid1);
      expect(await pool.liquidity()).to.equal(LIQUIDITY);

      const position = await pool.positions(getPositionKey(lp.address, LOWER, UPPER));
      expect(position.liquidity).to.equal(LIQUIDITY);
    });

    it("takes only token0 above range and only token1 below range", async () => {
      const { pool, callee, lp, token0, token1 } = await loadFixture(initializedPoolFixture);

      const bal0 = await token0.balanceOf(lp.address);
      const bal1 = await token1.balanceOf(lp.address);
      await callee.connect(lp).mint(pool.getAddress(), lp.address, 60, 120, LIQUIDITY); // above current price
      expect(bal0 - (await token0.balanceOf(lp.address))).to.be.greaterThan(0n);
      expect(bal1 - (await token1.balanceOf(lp.address))).to.equal(0n);

      const bal0b = await token0.balanceOf(lp.address);
      const bal1b = await token1.balanceOf(lp.address);
      await callee.connect(lp).mint(pool.getAddress(), lp.address, -120, -60, LIQUIDITY); // below current price
      expect(bal0b - (await token0.balanceOf(lp.address))).to.equal(0n);
      expect(bal1b - (await token1.balanceOf(lp.address))).to.be.greaterThan(0n);

      // Neither out-of-range position adds active liquidity.
      expect(await pool.liquidity()).to.equal(0n);
    });

    it("rejects invalid tick ranges and zero liquidity", async () => {
      const { pool, callee, lp } = await loadFixture(initializedPoolFixture);
      const p = pool.getAddress();
      await expect(callee.connect(lp).mint(p, lp.address, UPPER, LOWER, LIQUIDITY)).to.be.revertedWith(
        "CLAMMPool: TLU"
      );
      await expect(callee.connect(lp).mint(p, lp.address, -887280, UPPER, LIQUIDITY)).to.be.revertedWith(
        "CLAMMPool: TLM"
      );
      await expect(callee.connect(lp).mint(p, lp.address, LOWER, 887280, LIQUIDITY)).to.be.revertedWith(
        "CLAMMPool: TUM"
      );
      await expect(callee.connect(lp).mint(p, lp.address, LOWER, UPPER, 0)).to.be.revertedWith(
        "CLAMMPool: ZERO_LIQUIDITY"
      );
      await expect(callee.connect(lp).mint(p, lp.address, LOWER + 1, UPPER, LIQUIDITY)).to.be.revertedWith(
        "TickBitmap: TS"
      );
    });
  });

  describe("swap", () => {
    it("executes an exact-input zeroForOne swap and moves price down", async () => {
      const { pool, callee, trader, token0, token1 } = await loadFixture(poolWithLiquidityFixture);
      const amountIn = 10n ** 15n;

      const bal0 = await token0.balanceOf(trader.address);
      const bal1 = await token1.balanceOf(trader.address);
      await callee
        .connect(trader)
        .swap(pool.getAddress(), trader.address, true, amountIn, MIN_SQRT_RATIO + 1n);

      const spent0 = bal0 - (await token0.balanceOf(trader.address));
      const received1 = (await token1.balanceOf(trader.address)) - bal1;
      expect(spent0).to.equal(amountIn);
      expect(received1).to.be.greaterThan(0n);
      expect(received1).to.be.lessThan(amountIn); // fee + price impact at price 1

      const slot0 = await pool.slot0();
      expect(slot0.sqrtPriceX96).to.be.lessThan(Q96);
      expect(slot0.tick).to.be.lessThan(0);
    });

    it("executes an exact-output oneForZero swap", async () => {
      const { pool, callee, trader, token0 } = await loadFixture(poolWithLiquidityFixture);
      const amountOut = 10n ** 15n;

      const bal0 = await token0.balanceOf(trader.address);
      await callee
        .connect(trader)
        .swap(pool.getAddress(), trader.address, false, -amountOut, MAX_SQRT_RATIO - 1n);
      const received0 = (await token0.balanceOf(trader.address)) - bal0;
      expect(received0).to.equal(amountOut);

      const slot0 = await pool.slot0();
      expect(slot0.sqrtPriceX96).to.be.greaterThan(Q96);
    });

    it("stops exactly at the price limit and returns the partial fill", async () => {
      const { pool, callee, trader } = await loadFixture(poolWithLiquidityFixture);
      const limit = (Q96 * 999n) / 1000n; // allow only ~0.1% price move down
      const hugeAmount = 10n ** 21n;

      await callee.connect(trader).swap(pool.getAddress(), trader.address, true, hugeAmount, limit);
      const slot0 = await pool.slot0();
      expect(slot0.sqrtPriceX96).to.equal(limit);
    });

    it("crosses an initialized tick and deactivates out-of-range liquidity", async () => {
      const { pool, callee, trader, lp } = await loadFixture(poolWithLiquidityFixture);
      // A second, narrower position that the price will exit.
      await callee.connect(lp).mint(pool.getAddress(), lp.address, -60, 60, LIQUIDITY);
      expect(await pool.liquidity()).to.equal(2n * LIQUIDITY);

      // Swap enough to push the tick below -60.
      await callee
        .connect(trader)
        .swap(pool.getAddress(), trader.address, true, 10n ** 16n, MIN_SQRT_RATIO + 1n);

      const slot0 = await pool.slot0();
      expect(slot0.tick).to.be.lessThan(-60);
      // Only the wide position remains active.
      expect(await pool.liquidity()).to.equal(LIQUIDITY);
    });

    it("rejects swaps with a bad price limit or zero amount", async () => {
      const { pool, callee, trader } = await loadFixture(poolWithLiquidityFixture);
      const p = pool.getAddress();
      await expect(callee.connect(trader).swap(p, trader.address, true, 1000n, 0n)).to.be.revertedWith(
        "CLAMMPool: SPL"
      );
      await expect(
        callee.connect(trader).swap(p, trader.address, true, 1000n, Q96 + 1n) // limit above current for zeroForOne
      ).to.be.revertedWith("CLAMMPool: SPL");
      await expect(callee.connect(trader).swap(p, trader.address, true, 0n, MIN_SQRT_RATIO + 1n)).to.be.revertedWith(
        "CLAMMPool: AS"
      );
    });
  });

  describe("fees", () => {
    it("accrues swap fees to in-range LPs, collectable after a poke", async () => {
      const { pool, callee, trader, lp, token0 } = await loadFixture(poolWithLiquidityFixture);
      const amountIn = 10n ** 16n;

      await callee.connect(trader).swap(pool.getAddress(), trader.address, true, amountIn, MIN_SQRT_RATIO + 1n);
      expect(await pool.feeGrowthGlobal0X128()).to.be.greaterThan(0n);

      // Poke (burn 0 is disallowed; burn a negligible amount to update fee accounting).
      await pool.connect(lp).burn(LOWER, UPPER, 1n);
      const position = await pool.positions(getPositionKey(lp.address, LOWER, UPPER));

      // ~0.3% of the input, minus rounding.
      const expectedFee = (amountIn * 3000n) / 1_000_000n;
      expect(position.tokensOwed0).to.be.greaterThanOrEqual((expectedFee * 99n) / 100n);
      expect(position.tokensOwed0).to.be.lessThanOrEqual(expectedFee + 1n);

      const balBefore = await token0.balanceOf(lp.address);
      await pool.connect(lp).collect(lp.address, LOWER, UPPER, ethers.MaxUint256 & ((1n << 128n) - 1n), 0n);
      expect((await token0.balanceOf(lp.address)) - balBefore).to.equal(position.tokensOwed0);
    });

    it("routes the protocol share to protocolFees when enabled", async () => {
      const { pool, callee, trader, deployer } = await loadFixture(poolWithLiquidityFixture);
      await pool.connect(deployer).setFeeProtocol(4, 4); // 1/4 of fees to protocol

      await callee.connect(trader).swap(pool.getAddress(), trader.address, true, 10n ** 16n, MIN_SQRT_RATIO + 1n);

      const fees = await pool.protocolFees();
      expect(fees.token0).to.be.greaterThan(0n);
      expect(fees.token1).to.equal(0n);

      // Only the factory owner can collect; one wei stays behind for gas efficiency.
      const collected = fees.token0 - 1n;
      await expect(pool.connect(deployer).collectProtocol(deployer.address, fees.token0, 0n))
        .to.emit(pool, "CollectProtocol")
        .withArgs(deployer.address, deployer.address, collected, 0n);
    });

    it("restricts protocol fee configuration to the factory owner and valid values", async () => {
      const { pool, other, deployer } = await loadFixture(poolWithLiquidityFixture);
      await expect(pool.connect(other).setFeeProtocol(4, 4)).to.be.revertedWith("CLAMMPool: NOT_OWNER");
      await expect(pool.connect(other).collectProtocol(other.address, 1n, 1n)).to.be.revertedWith(
        "CLAMMPool: NOT_OWNER"
      );
      await expect(pool.connect(deployer).setFeeProtocol(3, 4)).to.be.revertedWith("CLAMMPool: FP");
      await expect(pool.connect(deployer).setFeeProtocol(11, 4)).to.be.revertedWith("CLAMMPool: FP");
      await pool.connect(deployer).setFeeProtocol(0, 10); // disabling / max are both fine
    });
  });

  describe("burn & collect", () => {
    it("returns principal (minus rounding) after burning the full position", async () => {
      const { pool, callee, lp, token0, token1 } = await loadFixture(initializedPoolFixture);

      const bal0 = await token0.balanceOf(lp.address);
      const bal1 = await token1.balanceOf(lp.address);
      await callee.connect(lp).mint(pool.getAddress(), lp.address, LOWER, UPPER, LIQUIDITY);
      const paid0 = bal0 - (await token0.balanceOf(lp.address));
      const paid1 = bal1 - (await token1.balanceOf(lp.address));

      await pool.connect(lp).burn(LOWER, UPPER, LIQUIDITY);
      const position = await pool.positions(getPositionKey(lp.address, LOWER, UPPER));
      expect(position.liquidity).to.equal(0n);
      // Owed amounts equal the principal minus at most 1 wei rounding in the pool's favour.
      expect(paid0 - position.tokensOwed0).to.be.lessThanOrEqual(1n);
      expect(paid1 - position.tokensOwed1).to.be.lessThanOrEqual(1n);

      await pool.connect(lp).collect(lp.address, LOWER, UPPER, position.tokensOwed0, position.tokensOwed1);
      expect(await pool.liquidity()).to.equal(0n);
    });

    it("cannot burn more than the position's liquidity", async () => {
      const { pool, lp } = await loadFixture(poolWithLiquidityFixture);
      await expect(pool.connect(lp).burn(LOWER, UPPER, LIQUIDITY + 1n)).to.be.reverted;
    });

    it("collect caps at what is owed and pays the requested recipient", async () => {
      const { pool, lp, other, token0 } = await loadFixture(poolWithLiquidityFixture);
      await pool.connect(lp).burn(LOWER, UPPER, LIQUIDITY / 2n);
      const position = await pool.positions(getPositionKey(lp.address, LOWER, UPPER));

      const balBefore = await token0.balanceOf(other.address);
      await pool
        .connect(lp)
        .collect(other.address, LOWER, UPPER, position.tokensOwed0 + 10n ** 18n, 0n);
      expect((await token0.balanceOf(other.address)) - balBefore).to.equal(position.tokensOwed0);
    });
  });

  describe("flash", () => {
    it("lends both tokens and takes the fee, growing feeGrowthGlobal", async () => {
      const { pool, callee, trader, token0 } = await loadFixture(poolWithLiquidityFixture);
      const amount = 10n ** 15n;
      const poolBal0Before = await token0.balanceOf(pool.getAddress());

      await expect(callee.connect(trader).flash(pool.getAddress(), callee.getAddress(), amount, amount)).to.emit(
        pool,
        "Flash"
      );

      // The pool ends up richer by the fee.
      expect(await token0.balanceOf(pool.getAddress())).to.be.greaterThan(poolBal0Before);
      expect(await pool.feeGrowthGlobal0X128()).to.be.greaterThan(0n);
      expect(await pool.feeGrowthGlobal1X128()).to.be.greaterThan(0n);
    });

    it("reverts when there is no liquidity", async () => {
      const { pool, callee, trader } = await loadFixture(initializedPoolFixture);
      await expect(
        callee.connect(trader).flash(pool.getAddress(), callee.getAddress(), 1000n, 0n)
      ).to.be.revertedWith("CLAMMPool: L");
    });
  });
});
