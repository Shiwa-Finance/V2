//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./@openzeppelin/contracts/access/Ownable.sol";

contract ShiwaMigrator is Ownable {
    IERC20 public ShiwaTokenV1;
    IERC20 public ShiwaTokenV2;
    address public targetDest;

    constructor(address tokenV1, address tokenV2, address target) {
        ShiwaTokenV1 = IERC20(tokenV1);
        ShiwaTokenV2 = IERC20(tokenV2);
        targetDest = target;
    }

    function migrateV2(uint256 amount) public returns (bool) {
        ShiwaTokenV1.transferFrom(_msgSender(), targetDest, amount);
        ShiwaTokenV2.transfer(_msgSender(), amount);
        return true;
    }

    function migrateV2EmergencyWithdraw() public onlyOwner returns (bool) {
        ShiwaTokenV2.transfer(_msgSender(), ShiwaTokenV2.balanceOf(_msgSender()));
        return true;
    }

    function extrudeTokens(address token, uint256 amount) public onlyOwner returns (bool) {
        IERC20(token).transfer(_msgSender(), amount);
        return true;
    }
}