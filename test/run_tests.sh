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

# Override log_info to avoid duplicates when reporting success
original_log_info() {
    log "INFO" "$1"
}

# Create a wrapper for log_info that filters out duplicate messages
log_info() {
    # Filter out the specific duplicate message
    if [[ "$1" == "Tests executed successfully" && "$TEST_RUNNER_SUCCESS_PRINTED" == "1" ]]; then
        return 0
    fi
    
    # If it's the success message, mark it as printed
    if [[ "$1" == "Tests executed successfully" ]]; then
        export TEST_RUNNER_SUCCESS_PRINTED=1
    fi
    
    # Call the original function
    original_log_info "$1"
}

log_section() {
    log_info "=============================================="
    log_info "$1"
    log_info "=============================================="
    # Flush stdout to ensure immediate display
    sync
}

# Debugging function to check test script existence and permissions
check_test_scripts() {
    log_info "Checking test scripts in directory: $TEST_DIR"
    
    # Get all test scripts
    local test_scripts=("$TEST_DIR"/test_*.sh)
    
    # Check if any test scripts were found
    if [ ! -f "${test_scripts[0]}" ]; then
        log_error "No test scripts found in $TEST_DIR"
        return 1
    fi
    
    # Output listing with proper formatting and numbering
    local counter=1
    for script in "${test_scripts[@]}"; do
        if [ -f "$script" ]; then
            # Ensure script is executable
            chmod +x "$script" 2>/dev/null
            
            # Log script with numbering
            local script_name=$(basename "$script")
            log_info "$counter. $script_name"
            ((counter++))
        fi
    done
    
    return 0
}

# Run all test scripts in the test directory
run_all_tests() {
    local failed=0
    local test_count=0
    local passed=0
    
    log_section "RUNNING ALL TESTS"
    
    # Check if test scripts exist and are executable
    check_test_scripts
    
    # Explicit test order
    local ordered_tests=(
        "$TEST_DIR/test_pg_connection.sh"
        "$TEST_DIR/test_netdata.sh"
        "$TEST_DIR/test_ssl_renewal.sh"
        "$TEST_DIR/test_dynamic_optimization.sh"
        "$TEST_DIR/test_email_notification.sh"
        "$TEST_DIR/test_backup.sh"
        "$TEST_DIR/test_pg_user_monitor.sh"
        "$TEST_DIR/test_disaster_recovery.sh"
        "$TEST_DIR/test_system_reboot.sh"
        "$TEST_DIR/test_service_failure.sh"
        "$TEST_DIR/test_recovery_procedures.sh"
    )
    
    log_info "Preparing to run ${#ordered_tests[@]} tests"
    
    for test_script in "${ordered_tests[@]}"; do
        if [ ! -f "$test_script" ]; then
            log_warn "Test script not found: $(basename "$test_script")"
            continue
        fi
        
        # Ensure the script is executable
        chmod +x "$test_script" 2>/dev/null
        if [ $? -ne 0 ]; then
            log_warn "Failed to set executable permission on $(basename "$test_script"). Will try with bash explicitly."
        fi
        
        test_name=$(basename "$test_script")
        
        # Add a blank line before running each test
        echo ""
        log_info "Running test: $test_name"
        # Flush output before running test
        sync
        
        # Run with bash explicitly to avoid permission issues
        # Redirect stderr to stdout to ensure all output is captured
        if bash "$test_script" from_runner 2>&1; then
            log_pass "✓ $test_name: PASSED"
            ((passed++))
        else
            local exit_code=$?
            log_error "✗ $test_name: FAILED (exit code: $exit_code)"
            ((failed++))
        fi
        ((test_count++))
        # Ensure output is visible
        sync
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
        echo ""
        log_info "Tests executed successfully"
        return 0
    else
        log_error "Failed: $failed"
        log_error "Some tests failed. Please check the logs above for details."
        echo ""
        log_info "Tests completed with errors"
        return 1
    fi
}

# Function to run the tests and ensure success message is displayed only once
main() {
    # Reset the flag at the start of execution
    export TEST_RUNNER_SUCCESS_PRINTED=0
    
    log_info "Test runner starting in: $SCRIPT_DIR"
    run_all_tests
    return $?
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
    exit $?
fi 