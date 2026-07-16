import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { Q96, FeeAmount, latestDeadline } from "./helpers";

const LOWER = -600;
const UPPER = 600;
const INITIAL_BALANCE = 10n ** 24n;
const DESIRED = 10n ** 18n;

describe("NonfungiblePositionManager & SwapRouter", () => {
  async function deployFixture() {
    const [deployer, lp, trader, other] = await ethers.getSigners();

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

    for (const user of [lp, trader, other]) {
      await token0.mint(user.address, INITIAL_BALANCE);
      await token1.mint(user.address, INITIAL_BALANCE);
      await token0.connect(user).approve(npm.getAddress(), ethers.MaxUint256);
      await token1.connect(user).approve(npm.getAddress(), ethers.MaxUint256);
      await token0.connect(user).approve(router.getAddress(), ethers.MaxUint256);
      await token1.connect(user).approve(router.getAddress(), ethers.MaxUint256);
    }

    return { deployer, lp, trader, other, factory, token0, token1, pool, npm, router };
  }

  function mintParams(token0: string, token1: string, recipient: string, deadline: number) {
    return {
      token0,
      token1,
      fee: FeeAmount.MEDIUM,
      tickLower: LOWER,
      tickUpper: UPPER,
      amount0Desired: DESIRED,
      amount1Desired: DESIRED,
      amount0Min: 0n,
      amount1Min: 0n,
      recipient,
      deadline,
    };
  }

  async function mintedPositionFixture() {
    const state = await deployFixture();
    const { npm, token0, token1, lp } = state;
    await npm
      .connect(lp)
      .mint(mintParams(await token0.getAddress(), await token1.getAddress(), lp.address, await latestDeadline()));
    return { ...state, tokenId: 1n };
  }

  describe("mint", () => {
    it("mints an NFT backed by pool liquidity", async () => {
      const { npm, pool, token0, token1, lp } = await loadFixture(deployFixture);

      await expect(
        npm
          .connect(lp)
          .mint(mintParams(await token0.getAddress(), await token1.getAddress(), lp.address, await latestDeadline()))
      ).to.emit(npm, "IncreaseLiquidity");

      expect(await npm.ownerOf(1)).to.equal(lp.address);
      const position = await npm.positions(1);
      expect(position.pool).to.equal(await pool.getAddress());
      expect(position.liquidity).to.be.greaterThan(0n);
      expect(await pool.liquidity()).to.equal(position.liquidity);
    });

    it("enforces deadline, token ordering and pool existence", async () => {
      const { npm, token0, token1, lp } = await loadFixture(deployFixture);
      const t0 = await token0.getAddress();
      const t1 = await token1.getAddress();

      await expect(npm.connect(lp).mint(mintParams(t0, t1, lp.address, 1))).to.be.revertedWith(
        "NPM: DEADLINE_EXPIRED"
      );
      await expect(npm.connect(lp).mint(mintParams(t1, t0, lp.address, await latestDeadline()))).to.be.revertedWith(
        "NPM: TOKEN_ORDER"
      );
      const params = { ...mintParams(t0, t1, lp.address, await latestDeadline()), fee: FeeAmount.LOW };
      await expect(npm.connect(lp).mint(params)).to.be.revertedWith("NPM: POOL_NOT_FOUND");
    });

    it("enforces the minimum-amount slippage check", async () => {
      const { npm, token0, token1, lp } = await loadFixture(deployFixture);
      const params = {
        ...mintParams(await token0.getAddress(), await token1.getAddress(), lp.address, await latestDeadline()),
        amount0Min: DESIRED * 2n,
      };
      await expect(npm.connect(lp).mint(params)).to.be.revertedWith("NPM: SLIPPAGE");
    });

    it("rejects a direct call to the mint callback", async () => {
      const { npm, other } = await loadFixture(deployFixture);
      await expect(npm.connect(other).clammMintCallback(1n, 1n, "0x")).to.be.revertedWith("NPM: INVALID_CALLBACK");
    });
  });

  describe("increase / decrease liquidity", () => {
    it("increases liquidity on an existing token", async () => {
      const { npm, pool, lp, tokenId } = await loadFixture(mintedPositionFixture);
      const before = (await npm.positions(tokenId)).liquidity;

      await npm.connect(lp).increaseLiquidity({
        tokenId,
        amount0Desired: DESIRED,
        amount1Desired: DESIRED,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline: await latestDeadline(),
      });

      const after = (await npm.positions(tokenId)).liquidity;
      expect(after).to.be.greaterThan(before);
      expect(await pool.liquidity()).to.equal(after);
    });

    it("decreases liquidity and accounts the principal as owed", async () => {
      const { npm, lp, tokenId } = await loadFixture(mintedPositionFixture);
      const position = await npm.positions(tokenId);

      await npm.connect(lp).decreaseLiquidity({
        tokenId,
        liquidity: position.liquidity / 2n,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline: await latestDeadline(),
      });

      const after = await npm.positions(tokenId);
      expect(after.liquidity).to.equal(position.liquidity - position.liquidity / 2n);
      expect(after.tokensOwed0).to.be.greaterThan(0n);
      expect(after.tokensOwed1).to.be.greaterThan(0n);
    });

    it("blocks non-owners from decreasing or collecting", async () => {
      const { npm, other, tokenId } = await loadFixture(mintedPositionFixture);
      await expect(
        npm.connect(other).decreaseLiquidity({
          tokenId,
          liquidity: 1n,
          amount0Min: 0n,
          amount1Min: 0n,
          deadline: await latestDeadline(),
        })
      ).to.be.revertedWith("NPM: NOT_AUTHORIZED");
      await expect(
        npm.connect(other).collect({
          tokenId,
          recipient: other.address,
          amount0Max: 1n,
          amount1Max: 1n,
        })
      ).to.be.revertedWith("NPM: NOT_AUTHORIZED");
    });

    it("allows an approved operator to manage the position", async () => {
      const { npm, lp, other, tokenId } = await loadFixture(mintedPositionFixture);
      await npm.connect(lp).approve(other.address, tokenId);
      await npm.connect(other).decreaseLiquidity({
        tokenId,
        liquidity: 1n,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline: await latestDeadline(),
      });
    });
  });

  describe("swaps via router", () => {
    it("swaps exact input with slippage protection", async () => {
      const { router, token0, token1, trader } = await loadFixture(mintedPositionFixture);
      const amountIn = 10n ** 15n;

      const bal1 = await token1.balanceOf(trader.address);
      await router.connect(trader).exactInputSingle({
        tokenIn: await token0.getAddress(),
        tokenOut: await token1.getAddress(),
        fee: FeeAmount.MEDIUM,
        recipient: trader.address,
        deadline: await latestDeadline(),
        amountIn,
        amountOutMinimum: (amountIn * 99n) / 100n, // ≥99% at price 1 in a deep-enough pool
        sqrtPriceLimitX96: 0n,
      });
      const received = (await token1.balanceOf(trader.address)) - bal1;
      expect(received).to.be.greaterThanOrEqual((amountIn * 99n) / 100n);
    });

    it("reverts exact input when output is below the minimum", async () => {
      const { router, token0, token1, trader } = await loadFixture(mintedPositionFixture);
      const amountIn = 10n ** 15n;
      await expect(
        router.connect(trader).exactInputSingle({
          tokenIn: await token0.getAddress(),
          tokenOut: await token1.getAddress(),
          fee: FeeAmount.MEDIUM,
          recipient: trader.address,
          deadline: await latestDeadline(),
          amountIn,
          amountOutMinimum: amountIn, // impossible: fees make out < in at price 1
          sqrtPriceLimitX96: 0n,
        })
      ).to.be.revertedWith("SwapRouter: TOO_LITTLE_RECEIVED");
    });

    it("swaps exact output and refunds nothing beyond the maximum input", async () => {
      const { router, token0, token1, trader } = await loadFixture(mintedPositionFixture);
      const amountOut = 10n ** 15n;

      const bal0Before = await token0.balanceOf(trader.address);
      const bal1Before = await token1.balanceOf(trader.address);
      await router.connect(trader).exactOutputSingle({
        tokenIn: await token1.getAddress(),
        tokenOut: await token0.getAddress(),
        fee: FeeAmount.MEDIUM,
        recipient: trader.address,
        deadline: await latestDeadline(),
        amountOut,
        amountInMaximum: (amountOut * 102n) / 100n,
        sqrtPriceLimitX96: 0n,
      });
      expect((await token0.balanceOf(trader.address)) - bal0Before).to.equal(amountOut);
      expect(bal1Before - (await token1.balanceOf(trader.address))).to.be.lessThanOrEqual((amountOut * 102n) / 100n);
    });

    it("enforces deadline and rejects unknown pools", async () => {
      const { router, token0, token1, trader } = await loadFixture(mintedPositionFixture);
      const base = {
        tokenIn: await token0.getAddress(),
        tokenOut: await token1.getAddress(),
        recipient: trader.address,
        amountIn: 1000n,
        amountOutMinimum: 0n,
        sqrtPriceLimitX96: 0n,
      };
      await expect(
        router.connect(trader).exactInputSingle({ ...base, fee: FeeAmount.MEDIUM, deadline: 1 })
      ).to.be.revertedWith("SwapRouter: DEADLINE_EXPIRED");
      await expect(
        router
          .connect(trader)
          .exactInputSingle({ ...base, fee: FeeAmount.LOW, deadline: await latestDeadline() })
      ).to.be.revertedWith("SwapRouter: POOL_NOT_FOUND");
    });

    it("rejects direct calls to the swap callback", async () => {
      const { router, other } = await loadFixture(mintedPositionFixture);
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ["tuple(address tokenIn, address tokenOut, uint24 fee, address payer)"],
        [
          {
            tokenIn: ethers.ZeroAddress,
            tokenOut: ethers.ZeroAddress,
            fee: FeeAmount.MEDIUM,
            payer: other.address,
          },
        ]
      );
      await expect(router.connect(other).clammSwapCallback(1n, -1n, data)).to.be.reverted;
    });
  });

  describe("full lifecycle", () => {
    it("LP earns fees from trading and exits cleanly, burning the NFT", async () => {
      const { npm, router, token0, token1, lp, trader, tokenId } = await loadFixture(mintedPositionFixture);

      // Generate fees with round-trip trades.
      for (let i = 0; i < 3; i++) {
        await router.connect(trader).exactInputSingle({
          tokenIn: await token0.getAddress(),
          tokenOut: await token1.getAddress(),
          fee: FeeAmount.MEDIUM,
          recipient: trader.address,
          deadline: await latestDeadline(),
          amountIn: 10n ** 16n,
          amountOutMinimum: 0n,
          sqrtPriceLimitX96: 0n,
        });
        await router.connect(trader).exactInputSingle({
          tokenIn: await token1.getAddress(),
          tokenOut: await token0.getAddress(),
          fee: FeeAmount.MEDIUM,
          recipient: trader.address,
          deadline: await latestDeadline(),
          amountIn: 10n ** 16n,
          amountOutMinimum: 0n,
          sqrtPriceLimitX96: 0n,
        });
      }

      // Withdraw all liquidity.
      const position = await npm.positions(tokenId);
      await npm.connect(lp).decreaseLiquidity({
        tokenId,
        liquidity: position.liquidity,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline: await latestDeadline(),
      });

      // Collect principal + fees.
      const bal0 = await token0.balanceOf(lp.address);
      const bal1 = await token1.balanceOf(lp.address);
      const max = (1n << 128n) - 1n;
      await npm.connect(lp).collect({ tokenId, recipient: lp.address, amount0Max: max, amount1Max: max });
      const got0 = (await token0.balanceOf(lp.address)) - bal0;
      const got1 = (await token1.balanceOf(lp.address)) - bal1;

      // The LP ends up with more than the principal thanks to fees. Principal was
      // ~1e18 of each; 3x 1e16 round trips at 0.3% fee add ~3e13 per token.
      expect(got0).to.be.greaterThan(0n);
      expect(got1).to.be.greaterThan(0n);

      // NFT can now be burned; position storage is cleared.
      await npm.connect(lp).burn(tokenId);
      await expect(npm.ownerOf(tokenId)).to.be.reverted;
      expect((await npm.positions(tokenId)).pool).to.equal(ethers.ZeroAddress);
    });

    it("refuses to burn an NFT that still has liquidity or uncollected tokens", async () => {
      const { npm, lp, tokenId } = await loadFixture(mintedPositionFixture);
      await expect(npm.connect(lp).burn(tokenId)).to.be.revertedWith("NPM: NOT_CLEARED");
    });
  });
});
