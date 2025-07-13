// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/CryptopayEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock fee-on-transfer token
contract MockFeeOnTransferToken is ERC20 {
    uint256 public transferFee = 100; // 1% fee
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * transferFee) / 10000;
        uint256 actualAmount = amount - fee;
        
        _transfer(_msgSender(), to, actualAmount);
        if (fee > 0) {
            _transfer(_msgSender(), address(0), fee); // Burn fee
        }
        
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        
        uint256 fee = (amount * transferFee) / 10000;
        uint256 actualAmount = amount - fee;
        
        _transfer(from, to, actualAmount);
        if (fee > 0) {
            _transfer(from, address(0), fee); // Burn fee
        }
        
        return true;
    }
}

contract CryptopayEscrowTest is Test {
    CryptopayEscrow public escrow;
    MockERC20 public usdt;
    MockERC20 public usdc;
    MockFeeOnTransferToken public feeToken;
    
    address public owner = address(0x1);
    address public devWallet = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public attacker = address(0x5);
    
    bytes32 public constant REQUEST_ID_1 = keccak256("request1");
    bytes32 public constant REQUEST_ID_2 = keccak256("request2");
    bytes32 public constant REQUEST_ID_3 = keccak256("request3");
    
    uint256 public constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 public constant INITIAL_TOKEN_BALANCE = 1000000 * 10**18;
    
    event OrderCreated(bytes32 indexed requestId, address indexed user, uint256 amount, CryptopayEscrow.PaymentToken token);
    event OrderSettled(bytes32 indexed requestId, bool success, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event ContractPaused();
    event ContractUnpaused();
    
    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT");
        usdc = new MockERC20("USDC", "USDC");
        feeToken = new MockFeeOnTransferToken("FeeToken", "FEE");
        
        // Deploy escrow contract
        escrow = new CryptopayEscrow(devWallet, address(usdt), address(usdc), owner);
        
        // Fund test addresses
        vm.deal(user1, INITIAL_ETH_BALANCE);
        vm.deal(user2, INITIAL_ETH_BALANCE);
        vm.deal(attacker, INITIAL_ETH_BALANCE);
        
        // Distribute tokens to users
        usdt.transfer(user1, INITIAL_TOKEN_BALANCE);
        usdt.transfer(user2, INITIAL_TOKEN_BALANCE);
        usdc.transfer(user1, INITIAL_TOKEN_BALANCE);
        usdc.transfer(user2, INITIAL_TOKEN_BALANCE);
        
        feeToken.transfer(user1, INITIAL_TOKEN_BALANCE);
        feeToken.transfer(user2, INITIAL_TOKEN_BALANCE);
        
        // Approve escrow to spend tokens
        vm.startPrank(user1);
        usdt.approve(address(escrow), type(uint256).max);
        usdc.approve(address(escrow), type(uint256).max);
        feeToken.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        usdt.approve(address(escrow), type(uint256).max);
        usdc.approve(address(escrow), type(uint256).max);
        feeToken.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }
    
    // Constructor Tests
    function test_constructor_Success() public {
        assertEq(escrow.devWallet(), devWallet);
        assertEq(address(escrow.USDT()), address(usdt));
        assertEq(address(escrow.USDC()), address(usdc));
        assertEq(escrow.owner(), owner);
    }
    
    function test_constructor_RevertDevWalletZeroAddress() public {
        vm.expectRevert(CryptopayEscrow.DevWalletZeroAddress.selector);
        new CryptopayEscrow(address(0), address(usdt), address(usdc), owner);
    }
    
    function test_constructor_RevertUSDTZeroAddress() public {
        vm.expectRevert(CryptopayEscrow.USDTZeroAddress.selector);
        new CryptopayEscrow(devWallet, address(0), address(usdc), owner);
    }
    
    function test_constructor_RevertUSDCZeroAddress() public {
        vm.expectRevert(CryptopayEscrow.USDCZeroAddress.selector);
        new CryptopayEscrow(devWallet, address(usdt), address(0), owner);
    }
    
    // ETH Order Tests
    function test_createOrder_ETH_Success() public {
        uint256 amount = 1 ether;
        
        vm.expectEmit(true, true, false, true);
        emit OrderCreated(REQUEST_ID_1, user1, amount, CryptopayEscrow.PaymentToken.ETH);
        
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertEq(order.amount, amount);
        assertEq(order.user, user1);
        assertEq(uint256(order.tokenType), uint256(CryptopayEscrow.PaymentToken.ETH));
        assertFalse(order.settled);
        assertEq(address(escrow).balance, amount);
    }
    
    function test_createOrder_ETH_RevertETHMismatch() public {
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.5 ether;
        
        vm.expectRevert(CryptopayEscrow.ETHMismatch.selector);
        vm.prank(user1);
        escrow.createOrder{value: wrongValue}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
    }
    
    function test_createOrder_ETH_RevertAmountZero() public {
        vm.expectRevert(CryptopayEscrow.AmountMustBeGreaterThanZero.selector);
        vm.prank(user1);
        escrow.createOrder{value: 0}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, 0);
    }
    
    // USDT Order Tests
    function test_createOrder_USDT_Success() public {
        uint256 amount = 1000 * 10**6; // 1000 USDT
        
        vm.expectEmit(true, true, false, true);
        emit OrderCreated(REQUEST_ID_1, user1, amount, CryptopayEscrow.PaymentToken.USDT);
        
        vm.prank(user1);
        escrow.createOrder(REQUEST_ID_1, CryptopayEscrow.PaymentToken.USDT, amount);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertEq(order.amount, amount);
        assertEq(order.user, user1);
        assertEq(uint256(order.tokenType), uint256(CryptopayEscrow.PaymentToken.USDT));
        assertFalse(order.settled);
        assertEq(usdt.balanceOf(address(escrow)), amount);
    }
    
    // USDC Order Tests
    function test_createOrder_USDC_Success() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC
        
        vm.expectEmit(true, true, false, true);
        emit OrderCreated(REQUEST_ID_1, user1, amount, CryptopayEscrow.PaymentToken.USDC);
        
        vm.prank(user1);
        escrow.createOrder(REQUEST_ID_1, CryptopayEscrow.PaymentToken.USDC, amount);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertEq(order.amount, amount);
        assertEq(order.user, user1);
        assertEq(uint256(order.tokenType), uint256(CryptopayEscrow.PaymentToken.USDC));
        assertFalse(order.settled);
        assertEq(usdc.balanceOf(address(escrow)), amount);
    }
    
    function test_createOrder_RevertDuplicateOrder() public {
        uint256 amount = 1 ether;
        
        vm.startPrank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        vm.expectRevert(CryptopayEscrow.DuplicateOrder.selector);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        vm.stopPrank();
    }
    
    function test_createOrder_RevertInvalidTokenType() public {
        uint256 amount = 1 ether;
        
        vm.expectRevert(CryptopayEscrow.InvalidTokenType.selector);
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken(3), amount);
    }
    
    // Settlement Tests
    function test_settleOrder_ETH_Success() public {
        uint256 amount = 1 ether;
        uint256 devWalletBalanceBefore = devWallet.balance;
        
        // Create order
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        vm.expectEmit(true, false, false, true);
        emit OrderSettled(REQUEST_ID_1, true, amount);
        
        // Settle successfully
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, true);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertTrue(order.settled);
        assertEq(devWallet.balance, devWalletBalanceBefore + amount);
        assertEq(address(escrow).balance, 0);
    }
    
    function test_settleOrder_ETH_Refund() public {
        uint256 amount = 1 ether;
        uint256 user1BalanceBefore = user1.balance;
        
        // Create order
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        vm.expectEmit(true, false, false, true);
        emit OrderSettled(REQUEST_ID_1, false, amount);
        
        // Settle with refund
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, false);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertTrue(order.settled);
        assertEq(user1.balance, user1BalanceBefore);
        assertEq(address(escrow).balance, 0);
    }
    
    function test_settleOrder_USDT_Success() public {
        uint256 amount = 1000 * 10**6;
        uint256 devWalletBalanceBefore = usdt.balanceOf(devWallet);
        
        // Create order
        vm.prank(user1);
        escrow.createOrder(REQUEST_ID_1, CryptopayEscrow.PaymentToken.USDT, amount);
        
        // Settle successfully
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, true);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertTrue(order.settled);
        assertEq(usdt.balanceOf(devWallet), devWalletBalanceBefore + amount);
        assertEq(usdt.balanceOf(address(escrow)), 0);
    }
    
    function test_settleOrder_USDC_Refund() public {
        uint256 amount = 1000 * 10**6;
        uint256 user1BalanceBefore = usdc.balanceOf(user1);
        
        // Create order
        vm.prank(user1);
        escrow.createOrder(REQUEST_ID_1, CryptopayEscrow.PaymentToken.USDC, amount);
        
        // Settle with refund
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, false);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertTrue(order.settled);
        assertEq(usdc.balanceOf(user1), user1BalanceBefore);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function test_settleOrder_RevertAlreadySettled() public {
        uint256 amount = 1 ether;
        
        // Create and settle order
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, true);
        
        // Try to settle again
        vm.expectRevert(CryptopayEscrow.AlreadySettled.selector);
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, true);
    }
    
    function test_settleOrder_RevertInvalidOrder() public {
        vm.expectRevert(CryptopayEscrow.InvalidOrder.selector);
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, true);
    }
    
    function test_settleOrder_RevertNotOwner() public {
        uint256 amount = 1 ether;
        
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vm.prank(user1);
        escrow.settleOrder(REQUEST_ID_1, true);
    }
    
    // Cancel Order Tests
    function test_cancelOrder_Success() public {
        uint256 amount = 1 ether;
        uint256 user1BalanceBefore = user1.balance;
        
        // Create order
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        vm.expectEmit(true, false, false, true);
        emit OrderSettled(REQUEST_ID_1, false, amount);
        
        // Cancel order
        vm.prank(owner);
        escrow.cancelOrder(REQUEST_ID_1);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertTrue(order.settled);
        assertEq(order.amount, 0); // Should be deleted
        assertEq(user1.balance, user1BalanceBefore);
    }
    
    // Pause/Unpause Tests
    function test_pause_Success() public {
        vm.expectEmit(false, false, false, true);
        emit ContractPaused();
        
        vm.prank(owner);
        escrow.pause();
        
        assertTrue(escrow.paused());
    }
    
    function test_unpause_Success() public {
        vm.prank(owner);
        escrow.pause();
        
        vm.expectEmit(false, false, false, true);
        emit ContractUnpaused();
        
        vm.prank(owner);
        escrow.unpause();
        
        assertFalse(escrow.paused());
    }
    
    function test_createOrder_RevertWhenPaused() public {
        vm.prank(owner);
        escrow.pause();
        
        vm.expectRevert();
        vm.prank(user1);
        escrow.createOrder{value: 1 ether}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, 1 ether);
    }
    
    // Emergency Withdraw Tests
    function test_emergencyWithdrawETH_Success() public {
        uint256 amount = 1 ether;
        
        // Fund contract
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        uint256 ownerBalanceBefore = owner.balance;
        
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdraw(owner, amount);
        
        vm.prank(owner);
        escrow.emergencyWithdrawETH(amount);
        
        assertEq(owner.balance, ownerBalanceBefore + amount);
        assertEq(address(escrow).balance, 0);
    }
    
    function test_emergencyWithdrawERC20_Success() public {
        uint256 amount = 1000 * 10**6;
        
        // Fund contract
        vm.prank(user1);
        escrow.createOrder(REQUEST_ID_1, CryptopayEscrow.PaymentToken.USDT, amount);
        
        uint256 ownerBalanceBefore = usdt.balanceOf(owner);
        
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdraw(owner, amount);
        
        vm.prank(owner);
        escrow.emergencyWithdrawERC20(usdt, amount);
        
        assertEq(usdt.balanceOf(owner), ownerBalanceBefore + amount);
        assertEq(usdt.balanceOf(address(escrow)), 0);
    }
    
    // Reentrancy Tests
    function test_reentrancy_createOrder() public {
        ReentrancyAttacker attackerContract = new ReentrancyAttacker(escrow);
        vm.deal(address(attackerContract), 10 ether);
        
        vm.expectRevert();
        attackerContract.attackCreateOrder();
    }
    
    // Fee-on-Transfer Token Tests
    function test_feeOnTransferToken_HandledCorrectly() public {
        // Deploy escrow with fee token as USDT
        CryptopayEscrow feeEscrow = new CryptopayEscrow(devWallet, address(feeToken), address(usdc), owner);
        
        vm.prank(user1);
        feeToken.approve(address(feeEscrow), type(uint256).max);
        
        uint256 amount = 1000 * 10**18;
        uint256 expectedFee = (amount * 100) / 10000; // 1% fee
        uint256 expectedAmount = amount - expectedFee;
        
        vm.prank(user1);
        feeEscrow.createOrder(REQUEST_ID_1, CryptopayEscrow.PaymentToken.USDT, amount);
        
        CryptopayEscrow.Order memory order = feeEscrow.getOrder(REQUEST_ID_1);
        assertEq(order.amount, expectedAmount);
        assertEq(feeToken.balanceOf(address(feeEscrow)), expectedAmount);
    }
    
    // Gas Optimization Tests
    function test_gasOptimization_createOrder() public {
        uint256 amount = 1 ether;
        
        uint256 gasBefore = gasleft();
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for createOrder:", gasUsed);
        // Should be reasonable gas usage
        assertLt(gasUsed, 200000);
    }
    
    // Edge Cases
    function test_multipleOrders_DifferentTokens() public {
        uint256 ethAmount = 1 ether;
        uint256 usdtAmount = 1000 * 10**6;
        uint256 usdcAmount = 2000 * 10**6;
        
        // Create orders
        vm.prank(user1);
        escrow.createOrder{value: ethAmount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, ethAmount);
        
        vm.prank(user1);
        escrow.createOrder(REQUEST_ID_2, CryptopayEscrow.PaymentToken.USDT, usdtAmount);
        
        vm.prank(user2);
        escrow.createOrder(REQUEST_ID_3, CryptopayEscrow.PaymentToken.USDC, usdcAmount);
        
        // Verify balances
        assertEq(address(escrow).balance, ethAmount);
        assertEq(usdt.balanceOf(address(escrow)), usdtAmount);
        assertEq(usdc.balanceOf(address(escrow)), usdcAmount);
        
        // Settle all orders
        vm.startPrank(owner);
        escrow.settleOrder(REQUEST_ID_1, true);
        escrow.settleOrder(REQUEST_ID_2, true);
        escrow.settleOrder(REQUEST_ID_3, false); // Refund
        vm.stopPrank();
        
        // Verify final balances
        assertEq(address(escrow).balance, 0);
        assertEq(usdt.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(devWallet.balance, ethAmount);
        assertEq(usdt.balanceOf(devWallet), usdtAmount);
        assertEq(usdc.balanceOf(user2), INITIAL_TOKEN_BALANCE); // Refunded
    }
    
    function test_receive_function() public {
        uint256 amount = 1 ether;
        
        (bool success, ) = address(escrow).call{value: amount}("");
        assertTrue(success);
        assertEq(address(escrow).balance, amount);
    }
    
    // Fuzzing Tests
    function testFuzz_createOrder_ETH(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        
        vm.deal(user1, amount);
        
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        CryptopayEscrow.Order memory order = escrow.getOrder(REQUEST_ID_1);
        assertEq(order.amount, amount);
        assertEq(address(escrow).balance, amount);
    }
    
    function testFuzz_settleOrder_Success(uint256 amount, bool success) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        
        vm.deal(user1, amount);
        
        vm.prank(user1);
        escrow.createOrder{value: amount}(REQUEST_ID_1, CryptopayEscrow.PaymentToken.ETH, amount);
        
        uint256 devBalanceBefore = devWallet.balance;
        uint256 userBalanceBefore = user1.balance;
        
        vm.prank(owner);
        escrow.settleOrder(REQUEST_ID_1, success);
        
        if (success) {
            assertEq(devWallet.balance, devBalanceBefore + amount);
        } else {
            assertEq(user1.balance, userBalanceBefore + amount);
        }
    }
}

// Contract for testing reentrancy attacks
contract ReentrancyAttacker {
    CryptopayEscrow public escrow;
    bytes32 public constant ATTACK_REQUEST_ID = keccak256("attack");
    
    constructor(CryptopayEscrow _escrow) {
        escrow = _escrow;
    }
    
    function attackCreateOrder() external {
        escrow.createOrder{value: 1 ether}(ATTACK_REQUEST_ID, CryptopayEscrow.PaymentToken.ETH, 1 ether);
    }
    
    receive() external payable {
        if (address(escrow).balance >= 1 ether) {
            escrow.createOrder{value: 1 ether}(keccak256(abi.encode(block.timestamp)), CryptopayEscrow.PaymentToken.ETH, 1 ether);
        }
    }
}