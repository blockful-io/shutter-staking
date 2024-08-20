// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@forge-std/Script.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {RewardsDistributor} from "src/RewardsDistributor.sol";
import {Staking} from "src/Staking.sol";
import {DelegateStaking} from "src/DelegateStaking.sol";
import {MockGovToken} from "test/mocks/MockGovToken.sol";
import "./Constants.sol";

// forge script script/testnet/DeployTestnet.s.sol --rpc-url testnet -vvvvv --slow --always-use-create-2-factory --account test --etherscan-api-key testnet --verify --chain 11155111 --code-size-limit 40000 --broadcast
contract DeployTestnet is Script {
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
            address(STAKING_TOKEN)
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

        IERC20Metadata(STAKING_TOKEN).approve(
            address(stakingProxy),
            INITIAL_MINT
        );

        stakingProxy.initialize(
            CONTRACT_OWNER,
            address(STAKING_TOKEN),
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
