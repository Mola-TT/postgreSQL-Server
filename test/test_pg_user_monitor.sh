#!/bin/bash
# test_pg_user_monitor.sh - Test script for PostgreSQL User Monitor
# Part of Milestone 8

# Script directory
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
source "$TEST_SCRIPT_DIR/../lib/logger.sh"

# Load environment variables
source "$TEST_SCRIPT_DIR/../conf/default.env"
if [ -f "$TEST_SCRIPT_DIR/../conf/user.env" ]; then
    source "$TEST_SCRIPT_DIR/../conf/user.env"
fi

# Test configuration
TEST_USER_PREFIX="test_monitor_user"
TEST_PASSWORD="test_password_123"
PG_USER_MONITOR_SERVICE_NAME="${PG_USER_MONITOR_SERVICE_NAME:-pg-user-monitor}"
PGB_USERLIST_PATH="${PGB_USERLIST_PATH:-/etc/pgbouncer/userlist.txt}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Function to run a test and track results
run_test() {
  local test_name="$1"
  local test_function="$2"
  
  log_info "Running test: $test_name"
  
  if $test_function; then
    log_info "✓ PASS: $test_name"
    ((TESTS_PASSED++))
    return 0
  else
    log_error "✗ FAIL: $test_name"
    ((TESTS_FAILED++))
    return 1
  fi
}

# Function to wait for userlist update
wait_for_userlist_update() {
  local username="$1"
  local action="$2"  # "add" or "remove"
  local timeout=60
  local count=0
  
  log_info "Waiting for userlist update ($action $username)..."
  
  while [ $count -lt $timeout ]; do
    if [ "$action" = "add" ]; then
      if grep -q "\"$username\"" "$PGB_USERLIST_PATH" 2>/dev/null; then
        log_info "User $username found in userlist after ${count}s"
        return 0
      fi
    elif [ "$action" = "remove" ]; then
      if ! grep -q "\"$username\"" "$PGB_USERLIST_PATH" 2>/dev/null; then
        log_info "User $username removed from userlist after ${count}s"
        return 0
      fi
    fi
    
    sleep 2
    ((count += 2))
  done
  
  log_error "Timeout waiting for userlist update ($action $username)"
  return 1
}

# Test 1: Check if PostgreSQL user monitor service is installed and running
test_service_installation() {
  log_info "Checking if PostgreSQL user monitor service is installed..."
  
  # Check if service file exists
  if [ ! -f "/etc/systemd/system/${PG_USER_MONITOR_SERVICE_NAME}.service" ]; then
    log_error "Service file not found: /etc/systemd/system/${PG_USER_MONITOR_SERVICE_NAME}.service"
    return 1
  fi
  
  # Check if service is enabled
  if ! systemctl is-enabled --quiet "$PG_USER_MONITOR_SERVICE_NAME"; then
    log_error "Service is not enabled: $PG_USER_MONITOR_SERVICE_NAME"
    return 1
  fi
  
  # Check if service is running
  if ! systemctl is-active --quiet "$PG_USER_MONITOR_SERVICE_NAME"; then
    log_error "Service is not running: $PG_USER_MONITOR_SERVICE_NAME"
    return 1
  fi
  
  log_info "PostgreSQL user monitor service is properly installed and running"
  return 0
}

# Test 2: Check if userlist.txt exists and has proper permissions
test_userlist_file() {
  log_info "Checking pgbouncer userlist.txt file..."
  
  # Check if userlist file exists
  if [ ! -f "$PGB_USERLIST_PATH" ]; then
    log_error "Userlist file not found: $PGB_USERLIST_PATH"
    return 1
  fi
  
  # Check file permissions (600 or 640 are both acceptable, 600 is more secure)
  local file_perms=$(stat -c "%a" "$PGB_USERLIST_PATH" 2>/dev/null)
  if [ "$file_perms" != "640" ] && [ "$file_perms" != "600" ]; then
    log_warn "Userlist file permissions are $file_perms, expected 600 or 640"
  fi
  
  # Check file ownership
  local file_owner=$(stat -c "%U:%G" "$PGB_USERLIST_PATH" 2>/dev/null)
  if [ "$file_owner" != "postgres:postgres" ]; then
    log_warn "Userlist file ownership is $file_owner, expected postgres:postgres"
  fi
  
  # Note: We intentionally do NOT include comment headers in the userlist file
  # because pgbouncer treats lines starting with '#' as syntax errors
  
  log_info "Userlist file exists and appears to be properly configured"
  return 0
}

