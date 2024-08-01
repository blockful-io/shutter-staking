// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import "./Constants.sol";

// forge script script/testnet/DeployDelegateTestnet.s.sol --rpc-url testnet -vvvvv --slow --always-use-create-2-factory --account test --etherscan-api-key testnet --verify --chain 11155111
contract DeployTestnet is Script {
    function run() public returns (DelegateStaking delegateProxy) {
        vm.startBroadcast();

        DelegateStaking delegate = new DelegateStaking();
        delegateProxy = DelegateStaking(
            address(
                new TransparentUpgradeableProxy(
                    address(delegate),
                    address(CONTRACT_OWNER),
                    ""
                )
            )
        );

        delegateProxy.initialize(
            CONTRACT_OWNER,
            MOCKED_SHU,
            REWARDS_DISTRIBUTOR,
            STAKING_CONTRACT_PROXY,
            LOCK_PERIOD
        );

        vm.stopBroadcast();
    }
}
