// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import {Staking} from "src/Staking.sol";
import "./Constants.sol";

contract Deploy is Script {
    function run()
        public
        returns (
            Staking stakingProxy,
            RewardsDistributor rewardsDistributor,
            DelegateStaking delegateProxy
        )
    {
        vm.startBroadcast();

        rewardsDistributor = new RewardsDistributor(
            CONTRACT_OWNER,
            STAKING_TOKEN
        );

        stakingProxy = Staking(
            address(
                new TransparentUpgradeableProxy(
                    address(new Staking()),
                    address(CONTRACT_OWNER),
                    ""
                )
            )
        );

        stakingProxy.initialize(
            CONTRACT_OWNER,
            STAKING_TOKEN,
            address(rewardsDistributor),
            LOCK_PERIOD,
            MIN_STAKE
        );

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
            STAKING_TOKEN,
            address(rewardsDistributor),
            address(stakingProxy),
            LOCK_PERIOD
        );

        vm.stopBroadcast();
    }
}
