// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PaycryptImproved
 * @dev ERC20-only payment processing for utility payments - supports stablecoins and other tokens
 */
contract PaycryptImproved is 
    Initializable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable 
{
    using SafeERC20 for IERC20;
    
    // Enums
    enum OrderStatus { PENDING, SUCCESSFUL, FAILED }
    
    // Structs
    struct Order {
        uint256 orderId;
        string requestId;
        address user;
        address token;
        uint256 amount;
        OrderStatus status;
        uint256 timestamp;
    }
    
    struct TokenInfo {
        string name;
        string symbol;
        uint8 decimals;
        bool isSupported;
        uint256 orderLimit;
        uint256 minOrderAmount;
    }
    
    // State variables
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userOrders;
    mapping(address => TokenInfo) public supportedTokens;
    mapping(address => bool) public blacklistedUsers;
    mapping(address => bool) public admins;
    
    address[] public tokenList;
    uint256 public nextOrderId;
    uint256 public totalSuccessfulOrders;
    uint256 public totalFailedOrders;
    
    // Per-token volume tracking
    mapping(address => uint256) public tokenVolume;
    
    // Events
    event TokenOrderCreated(uint256 indexed orderId, string indexed requestId, address indexed user, address token, uint256 amount);
    event OrderStatusUpdated(uint256 indexed orderId, OrderStatus indexed status, address indexed updatedBy);
    event TokenAdded(address indexed token, string name, string symbol, uint8 decimals);
    event TokenStatusUpdated(address indexed token, bool status);
    event OrderLimitUpdated(address indexed token, uint256 newLimit);
    event MinOrderAmountUpdated(address indexed token, uint256 newMinAmount);
    event UserBlacklisted(address indexed user, bool status);
    event AdminUpdated(address indexed admin, bool status);
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);
    
    // Modifiers
    modifier onlyAdmin() {
        require(admins[msg.sender] || msg.sender == owner(), "Not admin or owner");
        _;
    }
    
    modifier notBlacklisted(address user) {
        require(!blacklistedUsers[user], "User blacklisted");
        _;
    }
    
    modifier validAddress(address addr) {
        require(addr != address(0), "Invalid address");
        _;
    }
    
    modifier validOrderId(uint256 orderId) {
        require(orderId < nextOrderId, "Invalid order ID");
        _;
    }
    
    modifier supportedToken(address token) {
        require(supportedTokens[token].isSupported, "Token not supported");
        _;
    }
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initialize the contract
     */
    function initialize(address _owner) public initializer {
        require(_owner != address(0), "Invalid owner address");
        
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        
        _transferOwnership(_owner);
        nextOrderId = 1;
    }
    
    /**
     * @dev Reinitialize after upgrade (only owner can be updated)
     */
    function reinitializeOwner(address _newOwner) public {
        require(_newOwner != address(0), "Invalid new owner");
        require(msg.sender == owner() || owner() == address(0), "Not authorized");
        
        _transferOwnership(_newOwner);
    }
    
    // ============ MAIN FUNCTIONS ============
    
    /**
     * @dev Create ERC20 token order
     */
    function createOrder(
        string memory requestId,
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused notBlacklisted(msg.sender) supportedToken(token) {
        require(bytes(requestId).length > 0, "Empty request ID");
        require(amount > 0, "Amount must be greater than 0");
        
        TokenInfo memory tokenInfo = supportedTokens[token];
        require(amount >= tokenInfo.minOrderAmount, "Amount below minimum");
        require(amount <= tokenInfo.orderLimit, "Amount exceeds limit");
        
        // Transfer tokens from user to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        uint256 orderId = nextOrderId++;
        orders[orderId] = Order(orderId, requestId, msg.sender, token, amount, OrderStatus.PENDING, block.timestamp);
        userOrders[msg.sender].push(orderId);
        tokenVolume[token] += amount;
        
        emit TokenOrderCreated(orderId, requestId, msg.sender, token, amount);
    }
    
    /**
     * @dev Mark order successful (admin only)
     */
    function markOrderSuccessful(uint256 orderId) external onlyAdmin validOrderId(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.PENDING, "Order not pending");
        
        order.status = OrderStatus.SUCCESSFUL;
        totalSuccessfulOrders++;
        emit OrderStatusUpdated(orderId, OrderStatus.SUCCESSFUL, msg.sender);
    }
    
    /**
     * @dev Mark order failed and refund (admin only)
     */
    function markOrderFailed(uint256 orderId) external onlyAdmin validOrderId(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.PENDING, "Order not pending");
        
        order.status = OrderStatus.FAILED;
        totalFailedOrders++;
        
        // Refund tokens to user
        IERC20(order.token).safeTransfer(order.user, order.amount);
        
        emit OrderStatusUpdated(orderId, OrderStatus.FAILED, msg.sender);
    }
    
    /**
     * @dev Batch process orders for efficiency
     */
    function batchProcessOrders(uint256[] memory orderIds, OrderStatus[] memory statuses) external onlyAdmin {
        require(orderIds.length == statuses.length, "Arrays length mismatch");
        require(orderIds.length <= 50, "Too many orders"); // Gas limit protection
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            OrderStatus status = statuses[i];
            
            require(orderId < nextOrderId, "Invalid order ID");
            Order storage order = orders[orderId];
            require(order.status == OrderStatus.PENDING, "Order not pending");
            
            if (status == OrderStatus.SUCCESSFUL) {
                order.status = OrderStatus.SUCCESSFUL;
                totalSuccessfulOrders++;
            } else if (status == OrderStatus.FAILED) {
                order.status = OrderStatus.FAILED;
                totalFailedOrders++;
                IERC20(order.token).safeTransfer(order.user, order.amount);
            }
            
            emit OrderStatusUpdated(orderId, status, msg.sender);
        }
    }
    
    // ============ ADMIN FUNCTIONS ============
    
    function addSupportedToken(
        address tokenAddress, 
        string memory name, 
        string memory symbol,
        uint8 decimals,
        uint256 orderLimit,
        uint256 minOrderAmount
    ) external onlyOwner validAddress(tokenAddress) {
        require(!supportedTokens[tokenAddress].isSupported, "Token already supported");
        require(bytes(name).length > 0, "Empty name");
        require(bytes(symbol).length > 0, "Empty symbol");
        require(orderLimit > 0, "Invalid order limit");
        require(minOrderAmount <= orderLimit, "Min amount exceeds limit");
        
        supportedTokens[tokenAddress] = TokenInfo(name, symbol, decimals, true, orderLimit, minOrderAmount);
        tokenList.push(tokenAddress);
        
        emit TokenAdded(tokenAddress, name, symbol, decimals);
    }
    
    function setTokenStatus(address token, bool status) external onlyAdmin {
        require(supportedTokens[token].decimals > 0, "Token not added");
        supportedTokens[token].isSupported = status;
        emit TokenStatusUpdated(token, status);
    }
    
    function updateOrderLimit(address token, uint256 newLimit) external onlyOwner supportedToken(token) {
        require(newLimit > 0, "Invalid limit");
        require(newLimit >= supportedTokens[token].minOrderAmount, "Limit below min amount");
        supportedTokens[token].orderLimit = newLimit;
        emit OrderLimitUpdated(token, newLimit);
    }
    
    function updateMinOrderAmount(address token, uint256 newMinAmount) external onlyOwner supportedToken(token) {
        require(newMinAmount <= supportedTokens[token].orderLimit, "Min amount exceeds limit");
        supportedTokens[token].minOrderAmount = newMinAmount;
        emit MinOrderAmountUpdated(token, newMinAmount);
    }
    
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner validAddress(token) {
        require(amount > 0, "Invalid amount");
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount, owner());
    }
    
    function addToBlacklist(address user) external onlyAdmin validAddress(user) {
        blacklistedUsers[user] = true;
        emit UserBlacklisted(user, true);
    }
    
    function removeFromBlacklist(address user) external onlyAdmin {
        blacklistedUsers[user] = false;
        emit UserBlacklisted(user, false);
    }
    
    function setAdmin(address admin, bool status) external onlyOwner validAddress(admin) {
        admins[admin] = status;
        emit AdminUpdated(admin, status);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ============ VIEW FUNCTIONS ============
    
    function getOrder(uint256 orderId) external view validOrderId(orderId) returns (Order memory) {
        return orders[orderId];
    }
    
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }
    
    function getUserOrdersPaginated(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory allOrders = userOrders[user];
        if (offset >= allOrders.length) {
            return new uint256[](0);
        }
        
        uint256 end = offset + limit;
        if (end > allOrders.length) {
            end = allOrders.length;
        }
        
        uint256[] memory paginatedOrders = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            paginatedOrders[i - offset] = allOrders[i];
        }
        
        return paginatedOrders;
    }
    
    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }
    
    function isTokenSupported(address token) external view returns (bool) {
        return supportedTokens[token].isSupported;
    }
    
    function getOrderLimit(address token) external view returns (uint256) {
        return supportedTokens[token].orderLimit;
    }
    
    function getMinOrderAmount(address token) external view returns (uint256) {
        return supportedTokens[token].minOrderAmount;
    }
    
    function isBlacklisted(address user) external view returns (bool) {
        return blacklistedUsers[user];
    }
    
    function checkAllowance(address user, address token) external view returns (uint256) {
        return IERC20(token).allowance(user, address(this));
    }
    
    function checkBalance(address user, address token) external view returns (uint256) {
        return IERC20(token).balanceOf(user);
    }
    
    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return supportedTokens[token];
    }
    
    function getTokenVolume(address token) external view returns (uint256) {
        return tokenVolume[token];
    }
    
    function getTotalVolume() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < tokenList.length; i++) {
            total += tokenVolume[tokenList[i]];
        }
        return total;
    }
    
    function getContractStats() external view returns (
        uint256 totalOrders,
        uint256 successfulOrders,
        uint256 failedOrders,
        uint256 pendingOrders,
        uint256 supportedTokenCount
    ) {
        totalOrders = nextOrderId - 1;
        successfulOrders = totalSuccessfulOrders;
        failedOrders = totalFailedOrders;
        pendingOrders = totalOrders - successfulOrders - failedOrders;
        supportedTokenCount = tokenList.length;
    }
    
    function version() external pure returns (string memory) {
        return "2.2.0-ERC20";
    }
}