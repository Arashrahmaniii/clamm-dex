# Deployment

`script/Deploy.s.sol` deploys the full stack — `CLAMMFactory`, `SwapRouter`,
`NonfungiblePositionManager`, and `Quoter` — and, when `DEPLOY_DEMO_POOL=true`,
two demo tokens plus an initialised 0.30% pool so there is something live to
inspect.

The script file contains a second (demo-token) contract, so pass `--tc Deploy`.

## Local (anvil)

```bash
anvil &
DEPLOY_DEMO_POOL=true forge script script/Deploy.s.sol --tc Deploy \
  --rpc-url http://localhost:8545 --broadcast --private-key <ANVIL_KEY>
```

## Sepolia, with source verification

```bash
cp .env.example .env      # then fill in your values
source .env

DEPLOY_DEMO_POOL=true forge script script/Deploy.s.sol --tc Deploy \
  --rpc-url $SEPOLIA_RPC_URL --broadcast \
  --private-key $PRIVATE_KEY \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
```

The run prints every deployed address. `--verify` uploads and verifies source on
Etherscan automatically.

## After deploying

Record the addresses here so the README can link to verified source:

| Contract | Sepolia address |
|---|---|
| CLAMMFactory | `0x…` |
| SwapRouter | `0x…` |
| NonfungiblePositionManager | `0x…` |
| Quoter | `0x…` |
| Demo pool (0.30%) | `0x…` |

## Notes

- The deployer key is read from the environment and never written to disk. Use a
  throwaway key for testnets.
- `DemoERC20` is freely mintable and exists only to populate a demo pool. Do not
  deploy it anywhere its mint function would matter.
