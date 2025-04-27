#!/bin/bash
# run_tests.sh - Run all tests in the test directory
# Part of Milestone 2

# Find the script directory
SCRIPT_DIR="$(cd "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")" && pwd)"
TEST_DIR="$SCRIPT_DIR/test"

# Source the logger
source "$SCRIPT_DIR/lib/logger.sh"

# Load default environment variables
source "$SCRIPT_DIR/conf/default.env"

# Override with user environment if available
if [ -f "$SCRIPT_DIR/conf/user.env" ]; then
    source "$SCRIPT_DIR/conf/user.env"
fi

log_section() {
    log_info "=============================================="
    log_info "$1"
    log_info "=============================================="
}

# Run all test scripts in the test directory
run_all_tests() {
    local failed=0
    local test_count=0
    local passed=0
    
    log_section "RUNNING ALL TESTS"
    
    # Find all test scripts (excluding this one)
    for test_script in "$TEST_DIR"/*.sh; do
        # Skip this script and its copies
        if [[ "$(basename "$test_script")" == "run_tests.sh" ]]; then
            continue
        fi
        
        # Make sure the script is executable
        chmod +x "$test_script"
        
        test_name=$(basename "$test_script")
        log_info "Running test: $test_name"
        
        # Run the test script
        if "$test_script"; then
            log_info "✓ $test_name: PASSED"
            ((passed++))
        else
            log_error "✗ $test_name: FAILED"
            ((failed++))
        fi
        
        ((test_count++))
        echo ""
    done
    
    # Print summary
    if [ $test_count -eq 0 ]; then
        log_warn "No tests found in $TEST_DIR"
        return 0
    fi
    
    log_section "TEST SUMMARY"
    log_info "Total tests: $test_count"
    log_info "Passed: $passed"
    
    if [ $failed -eq 0 ]; then
        log_info "Failed: $failed"
        log_info "All tests passed successfully!"
        return 0
    else
        log_error "Failed: $failed"
        log_error "Some tests failed. Please check the logs above for details."
        return 1
    fi
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_info "Running tests from setup/test/run_tests.sh"
    run_all_tests
    exit $?
fi 