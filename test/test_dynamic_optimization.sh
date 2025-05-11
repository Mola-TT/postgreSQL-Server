#!/bin/bash
# test_dynamic_optimization.sh - Test script for dynamic optimization functionality
# Part of Milestone 6

# Get script directory
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
SETUP_DIR="$PROJECT_DIR/setup"

# Source the logger functions
source "$LIB_DIR/logger.sh"

# Source utilities
source "$LIB_DIR/utilities.sh"

# Test header function
test_header() {
  local title="$1"
  echo ""
  log_info "========== $title =========="
  echo ""
}

# Test hardware detection functions
test_hardware_detection() {
  test_header "Testing Hardware Detection Functions"
  
  # Source the dynamic_optimization script to access its functions
  source "$SETUP_DIR/dynamic_optimization.sh"
  
  # Test CPU cores detection
  log_info "Testing CPU cores detection..."
  local cpu_cores=$(detect_cpu_cores)
  
  if [ -n "$cpu_cores" ] && [ "$cpu_cores" -gt 0 ]; then
    log_pass "Detected $cpu_cores CPU cores"
  else
    log_error "CPU cores detection failed"
    exit 1
  fi
  
  # Test memory detection
  log_info "Testing memory detection..."
  local total_memory_mb=$(detect_total_memory)
  
  if [ -n "$total_memory_mb" ] && [ "$total_memory_mb" -gt 0 ]; then
    log_pass "Detected $total_memory_mb MB of memory"
  else
    log_error "Memory detection failed"
    exit 1
  fi
  
  # Test disk size detection
  log_info "Testing disk size detection..."
  local disk_size_gb=$(detect_disk_size)
  
  if [ -n "$disk_size_gb" ] && [ "$disk_size_gb" -gt 0 ]; then
    log_pass "Detected $disk_size_gb GB of disk space"
  else
    log_error "Disk size detection failed"
    exit 1
  fi
}

# Test parameter calculation functions
test_parameter_calculations() {
  test_header "Testing Parameter Calculation Functions"
  
  # Source the dynamic_optimization script to access its functions
  source "$SETUP_DIR/dynamic_optimization.sh"
  
  # Get hardware specs for calculations
  local cpu_cores=$(detect_cpu_cores)
  local total_memory_mb=$(detect_total_memory)
  
  # Test PostgreSQL parameter calculations
  log_info "Testing PostgreSQL parameter calculations..."
  
  # Test max_connections calculation
  local max_connections=$(calculate_max_connections "$total_memory_mb" "$cpu_cores")
  if [ -n "$max_connections" ] && [ "$max_connections" -gt 0 ]; then
    log_pass "Calculated max_connections: $max_connections"
  else
    log_error "max_connections calculation failed"
    exit 1
  fi
  
  # Test shared_buffers calculation
  local shared_buffers_mb=$(calculate_shared_buffers "$total_memory_mb")
  if [ -n "$shared_buffers_mb" ] && [ "$shared_buffers_mb" -gt 0 ]; then
    log_pass "Calculated shared_buffers: $shared_buffers_mb MB"
  else
    log_error "shared_buffers calculation failed"
    exit 1
  fi
  
  # Test work_mem calculation
  local work_mem_mb=$(calculate_work_mem "$total_memory_mb" "$max_connections" "$cpu_cores")
  if [ -n "$work_mem_mb" ] && [ "$work_mem_mb" -gt 0 ]; then
    log_pass "Calculated work_mem: $work_mem_mb MB"
  else
    log_error "work_mem calculation failed"
    exit 1
  fi
  
  # Test effective_cache_size calculation
  local effective_cache_size_mb=$(calculate_effective_cache_size "$total_memory_mb")
  if [ -n "$effective_cache_size_mb" ] && [ "$effective_cache_size_mb" -gt 0 ]; then
    log_pass "Calculated effective_cache_size: $effective_cache_size_mb MB"
  else
    log_error "effective_cache_size calculation failed"
    exit 1
  fi
  
  # Test pgbouncer parameter calculations
  log_info "Testing pgbouncer parameter calculations..."
  
  # Test default_pool_size calculation
  local default_pool_size=$(calculate_pgb_default_pool_size "$cpu_cores")
  if [ -n "$default_pool_size" ] && [ "$default_pool_size" -gt 0 ]; then
    log_pass "Calculated pgbouncer default_pool_size: $default_pool_size"
  else
    log_error "pgbouncer default_pool_size calculation failed"
    exit 1
  fi
  
  # Test max_client_conn calculation
  local max_client_conn=$(calculate_pgb_max_client_conn "$max_connections" "$cpu_cores" "$total_memory_mb")
  if [ -n "$max_client_conn" ] && [ "$max_client_conn" -gt 0 ]; then
    log_pass "Calculated pgbouncer max_client_conn: $max_client_conn"
  else
    log_error "pgbouncer max_client_conn calculation failed"
    exit 1
  fi
  
  # Test reserve_pool_size calculation
  local reserve_pool_size=$(calculate_pgb_reserve_pool_size "$default_pool_size")
  if [ -n "$reserve_pool_size" ] && [ "$reserve_pool_size" -gt 0 ]; then
    log_pass "Calculated pgbouncer reserve_pool_size: $reserve_pool_size"
  else
    log_error "pgbouncer reserve_pool_size calculation failed"
    exit 1
  fi
  
  # Test pool_mode determination
  local pool_mode=$(determine_pool_mode "$cpu_cores" "$total_memory_mb")
  if [ -n "$pool_mode" ]; then
    log_pass "Determined pgbouncer pool_mode: $pool_mode"
  else
    log_error "pgbouncer pool_mode determination failed"
    exit 1
  fi
}

