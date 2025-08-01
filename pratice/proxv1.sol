// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract PaycryptProxy is ERC1967Proxy {
    
    address public proxyOwner;
    
    modifier onlyProxyOwner() {
        require(msg.sender == proxyOwner, "Not proxy owner");
        _;
    }
    
    constructor(
        address implementation,
        address owner
    ) ERC1967Proxy(
        implementation,
        abi.encodeWithSignature("initialize(address)", owner)
    ) {
        proxyOwner = owner;
    }
    
    function upgradeTo(address newImplementation) external onlyProxyOwner {
        ERC1967Utils.upgradeToAndCall(
            newImplementation, 
            abi.encodeWithSignature("initialize(address)", proxyOwner)
        );
    }
    
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
    
    receive() external payable {}
}
//The provided Solidity code defines a proxy contract named `PaycryptProxy` that extends the `ERC1967Proxy` contract