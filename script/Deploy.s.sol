// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CLAMMFactory} from "../contracts/core/CLAMMFactory.sol";
import {SwapRouter} from "../contracts/periphery/SwapRouter.sol";
import {NonfungiblePositionManager} from "../contracts/periphery/NonfungiblePositionManager.sol";
import {Quoter} from "../contracts/periphery/Quoter.sol";
import {ICLAMMPool} from "../contracts/interfaces/ICLAMMPool.sol";

/// @notice A freely mintable ERC20 for testnet demos only. Never deploy this to
///         a network where the mint function would matter.
contract DemoERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Deploy
/// @notice Deploys the full CLAMM stack — factory, router, position manager, and
///         quoter — and, when `DEPLOY_DEMO_POOL=true`, two demo tokens plus an
///         initialised 0.30% pool so the deployment has something live to inspect.
///
/// @dev Usage:
///
///   The script file holds a second (demo-token) contract, so pass
///   `--tc Deploy` to disambiguate the entry point.
///
///   Local (anvil):
///     anvil &
///     forge script script/Deploy.s.sol --tc Deploy \
///       --rpc-url http://localhost:8545 --broadcast \
///       --private-key <ANVIL_KEY>
///
///   Sepolia, with source verification:
///     cp .env.example .env      # then fill it in
///     source .env
///     DEPLOY_DEMO_POOL=true forge script script/Deploy.s.sol --tc Deploy \
///       --rpc-url $SEPOLIA_RPC_URL --broadcast \
///       --private-key $PRIVATE_KEY \
///       --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
///
/// The private key is read from the command line / environment and is never
/// written to disk by this script. Use a throwaway deployer key for testnets.
contract Deploy is Script {
    // sqrt(1) * 2^96 — a 1:1 starting price in Q64.96.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        vm.startBroadcast();

        CLAMMFactory factory = new CLAMMFactory();
        SwapRouter router = new SwapRouter(address(factory));
        NonfungiblePositionManager positionManager = new NonfungiblePositionManager(address(factory));
        Quoter quoter = new Quoter(address(factory));

        console2.log("CLAMMFactory:            ", address(factory));
        console2.log("SwapRouter:              ", address(router));
        console2.log("NonfungiblePositionManager:", address(positionManager));
        console2.log("Quoter:                  ", address(quoter));

        if (vm.envOr("DEPLOY_DEMO_POOL", false)) {
            DemoERC20 tokenA = new DemoERC20("CLAMM Demo A", "DEMOA", 1_000_000 ether);
            DemoERC20 tokenB = new DemoERC20("CLAMM Demo B", "DEMOB", 1_000_000 ether);

            // Pools order tokens by address; sort so the 1:1 price is unambiguous.
            (address token0, address token1) = address(tokenA) < address(tokenB)
                ? (address(tokenA), address(tokenB))
                : (address(tokenB), address(tokenA));

            address pool = factory.createPool(token0, token1, 3000);
            ICLAMMPool(pool).initialize(SQRT_PRICE_1_1);

            console2.log("Demo token0:             ", token0);
            console2.log("Demo token1:             ", token1);
            console2.log("Demo 0.30%% pool:         ", pool);
        }

        vm.stopBroadcast();
    }
}
