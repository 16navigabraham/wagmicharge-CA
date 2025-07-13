// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

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
    error USDTTransferFailed();
    error USDCTransferFailed();
    error InvalidTokenType();
    error InvalidOrder();
    error ETHDevPayoutFailed();
    error USDTDevPayoutFailed();
    error USDCDevPayoutFailed();
    error ETHRefundFailed();
    error USDTRefundFailed();
    error USDCRefundFailed();
    error WithdrawFailed();
    error ERC20WithdrawFailed();

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
    ) payable Ownable(initialOwner) {
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
        if (_orders[requestId].user != address(0)) revert DuplicateOrder();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        if (tokenType == PaymentToken.ETH) {
            if (msg.value != amount) revert ETHMismatch();
        } else if (tokenType == PaymentToken.USDT) {
            // Handle fee-on-transfer tokens by checking balance before and after
            uint256 balanceBefore = USDT.balanceOf(_thisContract);
            USDT.safeTransferFrom(msg.sender, _thisContract, amount);
            uint256 balanceAfter = USDT.balanceOf(_thisContract);
            
            // Update amount to actual received amount
            amount = balanceAfter - balanceBefore;
            if (amount == 0) revert USDTTransferFailed();
        } else if (tokenType == PaymentToken.USDC) {
            // Handle fee-on-transfer tokens by checking balance before and after
            uint256 balanceBefore = USDC.balanceOf(_thisContract);
            USDC.safeTransferFrom(msg.sender, _thisContract, amount);
            uint256 balanceAfter = USDC.balanceOf(_thisContract);
            
            // Update amount to actual received amount
            amount = balanceAfter - balanceBefore;
            if (amount == 0) revert USDCTransferFailed();
        } else {
            revert InvalidTokenType();
        }

        // Create order with empty struct first, then assign individually for gas optimization
        Order storage newOrder = _orders[requestId];
        newOrder.amount = amount;
        newOrder.user = msg.sender;
        newOrder.tokenType = tokenType;
        newOrder.settled = false;

        emit OrderCreated(requestId, msg.sender, amount, tokenType);
    }

    function settleOrder(bytes32 requestId, bool success) 
        external 
        payable 
        nonReentrant 
        onlyOwner 
        onlyUnsettled(requestId) 
        whenNotPaused 
    {
        // Cache storage variable in memory to save gas
        Order storage cachedOrder = _orders[requestId];
        if (cachedOrder.amount == 0) revert InvalidOrder();

        cachedOrder.settled = true;

        // Cache frequently accessed values
        uint256 orderAmount = cachedOrder.amount;
        PaymentToken orderTokenType = cachedOrder.tokenType;
        address orderUser = cachedOrder.user;

        if (success) {
            // Inline _payout logic to save gas
            if (orderTokenType == PaymentToken.ETH) {
                (bool sent, ) = devWallet.call{value: orderAmount}("");
                if (!sent) revert ETHDevPayoutFailed();
            } else if (orderTokenType == PaymentToken.USDT) {
                USDT.safeTransfer(devWallet, orderAmount);
            } else if (orderTokenType == PaymentToken.USDC) {
                USDC.safeTransfer(devWallet, orderAmount);
            }
        } else {
            // Inline _refund logic to save gas
            if (orderTokenType == PaymentToken.ETH) {
                (bool sent, ) = orderUser.call{value: orderAmount}("");
                if (!sent) revert ETHRefundFailed();
            } else if (orderTokenType == PaymentToken.USDT) {
                USDT.safeTransfer(orderUser, orderAmount);
            } else if (orderTokenType == PaymentToken.USDC) {
                USDC.safeTransfer(orderUser, orderAmount);
            }
        }

        emit OrderSettled(requestId, success, orderAmount);
    }

    // Admin controls - marked as payable to save gas for legitimate callers
    function pause() external payable nonReentrant onlyOwner {
        _pause();
        emit ContractPaused();
    }

    function unpause() external payable nonReentrant onlyOwner {
        _unpause();
        emit ContractUnpaused();
    }

    function emergencyWithdrawETH(uint256 amount) external payable nonReentrant onlyOwner {
        (bool sent, ) = msg.sender.call{value: amount}("");
        if (!sent) revert WithdrawFailed();
        emit EmergencyWithdraw(msg.sender, amount);
    }

    function emergencyWithdrawERC20(IERC20 token, uint256 amount) external payable nonReentrant onlyOwner {
        token.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    function cancelOrder(bytes32 requestId) external payable nonReentrant onlyOwner onlyUnsettled(requestId) {
        // Cache storage variable in memory to save gas
        Order storage cachedOrder = _orders[requestId];
        if (cachedOrder.amount == 0) revert InvalidOrder();

        // Cache frequently accessed values
        uint256 orderAmount = cachedOrder.amount;
        PaymentToken orderTokenType = cachedOrder.tokenType;
        address orderUser = cachedOrder.user;

        cachedOrder.settled = true;
        
        // Use delete to reset amount to save gas instead of manual assignment
        delete cachedOrder.amount;

        // Refund to user
        if (orderTokenType == PaymentToken.ETH) {
            (bool sent, ) = orderUser.call{value: orderAmount}("");
            if (!sent) revert ETHRefundFailed();
        } else if (orderTokenType == PaymentToken.USDT) {
            USDT.safeTransfer(orderUser, orderAmount);
        } else if (orderTokenType == PaymentToken.USDC) {
            USDC.safeTransfer(orderUser, orderAmount);
        }

        emit OrderSettled(requestId, false, orderAmount);
    }

    // View
    function getOrder(bytes32 requestId) external view returns (Order memory) {
        return _orders[requestId];
    }
    
    // Receive function with specific purpose - to receive ETH for orders
    receive() external payable {
        // This function specifically allows the contract to receive ETH for order processing
    }
}