// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "./crowdfunds.sol";

contract CrowdfundFactory {
    address public devWallet;
    uint256 public feePercentage; // in basis points (e.g., 50 = 0.5%)
    address[] public campaigns;

    event CampaignCreated(address indexed campaign, address indexed creator);

    constructor(address _devWallet, uint256 _feePercentage) {
        require(_feePercentage <= 1000, "Max 10%");
        devWallet = _devWallet;
        feePercentage = _feePercentage;
    }

    function setDevWallet(address _newWallet) external {
        require(msg.sender == devWallet, "Not dev wallet");
        devWallet = _newWallet;
    }

    function setFeePercentage(uint256 _newFee) external {
        require(msg.sender == devWallet, "Not dev wallet");
        require(_newFee <= 1000, "Max 10%");
        feePercentage = _newFee;
    }

    function createCrowdfund(
        uint256 fundingGoal,
        uint256 durationInSeconds,
        string memory metadataURI
    ) external {
        crowdfunds newCampaign = new crowdfunds(
            fundingGoal,
            durationInSeconds,
            devWallet,
            feePercentage,
            metadataURI
        );
        campaigns.push(address(newCampaign));
        emit CampaignCreated(address(newCampaign), msg.sender);
    }

    function getAllCampaigns() external view returns (address[] memory) {
        return campaigns;
    }
}
