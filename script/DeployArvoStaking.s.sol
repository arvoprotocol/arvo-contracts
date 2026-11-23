// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ArvoStaking } from "../src/ArvoStaking.sol";

contract DeployArvoStaking is Script {
    error ZeroAddress();
    error WrongChain();

    function run() external returns (address proxy, address implementation) {
        address arvoToken = vm.envAddress("ARVO_TOKEN");
        address usdcToken = vm.envAddress("USDC_TOKEN");
        address admin = vm.envAddress("STAKING_ADMIN");
        // Optional guard for live deployments: set EXPECTED_CHAIN_ID (4663 for Robinhood Chain mainnet).
        if (block.chainid != vm.envOr("EXPECTED_CHAIN_ID", block.chainid)) revert WrongChain();

        return deploy(arvoToken, usdcToken, admin);
    }

    function deploy(address arvoToken, address usdcToken, address admin)
        public
        returns (address proxy, address implementation)
    {
        if (arvoToken == address(0) || usdcToken == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }

        bytes memory initializerData =
            abi.encodeCall(ArvoStaking.initialize, (arvoToken, usdcToken, admin));

        Options memory opts;
        // Allow only the reviewed mapping-based factory library; no assembly or
        // external token calls occur in that library. Keep storage checks enabled.
        opts.unsafeAllow = "constructor,external-library-linking";

        // Run OpenZeppelin's upgrade-safety validation (storage layout, initializers) on the
        // implementation first. Then deploy it with `new`, so Forge deploys and links the external
        // ArvoPoolCreation library (vm.getCode can't read unlinked bytecode), and put it behind an
        // ERC1967 (UUPS) proxy initialised in the same transaction. Same result as deployUUPSProxy.
        Upgrades.validateImplementation("ArvoStaking.sol:ArvoStaking", opts);

        vm.startBroadcast();

        implementation = address(new ArvoStaking());
        proxy = address(new ERC1967Proxy(implementation, initializerData));

        vm.stopBroadcast();

        implementation = Upgrades.getImplementationAddress(proxy);
    }
}
