// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PaycryptV1 is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    
    string public constant VERSION = "1.0.1";
    
    struct Order {
        uint256 amount;
        uint256 createdAt;
        address user;
        address token;
        bool settled;
        uint8 orderType;
    }

    struct TokenInfo {
        bool isSupported;
        bool isActive;
        uint8 decimals;
        uint256 maxOrderAmount;
        uint256 totalVolume;
        string name;
    }

    struct GovernanceParams {
        uint256 settlementDelay;
        uint256 dailyWithdrawLimit;
        uint256 maxBatchSize;
        uint256 emergencyDelay;
        bool requireMultiSig;
    }

    mapping(bytes32 => Order) private _orders;
    mapping(address => TokenInfo) private _supportedTokens;
    mapping(address => uint256) private _tokenIndices;
    
    bytes32[] private _pendingOrders;
    mapping(bytes32 => uint256) private _pendingOrderIndex;
    mapping(uint256 => bytes32[]) private _ordersByDay;
    
    mapping(bytes32 => mapping(address => bool)) private _adminApprovals;
    mapping(bytes32 => uint256) private _approvalCounts;
    address[] public admins;
    uint256 public requiredApprovals;
    
    address private constant ETH_ADDRESS = address(0);
    
    address public immutable devWallet;
    GovernanceParams public governanceParams;
    
    address[] private _tokenList;
    uint256 private constant MAX_TOKENS = 100;
    
    uint256 public lastWithdrawDay;
    uint256 public todayWithdrawn;
    
    bool public emergencyMode;
    uint256 public emergencyActivatedAt;
    
    struct HealthMetrics {
        uint256 totalOrders;
        uint256 totalSettled;
        uint256 totalRefunded;
        uint256 totalVolume;
        uint256 lastActivityAt;
    }
    HealthMetrics public healthMetrics;
    
    address private immutable _thisContract;
    
    event OrderCreated(bytes32 indexed requestId, address indexed user, uint256 amount, address indexed token, uint256 timestamp);
    event OrderCompleted(bytes32 indexed requestId, address indexed devWallet, uint256 amount, address indexed token);
    event OrderRefunded(bytes32 indexed requestId, address indexed user, uint256 amount, address indexed token);
    event BatchSettlementCompleted(uint256 processed, uint256 skipped, uint256 timestamp);
    event TokenAdded(address indexed token, string name, uint256 maxOrderAmount);
    event TokenRemoved(address indexed token);
    event TokenStatusChanged(address indexed token, bool isActive);
    event TokenMaxAmountUpdated(address indexed token, uint256 newMaxAmount);
    event EmergencyWithdrawETH(address indexed to, uint256 amount);
    event EmergencyWithdrawERC20(address indexed token, address indexed to, uint256 amount);
    event DailyLimitUpdated(uint256 newLimit);
    event ContractPaused(address indexed by, string reason);
    event ContractUnpaused(address indexed by);
    event EmergencyModeActivated(address indexed by, string reason);
    event EmergencyModeDeactivated(address indexed by);
    event GovernanceParamsUpdated(address indexed by);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event MultiSigOperationProposed(bytes32 indexed operationId, address indexed proposer);
    event MultiSigOperationExecuted(bytes32 indexed operationId);
    event HealthCheckPerformed(uint256 timestamp, bool healthy);

    error DevWalletZeroAddress();
    error TokenNotSupported();
    error TokenNotActive();
    error TokenAlreadyExists();
    error TokenDoesNotExist();
    error MaxTokensReached();
    error AlreadySettled();
    error DuplicateOrder();
    error AmountMustBeGreaterThanZero();
    error ETHMismatch();
    error InsufficientAllowance();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidOrder();
    error ETHTransferFailed();
    error WithdrawFailed();
    error InvalidTokenAddress();
    error ZeroAddress();
    error InvalidRequestId();
    error SettlementTooEarly();
    error ExceedsMaxOrderAmount();
    error DailyLimitExceeded();
    error InvalidLimit();
    error EmergencyModeActive();
    error InsufficientApprovals();
    error BatchSizeExceeded();
    error ContractNotHealthy();
    error InvalidGovernanceParams();
    error AdminAlreadyExists();
    error AdminDoesNotExist();
    error InvalidApprovalCount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _devWallet) {
        if (_devWallet == address(0)) revert DevWalletZeroAddress();
        devWallet = _devWallet;
        _thisContract = address(this);
        _disableInitializers();
    }

    function initialize(
        address[] calldata _admins,
        uint256 _requiredApprovals
    ) public initializer {
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        governanceParams = GovernanceParams({
            settlementDelay: 1 hours,
            dailyWithdrawLimit: 100 ether,
            maxBatchSize: 50,
            emergencyDelay: 24 hours,
            requireMultiSig: _admins.length > 0
        });
        
        if (_admins.length > 0) {
            for (uint256 i = 0; i < _admins.length; i++) {
                if (_admins[i] == address(0)) revert ZeroAddress();
                admins.push(_admins[i]);
            }
            if (_requiredApprovals == 0 || _requiredApprovals > _admins.length) 
                revert InvalidApprovalCount();
            requiredApprovals = _requiredApprovals;
        }
        
        _addTokenInternal(ETH_ADDRESS, "Ethereum", 18, type(uint256).max);
        healthMetrics.lastActivityAt = block.timestamp;
    }

    function initializeWithOwner(
        address[] calldata _admins,
        uint256 _requiredApprovals,
        address _initialOwner
    ) public initializer {
        __Ownable2Step_init();
        
        if (_initialOwner != address(0)) {
            _transferOwnership(_initialOwner);
        }
        
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        governanceParams = GovernanceParams({
            settlementDelay: 1 hours,
            dailyWithdrawLimit: 100 ether,
            maxBatchSize: 50,
            emergencyDelay: 24 hours,
            requireMultiSig: _admins.length > 0
        });
        
        if (_admins.length > 0) {
            for (uint256 i = 0; i < _admins.length; i++) {
                if (_admins[i] == address(0)) revert ZeroAddress();
                admins.push(_admins[i]);
            }
            if (_requiredApprovals == 0 || _requiredApprovals > _admins.length) 
                revert InvalidApprovalCount();
            requiredApprovals = _requiredApprovals;
        }
        
        _addTokenInternal(ETH_ADDRESS, "Ethereum", 18, type(uint256).max);
        healthMetrics.lastActivityAt = block.timestamp;
    }

    modifier onlyUnsettled(bytes32 requestId) {
        if (_orders[requestId].settled) revert AlreadySettled();
        _;
    }

    modifier onlySupportedToken(address token) {
        TokenInfo storage tokenInfo = _supportedTokens[token];
        if (!tokenInfo.isSupported) revert TokenNotSupported();
        if (!tokenInfo.isActive) revert TokenNotActive();
        _;
    }

    modifier validRequestId(bytes32 requestId) {
        if (requestId == bytes32(0)) revert InvalidRequestId();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    modifier settlementDelay(bytes32 requestId) {
        Order storage order = _orders[requestId];
        if (block.timestamp < order.createdAt + governanceParams.settlementDelay) 
            revert SettlementTooEarly();
        _;
    }

    modifier checkDailyLimit(uint256 amount) {
        _checkDailyLimit(amount);
        _;
    }

    modifier notInEmergency() {
        if (emergencyMode) revert EmergencyModeActive();
        _;
    }

    modifier onlyHealthy() {
        if (!_isContractHealthy()) revert ContractNotHealthy();
        _;
    }

    modifier multiSigRequired(bytes32 operationId) {
        if (governanceParams.requireMultiSig && admins.length > 0) {
            _requireMultiSigApproval(operationId);
        }
        _;
    }

    function _checkDailyLimit(uint256 amount) internal {
        uint256 today = block.timestamp / 1 days;
        if (today > lastWithdrawDay) {
            lastWithdrawDay = today;
            todayWithdrawn = 0;
        }
        if (todayWithdrawn + amount > governanceParams.dailyWithdrawLimit) 
            revert DailyLimitExceeded();
        todayWithdrawn += amount;
    }

    function _isContractHealthy() internal view returns (bool) {
        if (emergencyMode) return false;
        if (paused()) return false;
        if (block.timestamp - healthMetrics.lastActivityAt > 7 days) return false;
        return true;
    }

    function _requireMultiSigApproval(bytes32 operationId) internal {
        if (!_adminApprovals[operationId][msg.sender]) {
            _adminApprovals[operationId][msg.sender] = true;
            _approvalCounts[operationId]++;
            emit MultiSigOperationProposed(operationId, msg.sender);
        }
        
        if (_approvalCounts[operationId] < requiredApprovals) {
            revert InsufficientApprovals();
        }
        
        emit MultiSigOperationExecuted(operationId);
    }

    function addAdmin(address newAdmin) external onlyOwner validAddress(newAdmin) {
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == newAdmin) revert AdminAlreadyExists();
        }
        admins.push(newAdmin);
        emit AdminAdded(newAdmin);
    }

    function removeAdmin(address admin) external onlyOwner {
        bool found = false;
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == admin) {
                admins[i] = admins[admins.length - 1];
                admins.pop();
                found = true;
                break;
            }
        }
        if (!found) revert AdminDoesNotExist();
        
        if (requiredApprovals > admins.length && admins.length > 0) {
            requiredApprovals = admins.length;
        }
        
        emit AdminRemoved(admin);
    }

    function updateGovernanceParams(
        uint256 _settlementDelay,
        uint256 _dailyWithdrawLimit,
        uint256 _maxBatchSize,
        uint256 _emergencyDelay,
        bool _requireMultiSig
    ) external onlyOwner {
        bytes32 operationId = keccak256(abi.encodePacked(
            "updateGovernanceParams",
            _settlementDelay,
            _dailyWithdrawLimit,
            _maxBatchSize,
            _emergencyDelay,
            _requireMultiSig,
            block.timestamp
        ));
        
        if (governanceParams.requireMultiSig && admins.length > 0) {
            _requireMultiSigApproval(operationId);
        }
        
        if (_settlementDelay < 10 minutes || _settlementDelay > 7 days) 
            revert InvalidGovernanceParams();
        if (_dailyWithdrawLimit == 0) revert InvalidGovernanceParams();
        if (_maxBatchSize == 0 || _maxBatchSize > 1000) revert InvalidGovernanceParams();
        if (_emergencyDelay < 1 hours || _emergencyDelay > 30 days) 
            revert InvalidGovernanceParams();
        
        governanceParams.settlementDelay = _settlementDelay;
        governanceParams.dailyWithdrawLimit = _dailyWithdrawLimit;
        governanceParams.maxBatchSize = _maxBatchSize;
        governanceParams.emergencyDelay = _emergencyDelay;
        governanceParams.requireMultiSig = _requireMultiSig;
        
        emit GovernanceParamsUpdated(msg.sender);
    }

    function addToken(address token, string calldata name, uint8 decimals, uint256 maxOrderAmount) 
        external 
        payable
        onlyOwner 
        notInEmergency
    {
        if (_tokenList.length >= MAX_TOKENS) revert MaxTokensReached();
        if (_supportedTokens[token].isSupported) revert TokenAlreadyExists();
        if (maxOrderAmount == 0) revert InvalidLimit();
        
        _addTokenInternal(token, name, decimals, maxOrderAmount);
        emit TokenAdded(token, name, maxOrderAmount);
    }

    function _addTokenInternal(address token, string memory name, uint8 decimals, uint256 maxOrderAmount) 
        internal 
    {
        _tokenIndices[token] = _tokenList.length + 1;
        
        TokenInfo storage tokenInfo = _supportedTokens[token];
        tokenInfo.isSupported = true;
        tokenInfo.isActive = true;
        tokenInfo.decimals = decimals;
        tokenInfo.maxOrderAmount = maxOrderAmount;
        tokenInfo.totalVolume = 0;
        tokenInfo.name = name;
        
        _tokenList.push(token);
    }

    function createOrder(bytes32 requestId, address token, uint256 amount) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        notInEmergency
        validRequestId(requestId)
        onlySupportedToken(token)
        onlyHealthy
    {
        Order storage order = _orders[requestId];
        if (order.user != address(0)) revert DuplicateOrder();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        uint256 maxAmount = _supportedTokens[token].maxOrderAmount;
        if (amount > maxAmount) revert ExceedsMaxOrderAmount();

        if (token == ETH_ADDRESS) {
            if (msg.value != amount) revert ETHMismatch();
        } else {
            IERC20 erc20Token = IERC20(token);
            address msgSender = msg.sender;
            
            uint256 allowance = erc20Token.allowance(msgSender, _thisContract);
            if (allowance < amount) revert InsufficientAllowance();
            
            uint256 userBalance = erc20Token.balanceOf(msgSender);
            if (userBalance < amount) revert InsufficientBalance();
            
            uint256 balanceBefore = erc20Token.balanceOf(_thisContract);
            erc20Token.safeTransferFrom(msgSender, _thisContract, amount);
            uint256 balanceAfter = erc20Token.balanceOf(_thisContract);
            
            uint256 actualReceived = balanceAfter - balanceBefore;
            if (actualReceived == 0) revert TransferFailed();
            amount = actualReceived;
        }

        order.amount = amount;
        order.user = msg.sender;
        order.token = token;
        order.createdAt = block.timestamp;
        order.orderType = 0;
        
        _pendingOrderIndex[requestId] = _pendingOrders.length + 1;
        _pendingOrders.push(requestId);
        
        uint256 today = block.timestamp / 1 days;
        _ordersByDay[today].push(requestId);
        
        healthMetrics.totalOrders++;
        healthMetrics.lastActivityAt = block.timestamp;
        _supportedTokens[token].totalVolume += amount;

        emit OrderCreated(requestId, msg.sender, amount, token, block.timestamp);
    }

    function batchSettleOrders(bytes32[] calldata requestIds, bool[] calldata settlements)
        external
        payable
        nonReentrant
        onlyOwner
        whenNotPaused
        notInEmergency
        returns (uint256 processed, uint256 skipped)
    {
        if (requestIds.length != settlements.length) revert();
        if (requestIds.length == 0) revert();
        if (requestIds.length > governanceParams.maxBatchSize) revert BatchSizeExceeded();

        uint256 totalProcessed = 0;
        uint256 totalSkipped = 0;

        for (uint256 i = 0; i < requestIds.length; i++) {
            bytes32 requestId = requestIds[i];
            bool success = settlements[i];

            Order storage cachedOrder = _orders[requestId];
            if (cachedOrder.amount == 0 || cachedOrder.settled) {
                totalSkipped++;
                continue;
            }

            if (block.timestamp < cachedOrder.createdAt + governanceParams.settlementDelay) {
                totalSkipped++;
                continue;
            }

            try this._processSingleSettlement(requestId, success) {
                totalProcessed++;
                
                if (success) {
                    healthMetrics.totalSettled++;
                } else {
                    healthMetrics.totalRefunded++;
                }
                healthMetrics.lastActivityAt = block.timestamp;
                
            } catch {
                totalSkipped++;
            }
        }

        emit BatchSettlementCompleted(totalProcessed, totalSkipped, block.timestamp);
        return (totalProcessed, totalSkipped);
    }

    function _processSingleSettlement(bytes32 requestId, bool success) 
        external
        payable
    {
        if (msg.sender != address(this)) revert();

        Order storage cachedOrder = _orders[requestId];
        uint256 orderAmount = cachedOrder.amount;
        address orderToken = cachedOrder.token;
        address orderUser = cachedOrder.user;

        cachedOrder.settled = true;
        
        _removePendingOrder(requestId);
        
        address recipient = success ? devWallet : orderUser;
        
        if (success) {
            _checkDailyLimit(orderAmount);
        }
        
        _sendFunds(recipient, orderToken, orderAmount);

        if (success) {
            emit OrderCompleted(requestId, devWallet, orderAmount, orderToken);
        } else {
            emit OrderRefunded(requestId, orderUser, orderAmount, orderToken);
        }
    }

    function _removePendingOrder(bytes32 requestId) internal {
        uint256 index = _pendingOrderIndex[requestId];
        if (index == 0) return;
        
        uint256 arrayIndex = index - 1;
        uint256 lastIndex = _pendingOrders.length - 1;
        
        if (arrayIndex != lastIndex) {
            bytes32 lastOrderId = _pendingOrders[lastIndex];
            _pendingOrders[arrayIndex] = lastOrderId;
            _pendingOrderIndex[lastOrderId] = index;
        }
        
        _pendingOrders.pop();
        delete _pendingOrderIndex[requestId];
    }

    function getSettleableOrders(uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orders, bool hasMore)
    {
        if (limit == 0 || limit > 1000) limit = 100;
        
        uint256 settleableCount = 0;
        uint256 currentTime = block.timestamp;
        uint256 minSettlementTime = currentTime - governanceParams.settlementDelay;
        
        for (uint256 i = offset; i < _pendingOrders.length && settleableCount < limit; i++) {
            bytes32 orderId = _pendingOrders[i];
            Order storage order = _orders[orderId];
            
            if (!order.settled && order.createdAt <= minSettlementTime) {
                settleableCount++;
            }
        }
        
        orders = new bytes32[](settleableCount);
        uint256 collected = 0;
        
        for (uint256 i = offset; i < _pendingOrders.length && collected < settleableCount; i++) {
            bytes32 orderId = _pendingOrders[i];
            Order storage order = _orders[orderId];
            
            if (!order.settled && order.createdAt <= minSettlementTime) {
                orders[collected] = orderId;
                collected++;
            }
        }
        
        hasMore = offset + limit < _pendingOrders.length;
        return (orders, hasMore);
    }

    function getOrdersByDay(uint256 day) external view returns (bytes32[] memory) {
        return _ordersByDay[day];
    }

    function getPendingOrdersCount() external view returns (uint256) {
        return _pendingOrders.length;
    }

    function performHealthCheck() external returns (bool healthy) {
        healthy = _isContractHealthy();
        emit HealthCheckPerformed(block.timestamp, healthy);
        return healthy;
    }

    function activateEmergencyMode(string calldata reason) external onlyOwner {
        bytes32 operationId = keccak256(abi.encodePacked("activateEmergency", reason, block.timestamp));
        
        if (governanceParams.requireMultiSig && admins.length > 0) {
            _requireMultiSigApproval(operationId);
        }
        
        emergencyMode = true;
        emergencyActivatedAt = block.timestamp;
        _pause();
        
        emit EmergencyModeActivated(msg.sender, reason);
    }

    function deactivateEmergencyMode() external onlyOwner {
        if (!emergencyMode) return;
        
        if (block.timestamp < emergencyActivatedAt + governanceParams.emergencyDelay) {
            bytes32 operationId = keccak256(abi.encodePacked("deactivateEmergency", block.timestamp));
            if (governanceParams.requireMultiSig && admins.length > 0) {
                _requireMultiSigApproval(operationId);
            }
        }
        
        emergencyMode = false;
        emergencyActivatedAt = 0;
        _unpause();
        
        emit EmergencyModeDeactivated(msg.sender);
    }

    function _sendFunds(address recipient, address token, uint256 amount) private {
        if (token == ETH_ADDRESS) {
            (bool sent, ) = recipient.call{value: amount}("");
            if (!sent) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        bytes32 operationId = keccak256(abi.encodePacked("upgrade", newImplementation, block.timestamp));
        
        if (governanceParams.requireMultiSig && admins.length > 0) {
            _requireMultiSigApproval(operationId);
        }
    }

    function getOrder(bytes32 requestId) external view returns (Order memory) {
        return _orders[requestId];
    }
    
    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return _supportedTokens[token];
    }
    
    function getHealthMetrics() external view returns (HealthMetrics memory) {
        return healthMetrics;
    }
    
    function getAdmins() external view returns (address[] memory) {
        return admins;
    }
    
    function isAdmin(address addr) external view returns (bool) {
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == addr) return true;
        }
        return false;
    }

    receive() external payable {}
}