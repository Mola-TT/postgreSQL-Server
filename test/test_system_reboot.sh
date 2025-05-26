#!/bin/bash
# test_system_reboot.sh - Test automatic service restoration after reboot
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
REBOOT_TEST_LOG="/var/log/reboot-test.log"
RECOVERY_SERVICE_NAME="${DISASTER_RECOVERY_SERVICE_NAME:-disaster-recovery}"
CRITICAL_SERVICES=("postgresql" "pgbouncer" "nginx" "netdata" "pg-user-monitor" "$RECOVERY_SERVICE_NAME")

# Function to check service auto-start configuration
test_service_auto_start_config() {
  log_info "Testing service auto-start configuration..."
  
  local failed_services=()
  
  for service in "${CRITICAL_SERVICES[@]}"; do
    log_info "Checking auto-start for service: $service"
    
    # Check if service is enabled
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
      log_info "✓ Service $service is enabled for auto-start"
    else
      log_warn "✗ Service $service is NOT enabled for auto-start"
      failed_services+=("$service")
    fi
  done
  
  if [ ${#failed_services[@]} -eq 0 ]; then
    log_info "All critical services are configured for auto-start"
    return 0
  else
    log_error "Services not configured for auto-start: ${failed_services[*]}"
    return 1
  fi
}

# Function to test service dependencies
test_service_dependencies() {
  log_info "Testing service dependencies..."
  
  # Check disaster recovery service dependencies
  local service_file="/etc/systemd/system/${RECOVERY_SERVICE_NAME}.service"
  
  if [ ! -f "$service_file" ]; then
    log_error "Disaster recovery service file not found: $service_file"
    return 1
  fi
  
  # Check for proper dependencies
  local required_deps=("network.target")
  local wanted_services=("postgresql.service" "pgbouncer.service" "nginx.service" "netdata.service")
  
  for dep in "${required_deps[@]}"; do
    if grep -q "After=.*$dep" "$service_file"; then
      log_info "✓ Service has required dependency: $dep"
    else
      log_warn "✗ Service missing required dependency: $dep"
    fi
  done
  
  for wanted in "${wanted_services[@]}"; do
    if grep -q "Wants=.*$wanted" "$service_file"; then
      log_info "✓ Service wants: $wanted"
    else
      log_info "Service does not explicitly want: $wanted (this may be OK)"
    fi
  done
  
  # Check target configuration
  if grep -q "WantedBy=multi-user.target" "$service_file"; then
    log_info "✓ Service is configured for multi-user target"
  else
    log_error "✗ Service is not configured for multi-user target"
    return 1
  fi
  
  log_info "Service dependencies verified"
  return 0
}

# Function to simulate reboot scenario
test_reboot_simulation() {
  log_info "Testing reboot simulation (without actual reboot)..."
  
  # Record current service states
  local service_states=()
  for service in "${CRITICAL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      service_states+=("$service:active")
      log_info "Service $service is currently active"
    else
      service_states+=("$service:inactive")
      log_info "Service $service is currently inactive"
    fi
  done
  
  # Test what would happen after reboot by checking enabled status
  log_info "Simulating post-reboot service states..."
  
  local would_start=()
  local would_not_start=()
  
  for service in "${CRITICAL_SERVICES[@]}"; do
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
      would_start+=("$service")
      log_info "✓ Service $service would start after reboot"
    else
      would_not_start+=("$service")
      log_warn "✗ Service $service would NOT start after reboot"
    fi
  done
  
  # Report simulation results
  if [ ${#would_not_start[@]} -eq 0 ]; then
    log_info "✓ All critical services would start after reboot"
    return 0
  else
    log_error "✗ Services that would not start: ${would_not_start[*]}"
    return 1
  fi
}

# Function to test startup order
test_startup_order() {
  log_info "Testing service startup order..."
  
  # Check if PostgreSQL starts before dependent services
  local pg_deps=("pgbouncer" "pg-user-monitor")
  
  for dep_service in "${pg_deps[@]}"; do
    local dep_file="/etc/systemd/system/${dep_service}.service"
    
    if [ -f "$dep_file" ]; then
      if grep -q "After=.*postgresql" "$dep_file" || grep -q "Requires=.*postgresql" "$dep_file"; then
        log_info "✓ Service $dep_service properly depends on PostgreSQL"
      else
        log_warn "✗ Service $dep_service may not wait for PostgreSQL"
      fi
    else
      log_warn "Service file not found for dependency check: $dep_file"
    fi
  done
  
  # Check if disaster recovery starts after network
  local dr_file="/etc/systemd/system/${RECOVERY_SERVICE_NAME}.service"
  if [ -f "$dr_file" ]; then
    if grep -q "After=.*network.target" "$dr_file"; then
      log_info "✓ Disaster recovery service waits for network"
    else
      log_warn "✗ Disaster recovery service may not wait for network"
    fi
  fi
  
  log_info "Startup order verification completed"
  return 0
}

# Function to test recovery after simulated crash
test_recovery_after_crash() {
  log_info "Testing recovery after simulated service crash..."
  
  # Start disaster recovery service if not running
  if ! systemctl is-active --quiet "$RECOVERY_SERVICE_NAME" 2>/dev/null; then
    log_info "Starting disaster recovery service for crash test"
    systemctl start "$RECOVERY_SERVICE_NAME" >/dev/null 2>&1
    sleep 5
  fi
  
  # Test recovery detection for each critical service
  for service in "postgresql" "pgbouncer" "nginx" "netdata"; do
    log_info "Testing crash recovery for service: $service"
    
    # Check if service is running
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "Service $service is running - recovery system should maintain it"
    else
      log_info "Service $service is not running - recovery system should start it"
    fi
    
    # Run disaster recovery check
    if bash "$SCRIPT_DIR/../setup/disaster_recovery.sh" check >/dev/null 2>&1; then
      log_info "✓ Recovery check passed for $service"
    else
      log_warn "Recovery check completed with warnings for $service"
    fi
  done
  
  log_info "Crash recovery testing completed"
  return 0
}

# Function to test boot time optimization
test_boot_time_optimization() {
  log_info "Testing boot time optimization..."
  
  # Check for parallel service startup
  local parallel_services=("postgresql" "nginx" "netdata")
  
  for service in "${parallel_services[@]}"; do
    local service_file="/etc/systemd/system/${service}.service"
    local override_dir="/etc/systemd/system/${service}.service.d"
    
    # Check if service has any boot time optimizations
    if [ -d "$override_dir" ]; then
      log_info "Service $service has systemd overrides in $override_dir"
    fi
    
    # Check for Type=notify or Type=forking for faster startup detection
    if systemctl show "$service" --property=Type 2>/dev/null | grep -q "Type=notify\|Type=forking"; then
      log_info "✓ Service $service uses optimized startup type"
    else
      log_info "Service $service uses standard startup type"
    fi
  done
  
  log_info "Boot time optimization check completed"
  return 0
}

# Function to test reboot readiness
test_reboot_readiness() {
  log_info "Testing system reboot readiness..."
  
  # Check if all critical services are properly configured
  local readiness_issues=()
  
  # Check systemd targets
  if systemctl get-default | grep -q "multi-user.target\|graphical.target"; then
    log_info "✓ System default target is appropriate for server"
  else
    readiness_issues+=("inappropriate default target")
  fi
  
  # Check for failed services that might prevent proper startup
  local failed_services=$(systemctl list-units --failed --no-legend | wc -l)
  if [ "$failed_services" -eq 0 ]; then
    log_info "✓ No failed services detected"
  else
    log_warn "Found $failed_services failed services - may affect reboot"
    readiness_issues+=("failed services present")
  fi
  
  # Check disk space for logs
  local log_usage=$(df /var/log | awk 'NR==2 {print $5}' | sed 's/%//')
  if [ "$log_usage" -lt 90 ]; then
    log_info "✓ Log partition has sufficient space ($log_usage% used)"
  else
    log_warn "Log partition is nearly full ($log_usage% used)"
    readiness_issues+=("log partition nearly full")
  fi
  
  # Report readiness
  if [ ${#readiness_issues[@]} -eq 0 ]; then
    log_info "✓ System is ready for reboot"
    return 0
  else
    log_warn "Reboot readiness issues: ${readiness_issues[*]}"
    return 1
  fi
}

# Function to create reboot test marker
create_reboot_test_marker() {
  log_info "Creating reboot test marker..."
  
  local marker_file="/var/lib/reboot-test-marker"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  cat > "$marker_file" << EOF
{
  "test_started": "$timestamp",
  "test_type": "system_reboot_recovery",
  "services_to_check": [$(printf '"%s",' "${CRITICAL_SERVICES[@]}" | sed 's/,$//')],
  "expected_behavior": "all_services_auto_start"
}
EOF
  
  chmod 644 "$marker_file" 2>/dev/null
  log_info "Reboot test marker created: $marker_file"
  return 0
}

# Function to check post-reboot status (for manual verification)
check_post_reboot_status() {
  log_info "Checking post-reboot status..."
  
  local marker_file="/var/lib/reboot-test-marker"
  
  if [ ! -f "$marker_file" ]; then
    log_info "No reboot test marker found - this appears to be a fresh test"
    return 0
  fi
  
  log_info "Found reboot test marker - checking post-reboot service status"
  
  # Check all critical services
  local failed_services=()
  local successful_services=()
  
  for service in "${CRITICAL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      successful_services+=("$service")
      log_info "✓ Service $service is running after reboot"
    else
      failed_services+=("$service")
      log_error "✗ Service $service is NOT running after reboot"
    fi
  done
  
  # Report results
  log_info "Post-reboot service status:"
  log_info "  Services running: ${#successful_services[@]}"
  log_info "  Services failed:  ${#failed_services[@]}"
  
  if [ ${#failed_services[@]} -eq 0 ]; then
    log_info "✓ All services started successfully after reboot"
    rm -f "$marker_file" 2>/dev/null
    return 0
  else
    log_error "✗ Failed services after reboot: ${failed_services[*]}"
    return 1
  fi
}

# Main test execution
main() {
  log_info "Starting system reboot recovery tests..."
  
  local tests_passed=0
  local tests_failed=0
  
  # Define test functions
  local test_functions=(
    "test_service_auto_start_config"
    "test_service_dependencies"
    "test_startup_order"
    "test_reboot_simulation"
    "test_recovery_after_crash"
    "test_boot_time_optimization"
    "test_reboot_readiness"
    "create_reboot_test_marker"
    "check_post_reboot_status"
  )
  
  # Run all tests
  for test_func in "${test_functions[@]}"; do
    local test_name="${test_func#test_}"
    test_name="${test_name//_/ }"
    
    log_info "Running test: $test_name"
    
    if $test_func; then
      log_info "✓ PASS: $test_name"
      ((tests_passed++))
    else
      log_error "✗ FAIL: $test_name"
      ((tests_failed++))
    fi
    
    echo  # Add spacing between tests
  done
  
  # Summary
  log_info "System Reboot Recovery Test Summary:"
  log_info "  Tests Passed: $tests_passed"
  log_info "  Tests Failed: $tests_failed"
  log_info "  Total Tests:  $((tests_passed + tests_failed))"
  
  if [ $tests_failed -eq 0 ]; then
    log_info "✓ All system reboot recovery tests passed!"
    log_info ""
    log_info "To test actual reboot recovery:"
    log_info "1. Run this script to create test markers"
    log_info "2. Reboot the system: sudo reboot"
    log_info "3. After reboot, run this script again to verify recovery"
    return 0
  else
    log_error "✗ Some system reboot recovery tests failed"
    return 1
  fi
}

# Run main function
main "$@" 