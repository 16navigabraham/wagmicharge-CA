// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title PaycryptProxyWithOwner
 * @dev Proxy contract that properly initializes the PaycryptV1 implementation with owner
 */
contract PaycryptProxyWithOwner is ERC1967Proxy {
    constructor(
        address implementation,
        address[] memory admins,
        uint256 requiredApprovals,
        address initialOwner
    ) ERC1967Proxy(
        implementation,
        abi.encodeWithSelector(
            bytes4(keccak256("initializeWithOwner(address[],uint256,address)")),
            admins,
            requiredApprovals,
            initialOwner
        )
    ) {}
}