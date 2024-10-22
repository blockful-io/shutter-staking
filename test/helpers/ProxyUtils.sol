// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "@forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

library ProxyUtils {
    address public constant CHEATCODE_ADDRESS =
        0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    function getAdminAddress(address proxy) public view returns (address) {
        bytes32 adminSlot = Vm(CHEATCODE_ADDRESS).load(
            proxy,
            ERC1967Utils.ADMIN_SLOT
        );
        return address(uint160(uint256(adminSlot)));
    }
}