# Test 3: Test user creation detection
test_user_creation_detection() {
  local test_user="${TEST_USER_PREFIX}_create_$(date +%s)"
  
  log_info "Testing user creation detection with user: $test_user"
  
  # Create a new PostgreSQL user
  if ! su - postgres -c "psql -c \"CREATE USER $test_user WITH PASSWORD '$TEST_PASSWORD' LOGIN;\"" > /dev/null 2>&1; then
    log_error "Failed to create test user: $test_user"
    return 1
  fi
  
  log_info "Created test user: $test_user"
  
  # Wait for the monitor to detect the change and update userlist
  if ! wait_for_userlist_update "$test_user" "add"; then
    log_error "User creation was not detected by monitor"
    # Clean up
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  # Verify user is in userlist with correct format
  if ! grep -q "\"$test_user\" \"SCRAM-SHA-256" "$PGB_USERLIST_PATH"; then
    log_error "User found in userlist but not in expected SCRAM-SHA-256 format"
    # Clean up
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  log_info "User creation detection test passed"
  
  # Clean up
  su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
  return 0
}

# Test 4: Test password change detection
test_password_change_detection() {
  local test_user="${TEST_USER_PREFIX}_password_$(date +%s)"
  local new_password="new_password_456"
  
  log_info "Testing password change detection with user: $test_user"
  
  # Create a new PostgreSQL user
  if ! su - postgres -c "psql -c \"CREATE USER $test_user WITH PASSWORD '$TEST_PASSWORD' LOGIN;\"" > /dev/null 2>&1; then
    log_error "Failed to create test user: $test_user"
    return 1
  fi
  
  log_info "Created test user: $test_user"
  
  # Wait for initial user creation to be detected
  if ! wait_for_userlist_update "$test_user" "add"; then
    log_error "Initial user creation was not detected"
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  # Get initial password hash
  local initial_hash=$(grep "\"$test_user\"" "$PGB_USERLIST_PATH" | cut -d'"' -f4)
  
  # Change the user's password
  if ! su - postgres -c "psql -c \"ALTER USER $test_user PASSWORD '$new_password';\"" > /dev/null 2>&1; then
    log_error "Failed to change password for test user: $test_user"
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  log_info "Changed password for test user: $test_user"
  
  # Wait for password change to be detected (longer timeout for password changes)
  local timeout=90
  local count=0
  local password_changed=false
  
  while [ $count -lt $timeout ]; do
    local current_hash=$(grep "\"$test_user\"" "$PGB_USERLIST_PATH" 2>/dev/null | cut -d'"' -f4)
    if [ "$current_hash" != "$initial_hash" ] && [ -n "$current_hash" ]; then
      log_info "Password change detected after ${count}s"
      password_changed=true
      break
    fi
    
    sleep 3
    ((count += 3))
  done
  
  if [ "$password_changed" != true ]; then
    log_error "Password change was not detected by monitor"
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  log_info "Password change detection test passed"
  
  # Clean up
  su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
  return 0
}

# Test 5: Test user deletion detection
test_user_deletion_detection() {
  local test_user="${TEST_USER_PREFIX}_delete_$(date +%s)"
  
  log_info "Testing user deletion detection with user: $test_user"
  
  # Create a new PostgreSQL user
  if ! su - postgres -c "psql -c \"CREATE USER $test_user WITH PASSWORD '$TEST_PASSWORD' LOGIN;\"" > /dev/null 2>&1; then
    log_error "Failed to create test user: $test_user"
    return 1
  fi
  
  log_info "Created test user: $test_user"
  
  # Wait for user creation to be detected
  if ! wait_for_userlist_update "$test_user" "add"; then
    log_error "User creation was not detected"
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  # Delete the user
  if ! su - postgres -c "psql -c \"DROP USER $test_user;\"" > /dev/null 2>&1; then
    log_error "Failed to delete test user: $test_user"
    return 1
  fi
  
  log_info "Deleted test user: $test_user"
  
  # Wait for user deletion to be detected
  if ! wait_for_userlist_update "$test_user" "remove"; then
    log_error "User deletion was not detected by monitor"
    return 1
  fi
  
  log_info "User deletion detection test passed"
  return 0
}

