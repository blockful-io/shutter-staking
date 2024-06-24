// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockGovToken is ERC20 {
    constructor() ERC20("Shu", "SHU") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
