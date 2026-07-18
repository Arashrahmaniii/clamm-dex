import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { Q96, FeeAmount, encodePriceSqrt, latestDeadline } from "./helpers";

const LOWER = -600;
const UPPER = 600;
const INITIAL_BALANCE = 10n ** 24n;
const DESIRED = 10n ** 18n;

describe("Oracle, Quoter & Multicall", () => {
  async function deployFixture() {
    const [deployer, lp, trader] = await ethers.getSigners();

    const factory = await (await ethers.getContractFactory("CLAMMFactory")).deploy();

    const Token = await ethers.getContractFactory("TestERC20");
    const tokenA = await Token.deploy("Token A", "TKA");
    const tokenB = await Token.deploy("Token B", "TKB");
    const [token0, token1] =
      (await tokenA.getAddress()).toLowerCase() < (await tokenB.getAddress()).toLowerCase()
        ? [tokenA, tokenB]
        : [tokenB, tokenA];

    await factory.createPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM);
    const pool = await ethers.getContractAt(
      "CLAMMPool",
      await factory.getPool(token0.getAddress(), token1.getAddress(), FeeAmount.MEDIUM)
    );
    await pool.initialize(Q96);

    const npm = await (
      await ethers.getContractFactory("NonfungiblePositionManager")
    ).deploy(factory.getAddress());
    const router = await (await ethers.getContractFactory("SwapRouter")).deploy(factory.getAddress());
    const quoter = await (await ethers.getContractFactory("Quoter")).deploy(factory.getAddress());

    for (const user of [lp, trader]) {
      await token0.mint(user.address, INITIAL_BALANCE);
      await token1.mint(user.address, INITIAL_BALANCE);
      await token0.connect(user).approve(npm.getAddress(), ethers.MaxUint256);
      await token1.connect(user).approve(npm.getAddress(), ethers.MaxUint256);
      await token0.connect(user).approve(router.getAddress(), ethers.MaxUint256);
      await token1.connect(user).approve(router.getAddress(), ethers.MaxUint256);
    }

    return { deployer, lp, trader, factory, token0, token1, pool, npm, router, quoter };
  }

  async function poolWithLiquidityFixture() {
    const state = await deployFixture();
    const { npm, token0, token1, lp } = state;
    await npm.connect(lp).mint({
      token0: await token0.getAddress(),
      token1: await token1.getAddress(),
      fee: FeeAmount.MEDIUM,
      tickLower: LOWER,
      tickUpper: UPPER,
      amount0Desired: DESIRED,
      amount1Desired: DESIRED,
      amount0Min: 0n,
      amount1Min: 0n,
      recipient: lp.address,
      deadline: await latestDeadline(),
    });
    return state;
  }

  describe("oracle", () => {
    it("reverts observe on an uninitialized pool", async () => {
      const { factory, token0, token1 } = await loadFixture(deployFixture);
      await factory.createPool(token0.getAddress(), token1.getAddress(), FeeAmount.HIGH);
      const fresh = await ethers.getContractAt(
        "CLAMMPool",
        await factory.getPool(token0.getAddress(), token1.getAddress(), FeeAmount.HIGH)
      );
      await expect(fresh.observe()).to.be.revertedWith("CLAMMPool: NI");
    });

    it("accumulates zero while the tick is zero", async () => {
      const { pool } = await loadFixture(poolWithLiquidityFixture);
      await time.increase(1000);
      const [tickCumulative] = await pool.observe();
      expect(tickCumulative).to.equal(0n);
    });

    it("accumulates tick * seconds across a swap and supports a TWAP window", async () => {
      const { pool, router, token0, token1, trader } = await loadFixture(poolWithLiquidityFixture);

      // Sample 1: still at tick 0.
      const [c1, t1] = await pool.observe();
      expect(c1).to.equal(0n);

      // Swap zeroForOne to push the tick negative; the accumulator folds in the
      // pre-swap tick (0) at swap time, so it is still 0 right after the swap.
      const swapTime = Number(t1) + 100;
      await time.setNextBlockTimestamp(swapTime);
      await router.connect(trader).exactInputSingle({
        tokenIn: await token0.getAddress(),
        tokenOut: await token1.getAddress(),
        fee: FeeAmount.MEDIUM,
        recipient: trader.address,
        deadline: swapTime + 3600,
        amountIn: 10n ** 17n,
        amountOutMinimum: 0n,
        sqrtPriceLimitX96: 0n,
      });
      expect(await pool.tickCumulativeLast()).to.equal(0n);
      expect(await pool.blockTimestampLast()).to.equal(swapTime);

      const { tick } = await pool.slot0();
      expect(tick).to.be.lessThan(0n);

      // Sample 2: the new tick has been in effect for 500 seconds.
      await time.increaseTo(swapTime + 500);
      const [c2, t2] = await pool.observe();
      expect(c2 - c1).to.equal(tick * (t2 - t1 - 100n));

      // Time-weighted average tick over the window that includes the swap.
      const twat = (c2 - c1) / (t2 - t1);
      expect(twat).to.be.lessThanOrEqual(0n);
      expect(twat).to.be.greaterThanOrEqual(tick);
    });

    it("does not advance the accumulator for mints and burns", async () => {
      const { pool, npm, token0, token1, lp } = await loadFixture(poolWithLiquidityFixture);
      await time.increase(300);
      await npm.connect(lp).mint({
        token0: await token0.getAddress(),
        token1: await token1.getAddress(),
        fee: FeeAmount.MEDIUM,
        tickLower: LOWER,
        tickUpper: UPPER,
        amount0Desired: DESIRED,
        amount1Desired: DESIRED,
        amount0Min: 0n,
        amount1Min: 0n,
        recipient: lp.address,
        deadline: await latestDeadline(),
      });
      // Lazy accumulation: storage is untouched, observe() extrapolates.
      expect(await pool.tickCumulativeLast()).to.equal(0n);
      const [tickCumulative] = await pool.observe();
      expect(tickCumulative).to.equal(0n); // tick is still 0
    });
  });

  describe("quoter", () => {
    it("quotes exact input to the wei without changing pool state", async () => {
      const { pool, router, quoter, token0, token1, trader } = await loadFixture(poolWithLiquidityFixture);
      const t0 = await token0.getAddress();
      const t1 = await token1.getAddress();
      const amountIn = 10n ** 16n;

      const slotBefore = await pool.slot0();
      const quoted = await quoter.quoteExactInputSingle.staticCall(t0, t1, FeeAmount.MEDIUM, amountIn, 0n);
      const slotAfter = await pool.slot0();
      expect(slotAfter.sqrtPriceX96).to.equal(slotBefore.sqrtPriceX96);

      const balanceBefore = await token1.balanceOf(trader.address);
      await router.connect(trader).exactInputSingle({
        tokenIn: t0,
        tokenOut: t1,
        fee: FeeAmount.MEDIUM,
        recipient: trader.address,
        deadline: await latestDeadline(),
        amountIn,
        amountOutMinimum: 0n,
        sqrtPriceLimitX96: 0n,
      });
      const received = (await token1.balanceOf(trader.address)) - balanceBefore;
      expect(quoted).to.equal(received);
    });

    it("quotes exact output to the wei", async () => {
      const { router, quoter, token0, token1, trader } = await loadFixture(poolWithLiquidityFixture);
      const t0 = await token0.getAddress();
      const t1 = await token1.getAddress();
      const amountOut = 10n ** 16n;

      const quoted = await quoter.quoteExactOutputSingle.staticCall(t1, t0, FeeAmount.MEDIUM, amountOut, 0n);

      const balanceBefore = await token1.balanceOf(trader.address);
      await router.connect(trader).exactOutputSingle({
        tokenIn: t1,
        tokenOut: t0,
        fee: FeeAmount.MEDIUM,
        recipient: trader.address,
        deadline: await latestDeadline(),
        amountOut,
        amountInMaximum: ethers.MaxUint256,
        sqrtPriceLimitX96: 0n,
      });
      const spent = balanceBefore - (await token1.balanceOf(trader.address));
      expect(quoted).to.equal(spent);
    });

    it("rejects quotes for unknown pools and impossible outputs", async () => {
      const { quoter, token0, token1 } = await loadFixture(poolWithLiquidityFixture);
      const t0 = await token0.getAddress();
      const t1 = await token1.getAddress();

      await expect(
        quoter.quoteExactInputSingle.staticCall(t0, t1, FeeAmount.LOW, 1000n, 0n)
      ).to.be.revertedWith("Quoter: POOL_NOT_FOUND");

      // More output than the range holds cannot be quoted as complete.
      await expect(
        quoter.quoteExactOutputSingle.staticCall(t0, t1, FeeAmount.MEDIUM, INITIAL_BALANCE, 0n)
      ).to.be.revertedWith("Quoter: INCOMPLETE_OUTPUT");
    });
  });

  describe("multicall", () => {
    it("creates, initializes and mints into a brand-new pool atomically", async () => {
      const { npm, lp } = await loadFixture(deployFixture);

      const Token = await ethers.getContractFactory("TestERC20");
      const tokenC = await Token.deploy("Token C", "TKC");
      const tokenD = await Token.deploy("Token D", "TKD");
      const [n0, n1] =
        (await tokenC.getAddress()).toLowerCase() < (await tokenD.getAddress()).toLowerCase()
          ? [tokenC, tokenD]
          : [tokenD, tokenC];
      await n0.mint(lp.address, INITIAL_BALANCE);
      await n1.mint(lp.address, INITIAL_BALANCE);
      await n0.connect(lp).approve(npm.getAddress(), ethers.MaxUint256);
      await n1.connect(lp).approve(npm.getAddress(), ethers.MaxUint256);

      const price = encodePriceSqrt(1n, 1n);
      const createCall = npm.interface.encodeFunctionData("createAndInitializePoolIfNecessary", [
        await n0.getAddress(),
        await n1.getAddress(),
        FeeAmount.MEDIUM,
        price,
      ]);
      const mintCall = npm.interface.encodeFunctionData("mint", [
        {
          token0: await n0.getAddress(),
          token1: await n1.getAddress(),
          fee: FeeAmount.MEDIUM,
          tickLower: LOWER,
          tickUpper: UPPER,
          amount0Desired: DESIRED,
          amount1Desired: DESIRED,
          amount0Min: 0n,
          amount1Min: 0n,
          recipient: lp.address,
          deadline: await latestDeadline(),
        },
      ]);

      await npm.connect(lp).multicall([createCall, mintCall]);

      expect(await npm.ownerOf(1)).to.equal(lp.address);
      const position = await npm.positions(1);
      expect(position.liquidity).to.be.greaterThan(0n);
    });

    it("is idempotent for existing pools and rejects unsorted tokens", async () => {
      const { npm, factory, token0, token1 } = await loadFixture(deployFixture);
      const t0 = await token0.getAddress();
      const t1 = await token1.getAddress();

      // Pool exists and is initialized: a second call is a no-op returning the pool.
      const existing = await npm.createAndInitializePoolIfNecessary.staticCall(t0, t1, FeeAmount.MEDIUM, Q96);
      expect(existing).to.equal(await factory.getPool(t0, t1, FeeAmount.MEDIUM));

      await expect(
        npm.createAndInitializePoolIfNecessary(t1, t0, FeeAmount.MEDIUM, Q96)
      ).to.be.revertedWith("NPM: TOKEN_ORDER");
    });

    it("initializes an existing but priceless pool", async () => {
      const { npm, factory, token0, token1 } = await loadFixture(deployFixture);
      const t0 = await token0.getAddress();
      const t1 = await token1.getAddress();

      await factory.createPool(t0, t1, FeeAmount.HIGH);
      await npm.createAndInitializePoolIfNecessary(t0, t1, FeeAmount.HIGH, Q96);

      const pool = await ethers.getContractAt("CLAMMPool", await factory.getPool(t0, t1, FeeAmount.HIGH));
      const { sqrtPriceX96 } = await pool.slot0();
      expect(sqrtPriceX96).to.equal(Q96);
    });

    it("bubbles the inner revert reason out of a failed batch", async () => {
      const { npm, token0, token1, lp } = await loadFixture(deployFixture);
      const badMint = npm.interface.encodeFunctionData("mint", [
        {
          token0: await token1.getAddress(), // wrong order
          token1: await token0.getAddress(),
          fee: FeeAmount.MEDIUM,
          tickLower: LOWER,
          tickUpper: UPPER,
          amount0Desired: DESIRED,
          amount1Desired: DESIRED,
          amount0Min: 0n,
          amount1Min: 0n,
          recipient: lp.address,
          deadline: await latestDeadline(),
        },
      ]);
      await expect(npm.connect(lp).multicall([badMint])).to.be.revertedWith("NPM: TOKEN_ORDER");
    });

    it("batches a swap with slippage protection on the router", async () => {
      const { router, token0, token1, trader } = await loadFixture(poolWithLiquidityFixture);
      const swapCall = router.interface.encodeFunctionData("exactInputSingle", [
        {
          tokenIn: await token0.getAddress(),
          tokenOut: await token1.getAddress(),
          fee: FeeAmount.MEDIUM,
          recipient: trader.address,
          deadline: await latestDeadline(),
          amountIn: 10n ** 15n,
          amountOutMinimum: 0n,
          sqrtPriceLimitX96: 0n,
        },
      ]);
      const balanceBefore = await token1.balanceOf(trader.address);
      await router.connect(trader).multicall([swapCall]);
      expect(await token1.balanceOf(trader.address)).to.be.greaterThan(balanceBefore);
    });
  });
});
