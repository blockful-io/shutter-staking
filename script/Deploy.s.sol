// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Script.sol";
import "@forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import {Staking} from "src/Staking.sol";
import "./Constants.sol";

// forge script script/Deploy.s.sol --rpc-url mainnet -vvvvv --slow --always-use-create-2-factory --account test --etherscan-api-key mainnet --chain 1 --code-size-limit 40000
// --verify --broadcast
contract Deploy is Script {
    function run()
        public
        returns (
            Staking stakingProxy,
            RewardsDistributor rewardsDistributor,
            DelegateStaking delegateProxy
        )
    {
        vm.label(STAKING_TOKEN, "StakingToken");

        vm.startBroadcast();

        rewardsDistributor = new RewardsDistributor(
            CONTRACT_OWNER,
            address(STAKING_TOKEN)
        );
        vm.label(address(rewardsDistributor), "RewardsDistributor");

        Staking stake = new Staking();
        vm.label(address(stake), "Staking");
        stakingProxy = Staking(
            address(
                new TransparentUpgradeableProxy(
                    address(stake),
                    address(CONTRACT_OWNER),
                    ""
                )
            )
        );
        vm.label(address(stakingProxy), "StakingProxy");

        IERC20Metadata(STAKING_TOKEN).approve(
            address(stakingProxy),
            INITIAL_MINT
        );

        stakingProxy.initialize(
            CONTRACT_OWNER,
            STAKING_TOKEN,
            address(rewardsDistributor),
            LOCK_PERIOD,
            MIN_STAKE
        );

        DelegateStaking delegate = new DelegateStaking();
        vm.label(address(delegate), "DelegateStaking");
        delegateProxy = DelegateStaking(
            address(
                new TransparentUpgradeableProxy(
                    address(delegate),
                    address(CONTRACT_OWNER),
                    ""
                )
            )
        );
        vm.label(address(delegateProxy), "DelegateStakingProxy");

        IERC20Metadata(STAKING_TOKEN).approve(
            address(delegateProxy),
            INITIAL_MINT
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
