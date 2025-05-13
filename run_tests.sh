#!/bin/bash
# run_tests.sh - Simple wrapper to execute tests manually
# This script is part of Milestone 7

# Find the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/test"

# Source the logger
source "$SCRIPT_DIR/lib/logger.sh"

# Load environment variables
source "$SCRIPT_DIR/conf/default.env"

# Override with user environment if available
if [ -f "$SCRIPT_DIR/conf/user.env" ]; then
    source "$SCRIPT_DIR/conf/user.env"
fi

# Display banner
echo -e "\n-----------------------------------------------"
echo "PostgreSQL Server Test Runner"
echo "-----------------------------------------------"

# Execute the actual test script
if [ -f "$TEST_DIR/run_tests.sh" ]; then
    log_info "Starting test execution..."
    # Ensure proper permissions
    chmod +x "$TEST_DIR/run_tests.sh"
    # Run tests with explicit output
    exec "$TEST_DIR/run_tests.sh"
else
    log_error "Test runner not found at: $TEST_DIR/run_tests.sh"
    exit 1
fi 