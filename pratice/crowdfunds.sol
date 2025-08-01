// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

contract crowdfunds {
    address public owner;
    address public devWallet;
    uint256 public feePercentage;

    mapping(address => uint256) public contributors;

    uint256 public totalFundsRaised;
    uint256 public fundingGoal;
    uint256 public deadline;
    uint256 public withdrawalDeadline;
    string public metadataURI;

    bool public fundsWithdrawn = false;

    event ContributionReceived(address indexed contributor, uint256 amount);
    event FundsWithdrawn(uint256 netAmount, uint256 feeAmount);
    event Refunded(address indexed contributor, uint256 amount);

    constructor(
        uint256 _fundingGoal,
        uint256 _duration,
        address _devWallet,
        uint256 _feePercentage,
        string memory _metadataURI
    ) {
        require(_fundingGoal > 0, "Goal must be > 0");
        require(_duration > 0, "Duration must be > 0");
        require(_feePercentage <= 1000, "Max 10%");

        owner = msg.sender;
        fundingGoal = _fundingGoal;
        deadline = block.timestamp + _duration;
        withdrawalDeadline = deadline + 7 days;
        devWallet = _devWallet;
        feePercentage = _feePercentage;
        metadataURI = _metadataURI;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the campaign owner");
        _;
    }

    modifier onlyContributor() {
        require(contributors[msg.sender] > 0, "Not a contributor");
        _;
    }

    function contribute() external payable {
        require(block.timestamp < deadline, "Deadline passed");
        require(totalFundsRaised < fundingGoal, "Goal met");
        require(msg.value > 0, "Zero contribution");

        uint256 allowed = fundingGoal - totalFundsRaised;
        uint256 accepted = msg.value > allowed ? allowed : msg.value;

        contributors[msg.sender] += accepted;
        totalFundsRaised += accepted;

        if (msg.value > accepted) {
            payable(msg.sender).transfer(msg.value - accepted);
        }

        emit ContributionReceived(msg.sender, accepted);
    }

    function withdrawFunds() external onlyOwner {
        require(totalFundsRaised >= fundingGoal, "Goal not met");
        require(block.timestamp > deadline, "Too early to withdraw");
        require(block.timestamp <= withdrawalDeadline, "Withdrawal period ended");
        require(!fundsWithdrawn, "Already withdrawn");

        fundsWithdrawn = true;

        uint256 fee = (totalFundsRaised * feePercentage) / 10000;
        uint256 net = totalFundsRaised - fee;

        payable(devWallet).transfer(fee);
        payable(owner).transfer(net);

        emit FundsWithdrawn(net, fee);
    }

    function refund() external onlyContributor {
        require(block.timestamp > deadline, "Deadline not reached");
        require(
            totalFundsRaised < fundingGoal || (block.timestamp > withdrawalDeadline && !fundsWithdrawn),
            "Not eligible for refund"
        );

        uint256 amount = contributors[msg.sender];
        require(amount > 0, "Already refunded");

        contributors[msg.sender] = 0;
        payable(msg.sender).transfer(amount);

        emit Refunded(msg.sender, amount);
    }

    function getContribution(address user) external view returns (uint256) {
        return contributors[user];
    }

    function getTotalFundsRaised() external view returns (uint256) {
        return totalFundsRaised;
    }
}
