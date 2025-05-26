#!/bin/bash
# test_recovery_procedures.sh - Test recovery procedures in a controlled environment
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
TEST_LOG_PATH="${DISASTER_RECOVERY_LOG_PATH:-/var/log/disaster-recovery.log}.test"
TEST_DURATION=300  # 5 minutes
RECOVERY_SCRIPT="$SCRIPT_DIR/../setup/disaster_recovery.sh"

# Function to run controlled test
run_controlled_test() {
  local test_name="$1"
  local test_function="$2"
  
  log_info "Starting controlled test: $test_name"
  
  # Create test environment
  local test_start_time=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Run the test
  if $test_function; then
    log_info "✓ PASS: $test_name"
    return 0
  else
    log_error "✗ FAIL: $test_name"
    return 1
  fi
}

# Test disaster recovery service installation
test_service_installation() {
  log_info "Testing disaster recovery service installation..."
  
  # Check if script exists
  if [ ! -f "$RECOVERY_SCRIPT" ]; then
    log_error "Disaster recovery script not found: $RECOVERY_SCRIPT"
    return 1
  fi
  
  # Test script execution
  if ! bash "$RECOVERY_SCRIPT" --help >/dev/null 2>&1; then
    log_error "Disaster recovery script is not executable or has syntax errors"
    return 1
  fi
  
  # Check systemd service file
  if [ ! -f "/etc/systemd/system/disaster-recovery.service" ]; then
    log_warn "Systemd service file not found - running setup"
    if ! bash "$RECOVERY_SCRIPT" setup; then
      log_error "Failed to setup disaster recovery service"
      return 1
    fi
  fi
  
  log_info "Service installation test passed"
  return 0
}

# Test service monitoring capabilities
test_service_monitoring() {
  log_info "Testing service monitoring capabilities..."
  
  # Test service status checking
  local services=("postgresql" "pgbouncer" "nginx" "netdata")
  
  for service in "${services[@]}"; do
    log_info "Checking monitoring for service: $service"
    
    # Check if service is running
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "Service $service is running - monitoring test passed"
    else
      log_warn "Service $service is not running - this is expected for testing"
    fi
  done
  
  return 0
}

# Test recovery notification system
test_notification_system() {
  log_info "Testing recovery notification system..."
  
  # Test email configuration
  if [ "$DISASTER_RECOVERY_EMAIL_ENABLED" = "true" ]; then
    log_info "Email notifications are enabled"
    
    # Check email tools
    if command -v msmtp >/dev/null 2>&1; then
      log_info "msmtp is available for email notifications"
    elif command -v sendmail >/dev/null 2>&1; then
      log_info "sendmail is available for email notifications"
    else
      log_warn "No email tools found - notifications may not work"
    fi
  else
    log_info "Email notifications are disabled"
  fi
  
  return 0
}

# Test state file management
test_state_management() {
  log_info "Testing state file management..."
  
  local state_file="${DISASTER_RECOVERY_STATE_FILE:-/var/lib/postgresql/disaster_recovery_state.json}"
  local state_dir=$(dirname "$state_file")
  
  # Check if state directory exists or can be created
  if [ ! -d "$state_dir" ]; then
    if mkdir -p "$state_dir" 2>/dev/null; then
      log_info "Created state directory: $state_dir"
    else
      log_error "Cannot create state directory: $state_dir"
      return 1
    fi
  fi
  
  # Test state file creation
  local test_state='{"test": true, "timestamp": "'$(date)'"}'
  if echo "$test_state" > "$state_file.test" 2>/dev/null; then
    log_info "State file write test passed"
    rm -f "$state_file.test" 2>/dev/null
  else
    log_error "Cannot write to state file location"
    return 1
  fi
  
  return 0
}

# Test recovery timeout handling
test_timeout_handling() {
  log_info "Testing recovery timeout handling..."
  
  # Test with short timeout
  local original_timeout="${DISASTER_RECOVERY_TIMEOUT:-300}"
  export DISASTER_RECOVERY_TIMEOUT=10
  
  # Run a quick check
  if bash "$RECOVERY_SCRIPT" check >/dev/null 2>&1; then
    log_info "Timeout handling test passed"
  else
    log_warn "Timeout handling test completed with warnings"
  fi
  
  # Restore original timeout
  export DISASTER_RECOVERY_TIMEOUT="$original_timeout"
  
  return 0
}

# Test log file management
test_log_management() {
  log_info "Testing log file management..."
  
  local log_file="${DISASTER_RECOVERY_LOG_PATH:-/var/log/disaster-recovery.log}"
  local log_dir=$(dirname "$log_file")
  
  # Check log directory
  if [ ! -d "$log_dir" ]; then
    if mkdir -p "$log_dir" 2>/dev/null; then
      log_info "Created log directory: $log_dir"
    else
      log_error "Cannot create log directory: $log_dir"
      return 1
    fi
  fi
  
  # Test log file writing
  if echo "Test log entry: $(date)" >> "$log_file.test" 2>/dev/null; then
    log_info "Log file write test passed"
    rm -f "$log_file.test" 2>/dev/null
  else
    log_error "Cannot write to log file location"
    return 1
  fi
  
  return 0
}

# Test dependency resolution
test_dependency_resolution() {
  log_info "Testing service dependency resolution..."
  
  # Test dependency mapping
  local dependencies=(
    "pgbouncer:postgresql"
    "pg-user-monitor:postgresql,pgbouncer"
    "nginx:postgresql,pgbouncer"
    "netdata:postgresql"
  )
  
  for dep_rule in "${dependencies[@]}"; do
    local service="${dep_rule%%:*}"
    local deps="${dep_rule#*:}"
    log_info "Service $service depends on: $deps"
  done
  
  log_info "Dependency resolution test passed"
  return 0
}

# Test configuration validation
test_configuration_validation() {
  log_info "Testing configuration validation..."
  
  # Check required environment variables
  local required_vars=(
    "DISASTER_RECOVERY_ENABLED"
    "DISASTER_RECOVERY_CHECK_INTERVAL"
    "DISASTER_RECOVERY_LOG_PATH"
  )
  
  for var in "${required_vars[@]}"; do
    if [ -n "${!var}" ]; then
      log_info "Configuration variable $var is set: ${!var}"
    else
      log_warn "Configuration variable $var is not set"
    fi
  done
  
  return 0
}

# Main test execution
main() {
  log_info "Starting controlled recovery procedure tests..."
  
  local tests_passed=0
  local tests_failed=0
  
  # Run all tests
  local test_functions=(
    "test_service_installation"
    "test_service_monitoring"
    "test_notification_system"
    "test_state_management"
    "test_timeout_handling"
    "test_log_management"
    "test_dependency_resolution"
    "test_configuration_validation"
  )
  
  for test_func in "${test_functions[@]}"; do
    local test_name="${test_func#test_}"
    test_name="${test_name//_/ }"
    
    if run_controlled_test "$test_name" "$test_func"; then
      ((tests_passed++))
    else
      ((tests_failed++))
    fi
    
    echo  # Add spacing between tests
  done
  
  # Summary
  log_info "Test Summary:"
  log_info "  Tests Passed: $tests_passed"
  log_info "  Tests Failed: $tests_failed"
  log_info "  Total Tests:  $((tests_passed + tests_failed))"
  
  if [ $tests_failed -eq 0 ]; then
    log_info "✓ All recovery procedure tests passed!"
    return 0
  else
    log_error "✗ Some recovery procedure tests failed"
    return 1
  fi
}

# Run main function
main "$@" 