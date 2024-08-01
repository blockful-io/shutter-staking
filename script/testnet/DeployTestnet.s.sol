// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {Staking} from "src/Staking.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import "./Constants.sol";

// forge script script/testnet/DeployTestnet.s.sol --rpc-url testnet -vvvvv --slow --always-use-create-2-factory --account test --etherscan-api-key testnet --verify --chain 11155111
contract DeployTestnet is Script {
    function run()
        public
        returns (Staking stakingProxy, RewardsDistributor rewardsDistributor)
    {
        vm.startBroadcast();

        MockGovToken govToken = new MockGovToken();

        rewardsDistributor = new RewardsDistributor(
            CONTRACT_OWNER,
            address(govToken)
        );

        Staking stake = new Staking();
        stakingProxy = Staking(
            address(
                new TransparentUpgradeableProxy(
                    address(stake),
                    address(CONTRACT_OWNER),
                    ""
                )
            )
        );

        stakingProxy.initialize(
            CONTRACT_OWNER,
            address(govToken),
            address(rewardsDistributor),
            LOCK_PERIOD,
            MIN_STAKE
        );

        vm.stopBroadcast();
    }
}