# Test configuration file generation
test_config_generation() {
  test_header "Testing Configuration File Generation"
  
  # Test PostgreSQL configuration generation
  log_info "Testing PostgreSQL configuration file generation..."
  
  # Create a temporary directory for testing
  local test_pg_conf_dir="/tmp/pg_conf_test"
  mkdir -p "$test_pg_conf_dir/conf.d"
  
  # Create a mock pg_lsclusters function for testing
  pg_lsclusters() {
    echo "14 main 5432 online postgres /var/lib/postgresql/14/main /var/log/postgresql/postgresql-14-main.log"
  }
  export -f pg_lsclusters
  
  # Mock systemctl for testing
  systemctl() {
    case "$1" in
      is-active)
        return 0  # Return success to indicate service is active
        ;;
      reload|restart)
        return 0  # Return success for reload/restart
        ;;
      *)
        return 1  # Return failure for unknown commands
        ;;
    esac
  }
  export -f systemctl
  
  # Create a mock directory structure for PostgreSQL configuration
  mkdir -p "/tmp/etc/postgresql/14/main/conf.d"
  
  # Modify the config file path in the optimization function (temporarily)
  sed -i.bak "s|/etc/postgresql/\$(pg_lsclusters.*)/conf.d/90-dynamic-optimization.conf|$test_pg_conf_dir/conf.d/90-dynamic-optimization.conf|g" "$SETUP_DIR/dynamic_optimization.sh"
  
  # Source the modified script
  source "$SETUP_DIR/dynamic_optimization.sh"
  
  # Run the function
  optimize_postgresql
  
  # Check if configuration file was created
  if [ -f "$test_pg_conf_dir/conf.d/90-dynamic-optimization.conf" ]; then
    log_pass "PostgreSQL configuration file generated successfully"
    
    # Check if essential parameters are present
    if grep -q "shared_buffers" "$test_pg_conf_dir/conf.d/90-dynamic-optimization.conf" && 
       grep -q "work_mem" "$test_pg_conf_dir/conf.d/90-dynamic-optimization.conf" &&
       grep -q "max_connections" "$test_pg_conf_dir/conf.d/90-dynamic-optimization.conf"; then
      log_pass "PostgreSQL configuration contains required parameters"
    else
      log_error "PostgreSQL configuration is missing required parameters"
      exit 1
    fi
  else
    log_error "PostgreSQL configuration file generation failed"
    exit 1
  fi
  
  # Restore the original script
  mv "$SETUP_DIR/dynamic_optimization.sh.bak" "$SETUP_DIR/dynamic_optimization.sh"
  
  # Test pgbouncer configuration generation
  log_info "Testing pgbouncer configuration file generation..."
  
  # Create a mock pgbouncer.ini
  local test_pgb_conf="/tmp/pgbouncer.ini"
  
  cat > "$test_pgb_conf" << EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
listen_addr = *
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
ignore_startup_parameters = extra_float_digits
EOF
  
  # Modify the config file path in the pgbouncer optimization function (temporarily)
  sed -i.bak "s|/etc/pgbouncer/pgbouncer.ini|$test_pgb_conf|g" "$SETUP_DIR/dynamic_optimization.sh"
  
  # Source the modified script
  source "$SETUP_DIR/dynamic_optimization.sh"
  
  # Run the function
  optimize_pgbouncer
  
  # Check if configuration file was updated
  if [ -f "$test_pgb_conf" ]; then
    log_pass "pgbouncer configuration file generated successfully"
    
    # Check if essential parameters are present
    if grep -q "pool_mode" "$test_pgb_conf" && 
       grep -q "max_client_conn" "$test_pgb_conf" &&
       grep -q "default_pool_size" "$test_pgb_conf"; then
      log_pass "pgbouncer configuration contains required parameters"
    else
      log_error "pgbouncer configuration is missing required parameters"
      exit 1
    fi
  else
    log_error "pgbouncer configuration file generation failed"
    exit 1
  fi
  
  # Restore the original script
  mv "$SETUP_DIR/dynamic_optimization.sh.bak" "$SETUP_DIR/dynamic_optimization.sh"
  
  # Clean up
  rm -rf "$test_pg_conf_dir" "/tmp/etc" "$test_pgb_conf"
}

