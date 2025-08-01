// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PaycryptProxy
 * @dev UUPS Proxy contract for Paycrypt implementation
 * @author Paycrypt Team
 */
contract PaycryptProxy is ERC1967Proxy, Ownable {
    
    /**
     * @dev Constructor for the proxy contract
     * @param implementation Address of the implementation contract
     * @param devWallet Address of the dev wallet
     * @param proxyOwner Address that will own the proxy contract
     */
    constructor(
        address implementation,
        address devWallet,
        address proxyOwner
    ) 
        ERC1967Proxy(
            implementation,
            abi.encodeWithSignature(
                "initialize(address,address)",
                devWallet,
                proxyOwner
            )
        )
        Ownable(proxyOwner)
    {
        require(implementation != address(0), "Implementation zero address");
        require(devWallet != address(0), "Dev wallet zero address");
        require(proxyOwner != address(0), "Proxy owner zero address");
    }

    /**
     * @dev Upgrade the implementation contract
     * @param newImplementation Address of the new implementation contract
     */
    function upgradeTo(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "New implementation zero address");
        ERC1967Utils.upgradeToAndCall(newImplementation, "");
    }

    /**
     * @dev Upgrade the implementation contract and call a function
     * @param newImplementation Address of the new implementation contract
     * @param data Encoded function call data
     */
    function upgradeToAndCall(
        address newImplementation,
        bytes memory data
    ) external payable onlyOwner {
        require(newImplementation != address(0), "New implementation zero address");
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }

    /**
     * @dev Get the current implementation address
     * @return The address of the current implementation
     */
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @dev Get the proxy admin (owner)
     * @return The address of the proxy admin
     */
    function getProxyAdmin() external view returns (address) {
        return owner();
    }

    /**
     * @dev Receive function to handle direct ETH transfers
     * Delegates to the implementation contract
     */
    receive() external payable  {
        // Delegate to implementation
        _delegate(_implementation());
    }
}