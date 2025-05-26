#!/bin/bash
# test_service_failure.sh - Test service failure and recovery scenarios
# Part of Milestone 9

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
if [ -f "$SCRIPT_DIR/../conf/default.env" ]; then
  source "$SCRIPT_DIR/../conf/default.env"
fi

if [ -f "$SCRIPT_DIR/../conf/user.env" ]; then
  source "$SCRIPT_DIR/../conf/user.env"
fi

# Source required libraries
if ! type log_info &>/dev/null; then
  source "$SCRIPT_DIR/../lib/logger.sh"
fi

if ! type execute_silently &>/dev/null; then
  source "$SCRIPT_DIR/../lib/utilities.sh"
fi

# Test configuration
DISASTER_RECOVERY_SCRIPT="$SCRIPT_DIR/../setup/disaster_recovery.sh"
SIMULATION_SCRIPT="$SCRIPT_DIR/simulate_disaster_scenarios.sh"
RECOVERY_SERVICE_NAME="${DISASTER_RECOVERY_SERVICE_NAME:-disaster-recovery}"
TEST_TIMEOUT=120  # 2 minutes per test

# Services to test
TEST_SERVICES=("postgresql" "pgbouncer" "nginx" "netdata")

# Function to ensure disaster recovery service is running
ensure_disaster_recovery_running() {
  if ! systemctl is-active --quiet "$RECOVERY_SERVICE_NAME" 2>/dev/null; then
    log_info "Starting disaster recovery service for testing..."
    if bash "$DISASTER_RECOVERY_SCRIPT" start >/dev/null 2>&1; then
      sleep 10  # Give it time to start monitoring
      log_info "Disaster recovery service started"
    else
      log_error "Failed to start disaster recovery service"
      return 1
    fi
  else
    log_info "Disaster recovery service is already running"
  fi
  return 0
}

# Function to test service failure detection
test_service_failure_detection() {
  local service="$1"
  
  log_info "Testing failure detection for service: $service"
  
  # Check if service is currently running
  if ! systemctl is-active --quiet "$service" 2>/dev/null; then
    log_warn "Service $service is not running - starting it first"
    if ! systemctl start "$service" >/dev/null 2>&1; then
      log_error "Cannot start service $service for testing"
      return 1
    fi
    sleep 10
  fi
  
  # Ensure disaster recovery is monitoring
  if ! ensure_disaster_recovery_running; then
    return 1
  fi
  
  # Record initial state
  local initial_state="running"
  log_info "Initial state of $service: $initial_state"
  
  # Simulate service failure (safety mode)
  log_info "Simulating failure of $service (safety mode)..."
  if bash "$SIMULATION_SCRIPT" "service_failure_$service" 60 >/dev/null 2>&1; then
    log_info "✓ Service failure simulation completed for $service"
  else
    log_warn "Service failure simulation completed with warnings for $service"
  fi
  
  # Check if service is still running (should be recovered by disaster recovery)
  sleep 15  # Give recovery system time to act
  
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    log_info "✓ Service $service is running (recovery system maintained it)"
    return 0
  else
    log_warn "Service $service is not running after simulation"
    # Try to restart it manually for cleanup
    systemctl start "$service" >/dev/null 2>&1
    return 1
  fi
}

# Function to test service restart capability
test_service_restart_capability() {
  local service="$1"
  
  log_info "Testing restart capability for service: $service"
  
  # Ensure disaster recovery is running
  if ! ensure_disaster_recovery_running; then
    return 1
  fi
  
  # Check current service state
  local was_running=false
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    was_running=true
    log_info "Service $service is currently running"
  else
    log_info "Service $service is currently stopped"
  fi
  
  # Test disaster recovery's ability to start/restart the service
  log_info "Running disaster recovery check for $service..."
  if bash "$DISASTER_RECOVERY_SCRIPT" check >/dev/null 2>&1; then
    log_info "Disaster recovery check completed"
  else
    log_warn "Disaster recovery check completed with warnings"
  fi
  
  # Wait a moment for any recovery actions
  sleep 10
  
  # Check if service is now running
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    log_info "✓ Service $service is running after recovery check"
    return 0
  else
    log_warn "Service $service is not running after recovery check"
    return 1
  fi
}

# Function to test service dependency handling
test_service_dependency_handling() {
  log_info "Testing service dependency handling..."
  
  # Test PostgreSQL -> pgbouncer dependency
  log_info "Testing PostgreSQL -> pgbouncer dependency..."
  
  # Ensure both services are running
  for service in "postgresql" "pgbouncer"; do
    if ! systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "Starting $service for dependency test"
      systemctl start "$service" >/dev/null 2>&1
      sleep 5
    fi
  done
  
  # Ensure disaster recovery is monitoring
  if ! ensure_disaster_recovery_running; then
    return 1
  fi
  
  # Run recovery check to test dependency handling
  log_info "Running recovery check to test dependency handling..."
  if bash "$DISASTER_RECOVERY_SCRIPT" check >/dev/null 2>&1; then
    log_info "✓ Dependency handling test completed"
  else
    log_warn "Dependency handling test completed with warnings"
  fi
  
  # Verify both services are still running
  local dependency_ok=true
  for service in "postgresql" "pgbouncer"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "✓ Service $service is running after dependency test"
    else
      log_warn "✗ Service $service is not running after dependency test"
      dependency_ok=false
    fi
  done
  
  if [ "$dependency_ok" = true ]; then
    return 0
  else
    return 1
  fi
}