# Test hardware change detection
test_hardware_change_detector() {
  test_header "Testing Hardware Change Detector"
  
  # Source the hardware_change_detector script
  source "$SETUP_DIR/hardware_change_detector.sh"
  
  # Test hardware specs collection
  log_info "Testing hardware specifications collection..."
  
  # Override the specs file location for testing
  HARDWARE_SPECS_FILE="/tmp/hardware_specs.json"
  PREVIOUS_SPECS_FILE="/tmp/previous_hardware_specs.json"
  
  # Run the collection function
  collect_hardware_specs
  
  # Check if the specs file was created
  if [ -f "$HARDWARE_SPECS_FILE" ]; then
    log_pass "Hardware specifications collected successfully"
    
    # Check if essential sections are present
    if grep -q "cpu" "$HARDWARE_SPECS_FILE" && 
       grep -q "memory" "$HARDWARE_SPECS_FILE" &&
       grep -q "disk" "$HARDWARE_SPECS_FILE"; then
      log_pass "Hardware specs file contains required sections"
    else
      log_error "Hardware specs file is missing required sections"
      exit 1
    fi
  else
    log_error "Hardware specifications collection failed"
    exit 1
  fi
  
  # Test hardware comparison with no changes
  log_info "Testing hardware comparison with no changes..."
  
  # Copy current specs as previous specs
  cp "$HARDWARE_SPECS_FILE" "$PREVIOUS_SPECS_FILE"
  
  # Run comparison
  if compare_hardware_specs; then
    log_error "Hardware change incorrectly detected when no changes were made"
    exit 1
  else
    log_pass "Correctly detected no significant hardware changes"
  fi
  
  # Test hardware comparison with significant changes
  log_info "Testing hardware comparison with significant changes..."
  
  # Create a modified previous specs file with different values
  jq '.cpu.cores = .cpu.cores + 2 | .memory.total_mb = .memory.total_mb * 2' "$HARDWARE_SPECS_FILE" > "$PREVIOUS_SPECS_FILE"
  
  # Run comparison
  if compare_hardware_specs; then
    log_pass "Correctly detected significant hardware changes"
  else
    log_error "Failed to detect significant hardware changes"
    exit 1
  fi
  
  # Clean up
  rm -f "$HARDWARE_SPECS_FILE" "$PREVIOUS_SPECS_FILE"
}

# Test report generation
test_report_generation() {
  test_header "Testing Optimization Report Generation"
  
  # Source the dynamic_optimization script
  source "$SETUP_DIR/dynamic_optimization.sh"
  
  # Override the report directory for testing
  local test_report_dir="/tmp/optimization_reports"
  mkdir -p "$test_report_dir"
  
  # Modify the report directory in the function (temporarily)
  sed -i.bak "s|/var/lib/postgresql/optimization_reports|$test_report_dir|g" "$SETUP_DIR/dynamic_optimization.sh"
  
  # Source the modified script
  source "$SETUP_DIR/dynamic_optimization.sh"
  
  # Generate report
  log_info "Testing optimization report generation..."
  local report_file=$(generate_optimization_report)
  
  # Check if report was created
  if [ -f "$report_file" ]; then
    log_pass "Optimization report generated successfully: $report_file"
    
    # Check if essential sections are present
    if grep -q "Hardware Specifications" "$report_file" && 
       grep -q "PostgreSQL Configuration" "$report_file" &&
       grep -q "pgbouncer Configuration" "$report_file" &&
       grep -q "Performance Recommendations" "$report_file"; then
      log_pass "Report contains all required sections"
    else
      log_error "Report is missing required sections"
      exit 1
    fi
  else
    log_error "Report generation failed"
    exit 1
  fi
  
  # Restore the original script
  mv "$SETUP_DIR/dynamic_optimization.sh.bak" "$SETUP_DIR/dynamic_optimization.sh"
  
  # Clean up
  rm -rf "$test_report_dir"
}

# Main test function
main() {
  log_info "Starting dynamic optimization test suite..."
  
  # Check if jq is installed (needed for JSON testing)
  if ! command -v jq >/dev/null 2>&1; then
    log_info "Installing jq for JSON testing..."
    apt_install_with_retry "jq" 5 30
  fi
  
  # Run tests
  test_hardware_detection
  test_parameter_calculations
  test_config_generation
  test_hardware_change_detector
  test_report_generation
  
  log_info "All dynamic optimization tests completed successfully!"
}

# If script is run directly, execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 