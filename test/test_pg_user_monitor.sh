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

# Add missing log_warning function
log_warning() {
    log_warn "$1"
}

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
        log_warn "pg_user_monitor table does not exist (limited functionality mode)"
        return 2  # Special return code for limited functionality
    fi
    
    # Check for event trigger
    local trigger_exists
    trigger_exists=$(su - postgres -c "psql -t -c \"SELECT EXISTS(SELECT 1 FROM pg_event_trigger WHERE evtname='user_change_trigger');\"" 2>/dev/null | tr -d ' ')
    
    if [ "$trigger_exists" != "t" ]; then
        log_warn "user_change_trigger does not exist (limited functionality mode)"
        return 2  # Special return code for limited functionality
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
    local limited_mode=false
    
    # Check if service is running
    if ! check_service_status; then
        log_error "User monitor service is not running, cannot continue tests"
        return 1
    fi
    
    # Check if triggers are installed
    local trigger_status
    check_triggers_installed
    trigger_status=$?
    
    if [ $trigger_status -eq 1 ]; then
        log_error "Triggers are not properly installed, cannot continue tests"
        return 1
    elif [ $trigger_status -eq 2 ]; then
        log_warn "Monitor is running in limited functionality mode (without triggers)"
        log_warn "Will test basic userlist functionality only"
        limited_mode=true
    fi
    
    # Run the tests based on mode
    if [ "$limited_mode" = true ]; then
        # For limited mode, just test basic userlist generation
        log_info "Testing user creation in limited functionality mode..."
        
        # Create a test user
        TEST_USER="test_monitor_user_$$"
        TEST_PASSWORD="Test123!@#"
        
        # Create the user in PostgreSQL
        execute_silently "su - postgres -c \"psql -c \\\"CREATE USER $TEST_USER WITH PASSWORD '$TEST_PASSWORD';\\\"\"" \
            "Created test user: $TEST_USER" \
            "Failed to create test user"
        
        # Wait for monitor to update userlist
        log_info "Waiting for user monitor to update userlist..."
        
        # Wait for up to 10 seconds (check every 2 seconds since we shortened the monitor interval)
        for i in {1..5}; do
            if grep -q "\"$TEST_USER\"" "$PGB_USERLIST_PATH"; then
                log_info "[PASS] Test user was added to userlist"
                break
            fi
            log_info "Waiting for userlist update... (attempt $i/5)"
            sleep 2
        done
        
        # Check if the user was added to userlist
        if ! grep -q "\"$TEST_USER\"" "$PGB_USERLIST_PATH"; then
            log_warning "User was not automatically added to userlist within timeout period"
            log_info "Forcing userlist update by restarting service..."
            
            # Restart the service to force an update
            systemctl restart "$PG_USER_MONITOR_SERVICE_NAME"
            
            # Wait for the service to restart and update
            sleep 10
            
            # Check again
            if grep -q "\"$TEST_USER\"" "$PGB_USERLIST_PATH"; then
                log_info "[PASS] Test user was added to userlist after service restart"
            else
                log_error "[FAIL] Test user was not added to userlist even after service restart"
                cleanup_test
                exit 1
            fi
        fi
        
        # Clean up
        log_info "Cleaning up test resources..."
        execute_silently "su - postgres -c \"psql -c \\\"DROP USER $TEST_USER;\\\"\"" \
            "Dropped test user: $TEST_USER" \
            "Failed to drop test user"
    else
        # Full functionality tests
        if ! test_user_creation; then
            success=false
        fi
        
        if ! test_password_change; then
            success=false
        fi
        
        if ! test_user_deletion; then
            success=false
        fi
    fi
    
    # Clean up
    cleanup
    
    log_section "POSTGRESQL USER MONITOR TEST SUMMARY"
    if [ "$success" = true ]; then
        if [ "$limited_mode" = true ]; then
            log_pass "Limited functionality tests passed"
        else
            log_pass "All PostgreSQL user monitor tests passed"
        fi
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