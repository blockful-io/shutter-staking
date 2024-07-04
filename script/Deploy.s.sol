// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {Staking} from "src/Staking.sol";

contract Deploy is Script {
    address constant STAKING_TOKEN = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7; // shutter token
    address constant CONTRACT_OWNER =
        0x36bD3044ab68f600f6d3e081056F34f2a58432c4; // shuter multisig
    uint256 constant LOCK_PERIOD = 182 days;
    uint256 constant MIN_STAKE = 50_000 * 1e18;
    uint256 constant REWARD_RATE = 0.1e18;

    function run()
        public
        returns (Staking stakingProxy, RewardsDistributor rewardsDistributor)
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
                    address(this),
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

        rewardsDistributor.setRewardConfiguration(
            address(stakingProxy),
            REWARD_RATE
        );

        vm.stopBroadcast();
    }
}
