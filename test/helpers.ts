import { ethers } from "hardhat";

export const Q96 = 2n ** 96n;

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const MIN_SQRT_RATIO = 4295128739n;
export const MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342n;

export const FeeAmount = {
  LOW: 500,
  MEDIUM: 3000,
  HIGH: 10000,
} as const;

export const TICK_SPACINGS: Record<number, number> = {
  [FeeAmount.LOW]: 10,
  [FeeAmount.MEDIUM]: 60,
  [FeeAmount.HIGH]: 200,
};

/** Integer sqrt of a bigint (floor). */
export function sqrtBigInt(value: bigint): bigint {
  if (value < 0n) throw new Error("negative");
  if (value < 2n) return value;
  let x = value;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + value / x) / 2n;
  }
  return x;
}

/** Computes sqrt(reserve1/reserve0) * 2^96 as used by pool.initialize. */
export function encodePriceSqrt(reserve1: bigint, reserve0: bigint): bigint {
  // sqrt(r1/r0) * 2^96 = sqrt(r1 * 2^192 / r0)
  return sqrtBigInt((reserve1 * (1n << 192n)) / reserve0);
}

export function getPositionKey(owner: string, tickLower: number, tickUpper: number): string {
  return ethers.solidityPackedKeccak256(["address", "int24", "int24"], [owner, tickLower, tickUpper]);
}

/** Nearest usable tick for a given spacing (rounds toward zero). */
export function nearestUsableTick(tick: number, spacing: number): number {
  return Math.round(tick / spacing) * spacing;
}

export async function latestDeadline(): Promise<number> {
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp + 3600;
}
