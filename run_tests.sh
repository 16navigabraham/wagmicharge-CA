#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🧪 Running CryptopayEscrow Tests${NC}"
echo "================================="

# Clean and build
echo -e "${YELLOW}📦 Building contracts...${NC}"
forge build

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Build successful!${NC}"
echo ""

# Run all tests with gas reporting
echo -e "${YELLOW}🔍 Running all tests...${NC}"
forge test -vvv --gas-report

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Some tests failed!${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ All tests passed!${NC}"

# Run specific test categories
echo ""
echo -e "${YELLOW}🎯 Running specific test categories...${NC}"

echo "▶️  Constructor Tests"
forge test --match-test "test_constructor" -v

echo ""
echo "▶️  Order Creation Tests"
forge test --match-test "test_createOrder" -v

echo ""
echo "▶️  Settlement Tests"
forge test --match-test "test_settleOrder" -v

echo ""
echo "▶️  Security Tests"
forge test --match-test "test_reentrancy" -v

echo ""
echo "▶️  Admin Function Tests"
forge test --match-test "test_pause\|test_unpause\|test_emergencyWithdraw" -v

echo ""
echo "▶️  Edge Cases & Fuzzing Tests"
forge test --match-test "test_multipleOrders\|testFuzz" -v

echo ""
echo "▶️  Gas Optimization Tests"
forge test --match-test "test_gasOptimization" -v

echo ""
echo -e "${YELLOW}📊 Coverage Report${NC}"
forge coverage --report lcov

echo ""
echo -e "${GREEN}🎉 Test suite completed successfully!${NC}"
echo ""
echo -e "${YELLOW}💡 Tips:${NC}"
echo "• Run 'forge test --match-test <pattern>' to run specific tests"
echo "• Use 'forge test -vvvv' for maximum verbosity"
echo "• Check gas usage with 'forge test --gas-report'"
echo "• Generate coverage with 'forge coverage'"