# Test 6: Test non-login user handling
test_non_login_user_handling() {
  local test_user="${TEST_USER_PREFIX}_nologin_$(date +%s)"
  
  log_info "Testing non-login user handling with user: $test_user"
  
  # Create a user without login privilege
  if ! su - postgres -c "psql -c \"CREATE USER $test_user WITH PASSWORD '$TEST_PASSWORD' NOLOGIN;\"" > /dev/null 2>&1; then
    log_error "Failed to create non-login test user: $test_user"
    return 1
  fi
  
  log_info "Created non-login test user: $test_user"
  
  # Wait a bit for monitor to process
  sleep 35
  
  # Verify user is NOT in userlist (since it cannot login)
  if grep -q "\"$test_user\"" "$PGB_USERLIST_PATH" 2>/dev/null; then
    log_error "Non-login user found in userlist (should not be there)"
    su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
    return 1
  fi
  
  log_info "Non-login user correctly excluded from userlist"
  
  # Clean up
  su - postgres -c "psql -c \"DROP USER IF EXISTS $test_user;\"" > /dev/null 2>&1
  return 0
}

# Test 7: Test service restart functionality
test_service_restart() {
  log_info "Testing service restart functionality..."
  
  # Check initial service status
  if ! systemctl is-active --quiet "$PG_USER_MONITOR_SERVICE_NAME"; then
    log_error "Service is not running before restart test"
    return 1
  fi
  
  # Restart the service
  if ! systemctl restart "$PG_USER_MONITOR_SERVICE_NAME" > /dev/null 2>&1; then
    log_error "Failed to restart service"
    return 1
  fi
  
  # Wait for service to start
  sleep 5
  
  # Check if service is running after restart
  if ! systemctl is-active --quiet "$PG_USER_MONITOR_SERVICE_NAME"; then
    log_error "Service is not running after restart"
    return 1
  fi
  
  log_info "Service restart test passed"
  return 0
}

# Test 8: Test pgbouncer reload functionality
test_pgbouncer_reload() {
  log_info "Testing pgbouncer reload functionality..."
  
  # Check if pgbouncer is running
  if ! systemctl is-active --quiet pgbouncer; then
    log_error "pgbouncer service is not running"
    return 1
  fi
  
  # Get pgbouncer process ID before reload
  local pid_before=$(systemctl show --property MainPID --value pgbouncer)
  
  # Trigger a reload by creating and deleting a test user
  local test_user="${TEST_USER_PREFIX}_reload_$(date +%s)"
  
  # Create user
  su - postgres -c "psql -c \"CREATE USER $test_user WITH PASSWORD '$TEST_PASSWORD' LOGIN;\"" > /dev/null 2>&1
  
  # Wait for userlist update
  wait_for_userlist_update "$test_user" "add"
  
  # Delete user
  su - postgres -c "psql -c \"DROP USER $test_user;\"" > /dev/null 2>&1
  
  # Wait for userlist update
  wait_for_userlist_update "$test_user" "remove"
  
  # Check if pgbouncer is still running
  if ! systemctl is-active --quiet pgbouncer; then
    log_error "pgbouncer service stopped during reload test"
    return 1
  fi
  
  log_info "pgbouncer reload test passed"
  return 0
}

