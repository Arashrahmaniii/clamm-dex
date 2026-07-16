import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        // The factory embeds the pool's creation bytecode, so runs are tuned to
        // keep the factory under the 24KB Spurious Dragon deploy limit.
        runs: 200,
      },
      // Concentrated-liquidity math relies on unchecked overflow semantics in
      // a handful of hot paths; the via-IR pipeline keeps stack usage in check.
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },
};

export default config;
