// contracts/MemeBattles.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MemeBattles {
    struct Battle {
        string castA;
        string castB;
        uint256 votesA;
        uint256 votesB;
        bool isActive;
        uint256 createdAt;
    }

    mapping(uint256 => Battle) public battles;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public battleCount;
    uint256 public constant VOTING_PERIOD = 7 days;
    address public owner;
    uint256 public constant VOTE_FEE = 20000000000000; // 0.00002 BASE (~$0.05)

    event BattleCreated(uint256 indexed battleId, string castA, string castB);
    event VoteCast(uint256 indexed battleId, address indexed voter, uint8 choice);

    constructor() {
        owner = msg.sender;
    }

    function createBattle(string memory _castA, string memory _castB) external returns (uint256) {
        battleCount++;
        battles[battleCount] = Battle({
            castA: _castA,
            castB: _castB,
            votesA: 0,
            votesB: 0,
            isActive: true,
            createdAt: block.timestamp
        });

        emit BattleCreated(battleCount, _castA, _castB);
        return battleCount;
    }

    function vote(uint256 _battleId, uint8 _choice) external payable {
        require(msg.value == VOTE_FEE, "Exact fee required"); // Changed from >= to ==
        require(_battleId <= battleCount && _battleId > 0, "Invalid battle ID");
        require(battles[_battleId].isActive, "Battle inactive");
        require(!hasVoted[_battleId][msg.sender], "Already voted");
        require(_choice == 1 || _choice == 2, "Invalid choice");
        require(block.timestamp <= battles[_battleId].createdAt + VOTING_PERIOD, "Voting period over");

        hasVoted[_battleId][msg.sender] = true;

        if (_choice == 1) {
            battles[_battleId].votesA++;
        } else {
            battles[_battleId].votesB++;
        }

        emit VoteCast(_battleId, msg.sender, _choice);
    }

    function getBattle(uint256 _battleId) external view returns (Battle memory) {
        return battles[_battleId];
    }

    function endBattle(uint256 _battleId) external {
        require(block.timestamp > battles[_battleId].createdAt + VOTING_PERIOD, "Voting still active");
        battles[_battleId].isActive = false;
    }

    function withdrawFees() external {
        require(msg.sender == owner, "Not owner");
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        
        (bool success, ) = owner.call{value: balance}("");
        require(success, "Transfer failed");
    }

    receive() external payable {}
    fallback() external payable {}
}