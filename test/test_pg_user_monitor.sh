#!/bin/bash
# test_pg_user_monitor.sh - Test script for PostgreSQL user monitor
# Part of Milestone 8

# Skip if running from CI/CD
if [ "$1" = "from_ci" ]; then
    exit 0
fi

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

# Define variables for test
TEST_USER="pgbtest_user"
TEST_PASSWORD="test_password_123"
PGB_USERLIST_PATH="/etc/pgbouncer/userlist.txt"

# Function to execute SQL as postgres user
execute_sql() {
    local sql="$1"
    su - postgres -c "psql -c \"$sql\"" > /dev/null 2>&1
    return $?
}

# Function to check if PG monitor service is running
check_service_status() {
    local service_name="pg-user-monitor"
    
    if systemctl is-active --quiet "$service_name"; then
        log_pass "Service $service_name is running"
        return 0
    else
        log_error "Service $service_name is not running"
        return 1
    fi
}

# Function to check if triggers are installed
check_triggers_installed() {
    # Check for table
    local table_exists
    table_exists=$(su - postgres -c "psql -t -c \"SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='pg_user_monitor');\"" 2>/dev/null | tr -d ' ')
    
    if [ "$table_exists" != "t" ]; then
        log_error "pg_user_monitor table does not exist"
        return 1
    fi
    
    # Check for event trigger
    local trigger_exists
    trigger_exists=$(su - postgres -c "psql -t -c \"SELECT EXISTS(SELECT 1 FROM pg_event_trigger WHERE evtname='user_change_trigger');\"" 2>/dev/null | tr -d ' ')
    
    if [ "$trigger_exists" != "t" ]; then
        log_error "user_change_trigger does not exist"
        return 1
    fi
    
    log_pass "PostgreSQL triggers are installed correctly"
    return 0
}

# Function to test user creation
test_user_creation() {
    log_info "Testing user creation..."
    
    # Drop test user if it exists
    execute_sql "DROP USER IF EXISTS $TEST_USER;"
    
    # Save initial userlist state
    local initial_hash
    initial_hash=$(md5sum "$PGB_USERLIST_PATH" 2>/dev/null | awk '{print $1}')
    
    # Create test user
    execute_sql "CREATE USER $TEST_USER WITH PASSWORD '$TEST_PASSWORD';"
    
    # Wait for monitor to update userlist
    log_info "Waiting for user monitor to detect changes and update userlist..."
    sleep 60
    
    # Check if userlist changed
    local new_hash
    new_hash=$(md5sum "$PGB_USERLIST_PATH" 2>/dev/null | awk '{print $1}')
    
    if [ "$initial_hash" = "$new_hash" ]; then
        log_error "Userlist file was not updated after user creation"
        return 1
    fi
    
    # Check if user is in userlist
    if ! grep -q "$TEST_USER" "$PGB_USERLIST_PATH"; then
        log_error "Test user was not added to userlist"
        return 1
    fi
    
    log_pass "User creation test passed"
    return 0
}

# Function to test password change
test_password_change() {
    log_info "Testing password change..."
    
    # Save initial userlist state
    local initial_hash
    initial_hash=$(md5sum "$PGB_USERLIST_PATH" 2>/dev/null | awk '{print $1}')
    
    # Change test user password
    execute_sql "ALTER USER $TEST_USER WITH PASSWORD 'new_password_456';"
    
    # Wait for monitor to update userlist
    log_info "Waiting for user monitor to detect password change and update userlist..."
    sleep 60
    
    # Check if userlist changed
    local new_hash
    new_hash=$(md5sum "$PGB_USERLIST_PATH" 2>/dev/null | awk '{print $1}')
    
    if [ "$initial_hash" = "$new_hash" ]; then
        log_error "Userlist file was not updated after password change"
        return 1
    fi
    
    log_pass "Password change test passed"
    return 0
}

# Function to test user deletion
test_user_deletion() {
    log_info "Testing user deletion..."
    
    # Save initial userlist state
    local initial_hash
    initial_hash=$(md5sum "$PGB_USERLIST_PATH" 2>/dev/null | awk '{print $1}')
    
    # Drop test user
    execute_sql "DROP USER $TEST_USER;"
    
    # Wait for monitor to update userlist
    log_info "Waiting for user monitor to detect user deletion and update userlist..."
    sleep 60
    
    # Check if userlist changed
    local new_hash
    new_hash=$(md5sum "$PGB_USERLIST_PATH" 2>/dev/null | awk '{print $1}')
    
    if [ "$initial_hash" = "$new_hash" ]; then
        log_error "Userlist file was not updated after user deletion"
        return 1
    fi
    
    # Check if user is removed from userlist
    if grep -q "$TEST_USER" "$PGB_USERLIST_PATH"; then
        log_error "Test user was not removed from userlist"
        return 1
    fi
    
    log_pass "User deletion test passed"
    return 0
}

# Function to clean up after tests
cleanup() {
    log_info "Cleaning up test resources..."
    execute_sql "DROP USER IF EXISTS $TEST_USER;"
}

# Main test function
run_tests() {
    log_section "TESTING POSTGRESQL USER MONITOR"
    
    local success=true
    
    # Check if service is running
    if ! check_service_status; then
        log_error "User monitor service is not running, cannot continue tests"
        return 1
    fi
    
    # Check if triggers are installed
    if ! check_triggers_installed; then
        log_error "Triggers are not properly installed, cannot continue tests"
        return 1
    fi
    
    # Run the tests
    if ! test_user_creation; then
        success=false
    fi
    
    if ! test_password_change; then
        success=false
    fi
    
    if ! test_user_deletion; then
        success=false
    fi
    
    # Clean up
    cleanup
    
    log_section "POSTGRESQL USER MONITOR TEST SUMMARY"
    if [ "$success" = true ]; then
        log_pass "All PostgreSQL user monitor tests passed"
        return 0
    else
        log_error "Some PostgreSQL user monitor tests failed"
        return 1
    fi
}

# Helper function for section headers in logs
log_section() {
    log_info "=============================================="
    log_info "$1"
    log_info "=============================================="
}

# Helper function for passing tests
log_pass() {
    log_info "[PASS] $1"
}

# Run the tests if the script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Skip further execution if running from test runner with from_runner parameter
    if [ "$1" = "from_runner" ]; then
        run_tests
        exit $?
    fi
    
    # If running standalone, execute tests
    run_tests
    exit $?
fi 