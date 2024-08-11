// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Staking} from "src/Staking.sol";

contract StakingHarness is Staking {
    function exposed_nextStakeId() external view returns (uint256) {
        return nextStakeId;
    }

    function exposed_maxWithdraw(
        address keyper,
        uint256 unlockedAmount
    ) external view virtual returns (uint256) {
        return _maxWithdraw(keyper, unlockedAmount);
    }

    function exposed_previewWithdraw(
        uint256 amount
    ) external view returns (uint256) {
        return _previewWithdraw(amount);
    }
}
