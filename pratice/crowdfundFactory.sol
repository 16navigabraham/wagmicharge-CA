// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "./crowdfund.sol";

contract CrowdfundFactory {
    address[] public campaigns;

    function createCrowdfund(uint256 goal, uint256 duration) external returns (address) {
        crowdfunds newCampaign = new crowdfunds(goal, duration);
        campaigns.push(address(newCampaign));
        return address(newCampaign);
    }

    function getAllCampaigns() external view returns (address[] memory) {
        return campaigns;
    }
}
