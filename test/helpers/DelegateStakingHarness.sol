// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DelegateStaking} from "src/DelegateStaking.sol";

contract DelegateStakingHarness is DelegateStaking {
    function exposed_nextStakeId() external view returns (uint256) {
        return nextStakeId;
    }

    function exposed_previewWithdraw(
        uint256 amount
    ) external view returns (uint256) {
        return _previewWithdraw(amount);
    }

    function exposed_calculateWithdrawAmount(
        uint256 _amount,
        uint256 _maxWithdrawAmount
    ) external view returns (uint256) {
        return _calculateWithdrawAmount(_amount, _maxWithdrawAmount);
    }
}