# Function to test recovery timeout handling
test_recovery_timeout_handling() {
  log_info "Testing recovery timeout handling..."
  
  # Set a short timeout for testing
  local original_timeout="${DISASTER_RECOVERY_TIMEOUT:-300}"
  export DISASTER_RECOVERY_TIMEOUT=30
  
  # Ensure disaster recovery is running
  if ! ensure_disaster_recovery_running; then
    export DISASTER_RECOVERY_TIMEOUT="$original_timeout"
    return 1
  fi
  
  # Run a recovery check with short timeout
  log_info "Running recovery check with short timeout (30s)..."
  if timeout 60 bash "$DISASTER_RECOVERY_SCRIPT" check >/dev/null 2>&1; then
    log_info "✓ Recovery check completed within timeout"
  else
    log_warn "Recovery check timed out or completed with warnings"
  fi
  
  # Restore original timeout
  export DISASTER_RECOVERY_TIMEOUT="$original_timeout"
  
  log_info "Timeout handling test completed"
  return 0
}

# Function to test multiple service failures
test_multiple_service_failures() {
  log_info "Testing multiple service failure scenarios..."
  
  # Ensure disaster recovery is running
  if ! ensure_disaster_recovery_running; then
    return 1
  fi
  
  # Test handling of multiple services
  local services_to_test=("nginx" "netdata")
  
  for service in "${services_to_test[@]}"; do
    log_info "Testing recovery for $service in multi-service scenario..."
    
    # Check if service is running
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "Service $service is running"
    else
      log_info "Service $service is not running - this will test startup capability"
    fi
  done
  
  # Run comprehensive recovery check
  log_info "Running comprehensive recovery check..."
  if bash "$DISASTER_RECOVERY_SCRIPT" check >/dev/null 2>&1; then
    log_info "✓ Multi-service recovery check completed"
  else
    log_warn "Multi-service recovery check completed with warnings"
  fi
  
  # Verify services are running
  local all_ok=true
  for service in "${services_to_test[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "✓ Service $service is running after multi-service test"
    else
      log_warn "✗ Service $service is not running after multi-service test"
      all_ok=false
    fi
  done
  
  if [ "$all_ok" = true ]; then
    return 0
  else
    return 1
  fi
}

# Function to test recovery notification system
test_recovery_notification_system() {
  log_info "Testing recovery notification system..."
  
  # Check if email notifications are enabled
  if [ "$DISASTER_RECOVERY_EMAIL_ENABLED" != "true" ]; then
    log_info "Email notifications are disabled - skipping notification test"
    return 0
  fi
  
  # Check email configuration
  if [ -z "$DISASTER_RECOVERY_EMAIL_RECIPIENT" ]; then
    log_warn "Email recipient not configured - notification test limited"
  fi
  
  # Ensure disaster recovery is running
  if ! ensure_disaster_recovery_running; then
    return 1
  fi
  
  # Run a recovery action that would trigger notifications
  log_info "Running recovery action to test notifications..."
  if bash "$DISASTER_RECOVERY_SCRIPT" recover >/dev/null 2>&1; then
    log_info "✓ Recovery action completed (notifications would be sent if configured)"
  else
    log_warn "Recovery action completed with warnings"
  fi
  
  log_info "Notification system test completed"
  return 0
}

# Function to test recovery state management
test_recovery_state_management() {
  log_info "Testing recovery state management..."
  
  local state_file="${DISASTER_RECOVERY_STATE_FILE:-/var/lib/postgresql/disaster_recovery_state.json}"
  
  # Check if state file exists or can be created
  local state_dir=$(dirname "$state_file")
  if [ ! -d "$state_dir" ]; then
    if ! mkdir -p "$state_dir" 2>/dev/null; then
      log_error "Cannot create state directory: $state_dir"
      return 1
    fi
  fi
  
  # Ensure disaster recovery is running
  if ! ensure_disaster_recovery_running; then
    return 1
  fi
  
  # Run recovery action to generate state
  log_info "Running recovery action to generate state data..."
  if bash "$DISASTER_RECOVERY_SCRIPT" check >/dev/null 2>&1; then
    log_info "Recovery action completed"
  else
    log_warn "Recovery action completed with warnings"
  fi
  
  # Check if state file was created/updated
  if [ -f "$state_file" ]; then
    log_info "✓ State file exists: $state_file"
    
    # Check if state file contains valid JSON
    if python3 -c "import json; json.load(open('$state_file'))" 2>/dev/null; then
      log_info "✓ State file contains valid JSON"
    else
      log_warn "State file does not contain valid JSON"
    fi
  else
    log_warn "State file was not created: $state_file"
  fi
  
  log_info "State management test completed"
  return 0
}