# Test 9: Test monitor log file creation
test_log_file_creation() {
  local log_path="${PG_USER_MONITOR_LOG_PATH:-/var/log/pg-user-monitor.log}"
  
  log_info "Testing monitor log file creation..."
  
  # Check if log file exists
  if [ ! -f "$log_path" ]; then
    log_error "Monitor log file not found: $log_path"
    return 1
  fi
  
  # Check if log file has recent entries
  if [ ! -s "$log_path" ]; then
    log_warn "Monitor log file is empty"
  else
    # Check for recent log entries (within last 5 minutes)
    local recent_logs=$(find "$log_path" -newermt "5 minutes ago" 2>/dev/null)
    if [ -z "$recent_logs" ]; then
      log_warn "No recent entries in monitor log file"
    else
      log_info "Monitor log file has recent entries"
    fi
  fi
  
  log_info "Log file creation test passed"
  return 0
}

# Test 10: Test state file management
test_state_file_management() {
  local state_file="${PG_USER_MONITOR_STATE_FILE:-/var/lib/postgresql/user_monitor_state.json}"
  
  log_info "Testing state file management..."
  
  # Check if state file exists
  if [ ! -f "$state_file" ]; then
    log_error "State file not found: $state_file"
    return 1
  fi
  
  # Check if state file contains valid JSON
  if ! python3 -c "import json; json.load(open('$state_file'))" 2>/dev/null; then
    log_error "State file does not contain valid JSON"
    return 1
  fi
  
  # Check state file permissions
  local state_dir=$(dirname "$state_file")
  local dir_owner=$(stat -c "%U:%G" "$state_dir" 2>/dev/null)
  if [ "$dir_owner" != "postgres:postgres" ]; then
    log_warn "State directory ownership is $dir_owner, expected postgres:postgres"
  fi
  
  log_info "State file management test passed"
  return 0
}

# Function to clean up test users
cleanup_test_users() {
  log_info "Cleaning up any remaining test users..."
  
  # Get list of test users
  local test_users=$(su - postgres -c "psql -t -c \"SELECT rolname FROM pg_authid WHERE rolname LIKE '${TEST_USER_PREFIX}_%';\"" 2>/dev/null | tr -d ' \n\r\t')
  
  if [ -n "$test_users" ]; then
    for user in $test_users; do
      if [ -n "$user" ]; then
        log_info "Removing test user: $user"
        su - postgres -c "psql -c \"DROP USER IF EXISTS $user;\"" > /dev/null 2>&1
      fi
    done
  fi
  
  log_info "Test user cleanup completed"
}

# Main test function
main() {
  log_info "=========================================="
  log_info "PostgreSQL User Monitor Test Suite"
  log_info "=========================================="
  echo ""
  
  # Check prerequisites
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "Python3 is required for tests"
    exit 1
  fi
  
  if ! systemctl is-active --quiet postgresql; then
    log_error "PostgreSQL service is not running"
    exit 1
  fi
  
  # Clean up any existing test users before starting
  cleanup_test_users
  
  # Run tests
  run_test "Service Installation" test_service_installation
  echo ""
  
  run_test "Userlist File" test_userlist_file
  echo ""
  
  run_test "User Creation Detection" test_user_creation_detection
  echo ""
  
  run_test "Password Change Detection" test_password_change_detection
  echo ""
  
  run_test "User Deletion Detection" test_user_deletion_detection
  echo ""
  
  run_test "Non-Login User Handling" test_non_login_user_handling
  echo ""
  
  run_test "Service Restart" test_service_restart
  echo ""
  
  run_test "pgbouncer Reload" test_pgbouncer_reload
  echo ""
  
  run_test "Log File Creation" test_log_file_creation
  echo ""
  
  run_test "State File Management" test_state_file_management
  echo ""
  
  # Clean up test users after tests
  cleanup_test_users
  
  # Print test summary
  log_info "=========================================="
  log_info "TEST SUMMARY"
  log_info "=========================================="
  log_info "Tests passed: $TESTS_PASSED"
  log_info "Tests failed: $TESTS_FAILED"
  log_info "Total tests: $((TESTS_PASSED + TESTS_FAILED))"
  
  if [ $TESTS_FAILED -eq 0 ]; then
    log_info "✓ ALL TESTS PASSED"
    exit 0
  else
    log_error "✗ SOME TESTS FAILED"
    exit 1
  fi
}

# Execute main function
main "$@" 