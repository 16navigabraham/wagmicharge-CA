// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CryptopayEscrow is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    enum PaymentToken { ETH, USDT, USDC }

    struct Order {
        uint256 amount;
        address user;
        PaymentToken tokenType;
        bool settled;
    }

    // Named mapping parameters for better code documentation
    mapping(bytes32 requestId => Order orderData) private _orders;

    address public immutable devWallet;
    IERC20 public immutable USDT;
    IERC20 public immutable USDC;
    
    // Cache address(this) to save gas
    address private immutable _thisContract;

    // Custom errors to save gas
    error DevWalletZeroAddress();
    error USDTZeroAddress();
    error USDCZeroAddress();
    error AlreadySettled();
    error DuplicateOrder();
    error AmountMustBeGreaterThanZero();
    error ETHMismatch();
    error InsufficientAllowance();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidTokenType();
    error InvalidOrder();
    error ETHDevPayoutFailed();
    error ETHRefundFailed();
    error WithdrawFailed();

    event OrderCreated(bytes32 indexed requestId, address indexed user, uint256 amount, PaymentToken token);
    event OrderSettled(bytes32 indexed requestId, bool success, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event ContractPaused();
    event ContractUnpaused();

    constructor(
        address _devWallet,
        address _usdt,
        address _usdc,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_devWallet == address(0)) revert DevWalletZeroAddress();
        if (_usdt == address(0)) revert USDTZeroAddress();
        if (_usdc == address(0)) revert USDCZeroAddress();
        
        devWallet = _devWallet;
        USDT = IERC20(_usdt);
        USDC = IERC20(_usdc);
        _thisContract = address(this);
    }

    modifier onlyUnsettled(bytes32 requestId) {
        if (_orders[requestId].settled) revert AlreadySettled();
        _;
    }

    function createOrder(bytes32 requestId, PaymentToken tokenType, uint256 amount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        // Cache storage reads
        Order storage order = _orders[requestId];
        if (order.user != address(0)) revert DuplicateOrder();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        if (tokenType == PaymentToken.ETH) {
            if (msg.value != amount) revert ETHMismatch();
        } else {
            // Handle ERC20 tokens (USDT and USDC)
            IERC20 token = (tokenType == PaymentToken.USDT) ? USDT : USDC;
            
            // Check allowance first
            uint256 allowance = token.allowance(msg.sender, _thisContract);
            if (allowance < amount) revert InsufficientAllowance();
            
            // Check user balance
            uint256 userBalance = token.balanceOf(msg.sender);
            if (userBalance < amount) revert InsufficientBalance();
            
            // Handle fee-on-transfer tokens by checking balance before and after
            uint256 balanceBefore = token.balanceOf(_thisContract);
            
            // Use SafeERC20 for secure transfer handling
            token.safeTransferFrom(msg.sender, _thisContract, amount);
            
            uint256 balanceAfter = token.balanceOf(_thisContract);
            uint256 actualReceived = balanceAfter - balanceBefore;
            
            // Update amount to actual received amount
            if (actualReceived == 0) revert TransferFailed();
            amount = actualReceived;
        }

        // Update order data
        order.amount = amount;
        order.user = msg.sender;
        order.tokenType = tokenType;
        order.settled = false;

        emit OrderCreated(requestId, msg.sender, amount, tokenType);
    }

    function settleOrder(bytes32 requestId, bool success) 
        external 
        nonReentrant 
        onlyOwner 
        onlyUnsettled(requestId) 
        whenNotPaused 
    {
        // Cache storage variable in memory to save gas
        Order storage cachedOrder = _orders[requestId];
        if (cachedOrder.amount == 0) revert InvalidOrder();

        // Cache frequently accessed values to save gas
        uint256 orderAmount = cachedOrder.amount;
        PaymentToken orderTokenType = cachedOrder.tokenType;
        address orderUser = cachedOrder.user;

        cachedOrder.settled = true;

        if (success) {
            // Send to dev wallet
            _sendFunds(devWallet, orderTokenType, orderAmount);
        } else {
            // Refund to user
            _sendFunds(orderUser, orderTokenType, orderAmount);
        }

        emit OrderSettled(requestId, success, orderAmount);
    }

    function refundOrder(bytes32 requestId) 
        external 
        nonReentrant 
        onlyOwner 
        onlyUnsettled(requestId) 
        whenNotPaused 
    {
        // Cache storage variable in memory to save gas
        Order storage cachedOrder = _orders[requestId];
        if (cachedOrder.amount == 0) revert InvalidOrder();

        // Cache frequently accessed values to save gas
        uint256 orderAmount = cachedOrder.amount;
        PaymentToken orderTokenType = cachedOrder.tokenType;
        address orderUser = cachedOrder.user;

        cachedOrder.settled = true;

        // Refund to user
        _sendFunds(orderUser, orderTokenType, orderAmount);

        emit OrderSettled(requestId, false, orderAmount);
    }

    // Internal function to handle fund transfers (reduces code duplication)
    function _sendFunds(address recipient, PaymentToken tokenType, uint256 amount) private {
        if (tokenType == PaymentToken.ETH) {
            (bool sent, ) = recipient.call{value: amount}("");
            if (!sent) revert ETHRefundFailed();
        } else if (tokenType == PaymentToken.USDT) {
            USDT.safeTransfer(recipient, amount);
        } else if (tokenType == PaymentToken.USDC) {
            USDC.safeTransfer(recipient, amount);
        }
    }

    // Admin controls
    function pause() external nonReentrant onlyOwner {
        _pause();
        emit ContractPaused();
    }

    function unpause() external nonReentrant onlyOwner {
        _unpause();
        emit ContractUnpaused();
    }

    function emergencyWithdrawETH(uint256 amount) external nonReentrant onlyOwner {
        (bool sent, ) = msg.sender.call{value: amount}("");
        if (!sent) revert WithdrawFailed();
        emit EmergencyWithdraw(msg.sender, amount);
    }

    function emergencyWithdrawERC20(IERC20 token, uint256 amount) external nonReentrant onlyOwner {
        token.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // View functions for better debugging
    function getOrder(bytes32 requestId) external view returns (Order memory) {
        return _orders[requestId];
    }
    
    function checkAllowance(address user, PaymentToken tokenType) external view returns (uint256) {
        if (tokenType == PaymentToken.USDT) {
            return USDT.allowance(user, _thisContract);
        } else if (tokenType == PaymentToken.USDC) {
            return USDC.allowance(user, _thisContract);
        }
        return 0;
    }
    
    function checkBalance(address user, PaymentToken tokenType) external view returns (uint256) {
        if (tokenType == PaymentToken.USDT) {
            return USDT.balanceOf(user);
        } else if (tokenType == PaymentToken.USDC) {
            return USDC.balanceOf(user);
        } else if (tokenType == PaymentToken.ETH) {
            return user.balance;
        }
        return 0;
    }
    
    // Receive function to accept ETH for orders
    receive() external payable {
        // This function allows the contract to receive ETH for order processing
        // ETH is handled through createOrder function, this is just for receiving
    }
}