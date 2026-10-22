// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { Ryo } from "../src/Ryo.sol";

/// @notice Deploy Ryo to Base mainnet using environment variables.
/// @dev Usage:
///      forge script script/Deploy.s.sol:Deploy \
///        --rpc-url "$BASE_RPC_URL" --account ryo-deployer --broadcast --verify
///
///      The script refuses to deploy on any chain other than Base mainnet (8453). Simulation is
///      therefore done against a Base RPC endpoint rather than a local anvil chain.
contract Deploy is Script {
    error WrongChain(uint256 chainId);
    error VaultNotContract(address vault);
    error EnvValueTooLarge(string name, uint256 value);

    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;

    function run() external returns (Ryo ryo) {
        if (block.chainid != BASE_MAINNET_CHAIN_ID) revert WrongChain(block.chainid);

        address vault = vm.envAddress("BALANCER_VAULT");
        if (vault.code.length == 0) revert VaultNotContract(vault);

        Ryo.PrimaryRouteConfig memory route0 = Ryo.PrimaryRouteConfig({
            asset: vm.envAddress("ROUTE0_ASSET"),
            intermediate: vm.envAddress("ROUTE0_INTERMEDIATE"),
            buyRouter: vm.envAddress("ROUTE0_BUY_ROUTER"),
            sellRouter: vm.envAddress("ROUTE0_SELL_ROUTER"),
            buyDexType: _envUint8("ROUTE0_BUY_DEX_TYPE"),
            sellDexType: _envUint8("ROUTE0_SELL_DEX_TYPE"),
            buyFee: _envUint24("ROUTE0_BUY_FEE"),
            sellFee: _envUint24("ROUTE0_SELL_FEE")
        });

        Ryo.PrimaryRouteConfig memory route1 = Ryo.PrimaryRouteConfig({
            asset: vm.envAddress("ROUTE1_ASSET"),
            intermediate: vm.envAddress("ROUTE1_INTERMEDIATE"),
            buyRouter: vm.envAddress("ROUTE1_BUY_ROUTER"),
            sellRouter: vm.envAddress("ROUTE1_SELL_ROUTER"),
            buyDexType: _envUint8("ROUTE1_BUY_DEX_TYPE"),
            sellDexType: _envUint8("ROUTE1_SELL_DEX_TYPE"),
            buyFee: _envUint24("ROUTE1_BUY_FEE"),
            sellFee: _envUint24("ROUTE1_SELL_FEE")
        });

        address[] memory extraRouters = vm.envOr("EXTRA_ROUTERS", ",", new address[](0));

        vm.startBroadcast();

        ryo = new Ryo(
            vault,
            vm.envAddress("OWNER"),
            vm.envAddress("OPERATOR"),
            route0,
            route1,
            extraRouters,
            vm.envUint("MAX_GAS_PRICE"),
            vm.envUint("ROUTE0_MAX_TRADE_SIZE"),
            vm.envUint("ROUTE1_MAX_TRADE_SIZE")
        );

        vm.stopBroadcast();

        console2.log("Ryo deployed at", address(ryo));
        console2.log("  chainId  ", block.chainid);
        console2.log("  vault    ", vault);
        console2.log("  owner    ", ryo.owner());
        console2.log("  operator ", ryo.operator());
        console2.log("  route0 asset  ", route0.asset);
        console2.log("  route0 middle ", route0.intermediate);
        console2.log("  route1 asset  ", route1.asset);
        console2.log("  route1 middle ", route1.intermediate);
    }

    function _envUint8(string memory name) private view returns (uint8) {
        uint256 value = vm.envUint(name);
        if (value > type(uint8).max) revert EnvValueTooLarge(name, value);
        return uint8(value);
    }

    function _envUint24(string memory name) private view returns (uint24) {
        uint256 value = vm.envUint(name);
        if (value > type(uint24).max) revert EnvValueTooLarge(name, value);
        return uint24(value);
    }
}
