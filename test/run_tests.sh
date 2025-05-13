#!/bin/bash
# run_tests.sh - Run all tests in the test directory
# Part of Milestone 2

# Find the script directory
SCRIPT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
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
    # Flush stdout to ensure immediate display
    sync
}

# Run all test scripts in the test directory
run_all_tests() {
    local failed=0
    local test_count=0
    local passed=0
    
    log_section "RUNNING ALL TESTS"
    echo ""
    
    # Explicit test order
    local ordered_tests=(
        "$TEST_DIR/test_pg_connection.sh"
        "$TEST_DIR/test_netdata.sh"
        "$TEST_DIR/test_ssl_renewal.sh"
        "$TEST_DIR/test_dynamic_optimization.sh"
        "$TEST_DIR/test_email_notification.sh"
        "$TEST_DIR/test_backup.sh"
    )
    
    for test_script in "${ordered_tests[@]}"; do
        if [ ! -f "$test_script" ]; then
            log_warn "Test script not found: $(basename "$test_script")"
            # Flush output
            echo -e "\n" && sync
            continue
        fi
        chmod +x "$test_script"
        test_name=$(basename "$test_script")
        
        log_info "Running test: $test_name"
        # Flush output before running test
        echo -e "\n" && sync
        
        if "$test_script"; then
            log_pass "✓ $test_name: PASSED"
            ((passed++))
        else
            log_error "✗ $test_name: FAILED"
            ((failed++))
        fi
        ((test_count++))
        # Ensure output is visible
        echo -e "\n" && sync
    done
    
    # Print summary
    if [ $test_count -eq 0 ]; then
        log_warn "No tests found in $TEST_DIR"
        # Flush output
        echo -e "\n" && sync
        return 0
    fi
    
    log_section "TEST SUMMARY"
    log_info "Total tests: $test_count"
    log_info "Passed: $passed"
    
    if [ $failed -eq 0 ]; then
        log_info "Failed: $failed"
        log_info "All tests passed successfully!"
        # Flush output
        echo -e "\n" && sync
        return 0
    else
        log_error "Failed: $failed"
        log_error "Some tests failed. Please check the logs above for details."
        # Flush output
        echo -e "\n" && sync
        return 1
    fi
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Ensure we're starting with a clean line
    echo ""
    run_all_tests
    exit_code=$?
    # Make sure the prompt appears on a new line after all tests
    echo ""
    exit $exit_code
fi 