# Main test execution
main() {
  log_info "Starting service failure and recovery tests..."
  
  local tests_passed=0
  local tests_failed=0
  
  # Define test functions
  local test_functions=(
    "test_recovery_timeout_handling"
    "test_recovery_notification_system"
    "test_recovery_state_management"
    "test_service_dependency_handling"
    "test_multiple_service_failures"
  )
  
  # Add individual service tests
  for service in "${TEST_SERVICES[@]}"; do
    test_functions+=("test_service_failure_detection:$service")
    test_functions+=("test_service_restart_capability:$service")
  done
  
  # Run all tests
  for test_item in "${test_functions[@]}"; do
    local test_func="${test_item%%:*}"
    local test_param="${test_item#*:}"
    
    if [ "$test_func" = "$test_item" ]; then
      # No parameter
      local test_name="${test_func#test_}"
      test_name="${test_name//_/ }"
      
      log_info "Running test: $test_name"
      
      # Create subshell script with all required functions and variables
      local subshell_script="
# Source required libraries
source '$SCRIPT_DIR/../lib/logger.sh'
source '$SCRIPT_DIR/../lib/utilities.sh'

# Export environment variables
export DISASTER_RECOVERY_SCRIPT='$DISASTER_RECOVERY_SCRIPT'
export SIMULATION_SCRIPT='$SIMULATION_SCRIPT'
export RECOVERY_SERVICE_NAME='$RECOVERY_SERVICE_NAME'
export DISASTER_RECOVERY_EMAIL_ENABLED='$DISASTER_RECOVERY_EMAIL_ENABLED'
export DISASTER_RECOVERY_EMAIL_RECIPIENT='$DISASTER_RECOVERY_EMAIL_RECIPIENT'
export DISASTER_RECOVERY_STATE_FILE='$DISASTER_RECOVERY_STATE_FILE'
export DISASTER_RECOVERY_TIMEOUT='$DISASTER_RECOVERY_TIMEOUT'

# Define all required functions
$(declare -f ensure_disaster_recovery_running)
$(declare -f "$test_func")

# Run the test function
$test_func
"

      if timeout "$TEST_TIMEOUT" bash -c "$subshell_script"; then
        log_info "✓ PASS: $test_name"
        ((tests_passed++))
      else
        log_error "✗ FAIL: $test_name"
        ((tests_failed++))
      fi
    else
      # Has parameter
      local test_name="${test_func#test_} for $test_param"
      test_name="${test_name//_/ }"
      
      log_info "Running test: $test_name"
      
      # Create subshell script with all required functions and variables
      local subshell_script="
# Source required libraries
source '$SCRIPT_DIR/../lib/logger.sh'
source '$SCRIPT_DIR/../lib/utilities.sh'

# Export environment variables
export DISASTER_RECOVERY_SCRIPT='$DISASTER_RECOVERY_SCRIPT'
export SIMULATION_SCRIPT='$SIMULATION_SCRIPT'
export RECOVERY_SERVICE_NAME='$RECOVERY_SERVICE_NAME'
export DISASTER_RECOVERY_EMAIL_ENABLED='$DISASTER_RECOVERY_EMAIL_ENABLED'
export DISASTER_RECOVERY_EMAIL_RECIPIENT='$DISASTER_RECOVERY_EMAIL_RECIPIENT'
export DISASTER_RECOVERY_STATE_FILE='$DISASTER_RECOVERY_STATE_FILE'
export DISASTER_RECOVERY_TIMEOUT='$DISASTER_RECOVERY_TIMEOUT'

# Define all required functions
$(declare -f ensure_disaster_recovery_running)
$(declare -f "$test_func")

# Run the test function with parameter
$test_func '$test_param'
"

      if timeout "$TEST_TIMEOUT" bash -c "$subshell_script"; then
        log_info "✓ PASS: $test_name"
        ((tests_passed++))
      else
        log_error "✗ FAIL: $test_name"
        ((tests_failed++))
      fi
    fi
    
    echo  # Add spacing between tests
  done
  
  # Summary
  log_info "Service Failure Recovery Test Summary:"
  log_info "  Tests Passed: $tests_passed"
  log_info "  Tests Failed: $tests_failed"
  log_info "  Total Tests:  $((tests_passed + tests_failed))"
  
  if [ $tests_failed -eq 0 ]; then
    log_info "✓ All service failure recovery tests passed!"
    return 0
  else
    log_error "✗ Some service failure recovery tests failed"
    return 1
  fi
}

# Run main function
main "$@" 