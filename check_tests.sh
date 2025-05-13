#!/bin/bash
# check_tests.sh - Diagnostic script for checking test environment
# Part of Milestone 7

# Find the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/test"

# Define colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Print banner
echo -e "${BOLD}${BLUE}"
echo "======================================================"
echo "  PostgreSQL Server Test Environment Diagnostics"
echo "======================================================"
echo -e "${NC}"

# Check if running as root
echo -e "${BOLD}User Check:${NC}"
if [ "$(id -u)" -eq 0 ]; then
    echo -e "✓ ${GREEN}Running as root${NC}"
else
    echo -e "✗ ${RED}Not running as root - some tests may fail${NC}"
fi
echo ""

# Check test directory
echo -e "${BOLD}Test Directory Check:${NC}"
if [ -d "$TEST_DIR" ]; then
    echo -e "✓ ${GREEN}Test directory exists: $TEST_DIR${NC}"
    
    # Check test runner
    if [ -f "$TEST_DIR/run_tests.sh" ]; then
        echo -e "✓ ${GREEN}Test runner exists: $TEST_DIR/run_tests.sh${NC}"
        
        # Check permissions
        if [ -x "$TEST_DIR/run_tests.sh" ]; then
            echo -e "✓ ${GREEN}Test runner is executable${NC}"
        else
            echo -e "✗ ${RED}Test runner is not executable${NC}"
            echo -e "${YELLOW}Fixing permissions...${NC}"
            chmod +x "$TEST_DIR/run_tests.sh" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "✓ ${GREEN}Fixed test runner permissions${NC}"
            else
                echo -e "✗ ${RED}Failed to fix permissions${NC}"
            fi
        fi
    else
        echo -e "✗ ${RED}Test runner not found${NC}"
    fi
else
    echo -e "✗ ${RED}Test directory not found: $TEST_DIR${NC}"
    exit 1
fi
echo ""

# Check test files
echo -e "${BOLD}Test Files Check:${NC}"
test_files=("$TEST_DIR"/test_*.sh)
if [ ${#test_files[@]} -eq 0 ] || [ ! -f "${test_files[0]}" ]; then
    echo -e "✗ ${RED}No test files found${NC}"
    ls -la "$TEST_DIR"
else
    echo -e "✓ ${GREEN}Found ${#test_files[@]} test files${NC}"
    
    # List all test files
    echo ""
    echo -e "${BOLD}Available Test Files:${NC}"
    for test_file in "${test_files[@]}"; do
        base_name=$(basename "$test_file")
        
        # Check if executable
        if [ -x "$test_file" ]; then
            echo -e "✓ ${GREEN}$base_name${NC} (executable)"
        else
            echo -e "✗ ${YELLOW}$base_name${NC} (not executable, fixing...)"
            chmod +x "$test_file" 2>/dev/null
        fi
    done
    
    # Make sure all test files are executable
    echo ""
    echo -e "${BOLD}Making all test files executable:${NC}"
    chmod +x "$TEST_DIR"/test_*.sh 2>/dev/null
    echo -e "${GREEN}Done${NC}"
fi
echo ""

# Check environment files
echo -e "${BOLD}Environment Files Check:${NC}"
if [ -f "$SCRIPT_DIR/conf/default.env" ]; then
    echo -e "✓ ${GREEN}Default environment file exists${NC}"
else
    echo -e "✗ ${RED}Default environment file not found${NC}"
fi

if [ -f "$SCRIPT_DIR/conf/user.env" ]; then
    echo -e "✓ ${GREEN}User environment file exists${NC}"
else
    echo -e "✗ ${YELLOW}User environment file not found (using defaults)${NC}"
fi
echo ""

# Check logger
echo -e "${BOLD}Logger Check:${NC}"
if [ -f "$SCRIPT_DIR/lib/logger.sh" ]; then
    echo -e "✓ ${GREEN}Logger script exists${NC}"
else
    echo -e "✗ ${RED}Logger script not found${NC}"
fi
echo ""

# Try running a simple test file
echo -e "${BOLD}${BLUE}"
echo "======================================================"
echo "  Attempting to Run Test Runner"
echo "======================================================"
echo -e "${NC}"

# Run the test runner with diagnostic output
if [ -f "$TEST_DIR/run_tests.sh" ]; then
    # Make executable
    chmod +x "$TEST_DIR/run_tests.sh"
    
    # Run with bash explicitly
    bash "$TEST_DIR/run_tests.sh"
    exit_code=$?
    
    echo ""
    echo -e "${BOLD}Test runner exited with code: $exit_code${NC}"
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Test runner executed successfully!${NC}"
    else
        echo -e "${RED}Test runner encountered issues.${NC}"
    fi
else
    echo -e "${RED}Cannot run test runner - file not found${NC}"
fi

echo ""
echo -e "${BOLD}${BLUE}Diagnostics complete.${NC}" 