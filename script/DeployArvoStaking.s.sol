// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { Options } from "openzeppelin-foundry-upgrades/Options.sol";

import { ArvoStaking } from "../src/ArvoStaking.sol";

contract DeployArvoStaking is Script {
    error ZeroAddress();

    function run() external returns (address proxy, address implementation) {
        address arvoToken = vm.envAddress("ARVO_TOKEN");
        address usdcToken = vm.envAddress("USDC_TOKEN");
        address admin = vm.envAddress("STAKING_ADMIN");

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

        vm.startBroadcast();

        proxy = Upgrades.deployUUPSProxy("ArvoStaking.sol:ArvoStaking", initializerData, opts);

        vm.stopBroadcast();

        implementation = Upgrades.getImplementationAddress(proxy);
    }
}
