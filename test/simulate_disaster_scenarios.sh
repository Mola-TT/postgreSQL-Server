#!/bin/bash
# simulate_disaster_scenarios.sh - Simulate various disaster scenarios for testing
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

# Simulation configuration
SIMULATION_LOG_PATH="${DISASTER_RECOVERY_LOG_PATH:-/var/log/disaster-recovery.log}.simulation"
RECOVERY_SCRIPT="$SCRIPT_DIR/../setup/disaster_recovery.sh"
SIMULATION_TIMEOUT=300  # 5 minutes max per simulation

# Safety checks
SAFETY_MODE="${SAFETY_MODE:-true}"  # Prevent actual damage in production

# Function to check safety mode
check_safety_mode() {
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "Running in SAFETY MODE - simulations will not cause actual damage"
    return 0
  else
    log_warn "SAFETY MODE is disabled - simulations may cause actual service disruption"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
      log_info "Simulation cancelled by user"
      exit 0
    fi
  fi
}

# Function to simulate service failure
simulate_service_failure() {
  local service="$1"
  local duration="${2:-60}"  # Default 60 seconds
  
  log_info "Simulating failure of service: $service for ${duration}s"
  
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "[SIMULATION] Would stop service $service for ${duration}s"
    log_info "[SIMULATION] Service failure simulation completed (safety mode)"
    return 0
  fi
  
  # Check if service is running
  if ! systemctl is-active --quiet "$service" 2>/dev/null; then
    log_warn "Service $service is not running - cannot simulate failure"
    return 1
  fi
  
  # Stop the service
  log_info "Stopping service: $service"
  if systemctl stop "$service" >/dev/null 2>&1; then
    log_info "Service $service stopped successfully"
    
    # Wait for specified duration
    log_info "Waiting ${duration}s for recovery system to detect failure..."
    sleep "$duration"
    
    # Check if recovery system restarted the service
    if systemctl is-active --quiet "$service" 2>/dev/null; then
      log_info "✓ Recovery system successfully restarted $service"
      return 0
    else
      log_warn "Recovery system did not restart $service - manual intervention needed"
      # Manually restart for safety
      systemctl start "$service" >/dev/null 2>&1
      return 1
    fi
  else
    log_error "Failed to stop service $service"
    return 1
  fi
}

# Function to simulate database corruption
simulate_database_corruption() {
  local corruption_type="${1:-minor}"  # minor, major, catastrophic
  
  log_info "Simulating database corruption: $corruption_type"
  
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "[SIMULATION] Would simulate $corruption_type database corruption"
    log_info "[SIMULATION] Database corruption simulation completed (safety mode)"
    return 0
  fi
  
  case "$corruption_type" in
    "minor")
      # Simulate minor corruption by creating a temporary lock file
      log_info "Creating temporary database lock to simulate minor corruption"
      touch "/tmp/pg_simulate_corruption.lock"
      sleep 30
      rm -f "/tmp/pg_simulate_corruption.lock"
      ;;
    "major")
      log_warn "Major corruption simulation not implemented in safety mode"
      ;;
    "catastrophic")
      log_warn "Catastrophic corruption simulation not implemented in safety mode"
      ;;
    *)
      log_error "Unknown corruption type: $corruption_type"
      return 1
      ;;
  esac
  
  return 0
}

# Function to simulate network disruption
simulate_network_disruption() {
  local duration="${1:-60}"  # Default 60 seconds
  
  log_info "Simulating network disruption for ${duration}s"
  
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "[SIMULATION] Would disrupt network for ${duration}s"
    log_info "[SIMULATION] Network disruption simulation completed (safety mode)"
    return 0
  fi
  
  # Block external network access temporarily
  log_info "Blocking external network access"
  if iptables -A OUTPUT -p tcp --dport 80 -j DROP 2>/dev/null && \
     iptables -A OUTPUT -p tcp --dport 443 -j DROP 2>/dev/null; then
    
    log_info "Network access blocked - waiting ${duration}s"
    sleep "$duration"
    
    # Restore network access
    log_info "Restoring network access"
    iptables -D OUTPUT -p tcp --dport 80 -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --dport 443 -j DROP 2>/dev/null
    
    log_info "✓ Network disruption simulation completed"
    return 0
  else
    log_error "Failed to simulate network disruption"
    return 1
  fi
}

# Function to simulate disk space exhaustion
simulate_disk_exhaustion() {
  local target_usage="${1:-95}"  # Target disk usage percentage
  
  log_info "Simulating disk space exhaustion (target: ${target_usage}%)"
  
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "[SIMULATION] Would fill disk to ${target_usage}% usage"
    log_info "[SIMULATION] Disk exhaustion simulation completed (safety mode)"
    return 0
  fi
  
  # Get current disk usage
  local current_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
  
  if [ "$current_usage" -ge "$target_usage" ]; then
    log_warn "Disk usage already at ${current_usage}% - simulation not needed"
    return 0
  fi
  
  # Calculate space to fill
  local available_space=$(df / | awk 'NR==2 {print $4}')
  local total_space=$(df / | awk 'NR==2 {print $2}')
  local target_free=$((total_space * (100 - target_usage) / 100))
  local space_to_fill=$((available_space - target_free))
  
  if [ "$space_to_fill" -gt 0 ]; then
    log_info "Creating temporary file to fill ${space_to_fill}KB"
    local temp_file="/tmp/disk_fill_simulation.tmp"
    
    # Create large file
    if dd if=/dev/zero of="$temp_file" bs=1024 count="$space_to_fill" 2>/dev/null; then
      log_info "Disk filled to target usage - waiting for recovery detection"
      sleep 60
      
      # Clean up
      rm -f "$temp_file"
      log_info "✓ Disk exhaustion simulation completed"
      return 0
    else
      log_error "Failed to create disk fill file"
      return 1
    fi
  else
    log_warn "Cannot safely fill disk to target usage"
    return 1
  fi
}

# Function to simulate memory exhaustion
simulate_memory_exhaustion() {
  local duration="${1:-60}"  # Default 60 seconds
  
  log_info "Simulating memory exhaustion for ${duration}s"
  
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "[SIMULATION] Would exhaust memory for ${duration}s"
    log_info "[SIMULATION] Memory exhaustion simulation completed (safety mode)"
    return 0
  fi
  
  # Create memory pressure using stress tool if available
  if command -v stress >/dev/null 2>&1; then
    log_info "Using stress tool to create memory pressure"
    stress --vm 2 --vm-bytes 512M --timeout "${duration}s" >/dev/null 2>&1 &
    local stress_pid=$!
    
    sleep "$duration"
    
    # Ensure stress process is terminated
    kill "$stress_pid" 2>/dev/null || true
    wait "$stress_pid" 2>/dev/null || true
    
    log_info "✓ Memory exhaustion simulation completed"
    return 0
  else
    log_warn "stress tool not available - installing..."
    if apt-get update >/dev/null 2>&1 && apt-get install -y stress >/dev/null 2>&1; then
      # Retry with stress tool
      simulate_memory_exhaustion "$duration"
    else
      log_error "Cannot install stress tool for memory simulation"
      return 1
    fi
  fi
}

# Function to simulate system reboot
simulate_system_reboot() {
  log_info "Simulating system reboot scenario"
  
  if [ "$SAFETY_MODE" = "true" ]; then
    log_info "[SIMULATION] Would reboot system and test recovery"
    log_info "[SIMULATION] System reboot simulation completed (safety mode)"
    return 0
  fi
  
  log_warn "System reboot simulation requires actual reboot"
  log_warn "This will cause service interruption"
  
  read -p "Proceed with actual reboot? (yes/no): " confirm
  if [ "$confirm" = "yes" ]; then
    log_info "Scheduling system reboot in 1 minute"
    shutdown -r +1 "Disaster recovery simulation reboot"
    return 0
  else
    log_info "System reboot simulation cancelled"
    return 1
  fi
}

# Function to run disaster scenario simulation
run_disaster_simulation() {
  local scenario="$1"
  local duration="${2:-60}"
  
  log_info "Starting disaster scenario simulation: $scenario"
  
  # Record start time
  local start_time=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Run the simulation
  case "$scenario" in
    "service_failure_postgresql")
      simulate_service_failure "postgresql" "$duration"
      ;;
    "service_failure_pgbouncer")
      simulate_service_failure "pgbouncer" "$duration"
      ;;
    "service_failure_nginx")
      simulate_service_failure "nginx" "$duration"
      ;;
    "service_failure_netdata")
      simulate_service_failure "netdata" "$duration"
      ;;
    "database_corruption_minor")
      simulate_database_corruption "minor"
      ;;
    "database_corruption_major")
      simulate_database_corruption "major"
      ;;
    "network_disruption")
      simulate_network_disruption "$duration"
      ;;
    "disk_exhaustion")
      simulate_disk_exhaustion "95"
      ;;
    "memory_exhaustion")
      simulate_memory_exhaustion "$duration"
      ;;
    "system_reboot")
      simulate_system_reboot
      ;;
    *)
      log_error "Unknown disaster scenario: $scenario"
      return 1
      ;;
  esac
  
  local result=$?
  local end_time=$(date '+%Y-%m-%d %H:%M:%S')
  
  if [ $result -eq 0 ]; then
    log_info "✓ Disaster simulation completed successfully: $scenario"
  else
    log_error "✗ Disaster simulation failed: $scenario"
  fi
  
  log_info "Simulation duration: $start_time to $end_time"
  return $result
}

# Function to run comprehensive disaster simulation suite
run_comprehensive_simulation() {
  log_info "Starting comprehensive disaster simulation suite..."
  
  local simulations=(
    "service_failure_postgresql:90"
    "service_failure_pgbouncer:60"
    "service_failure_nginx:60"
    "service_failure_netdata:30"
    "database_corruption_minor:0"
    "network_disruption:45"
    "disk_exhaustion:0"
    "memory_exhaustion:30"
  )
  
  local passed=0
  local failed=0
  
  for sim in "${simulations[@]}"; do
    local scenario="${sim%%:*}"
    local duration="${sim#*:}"
    
    if run_disaster_simulation "$scenario" "$duration"; then
      ((passed++))
    else
      ((failed++))
    fi
    
    # Wait between simulations
    log_info "Waiting 30s before next simulation..."
    sleep 30
  done
  
  log_info "Comprehensive simulation results:"
  log_info "  Simulations Passed: $passed"
  log_info "  Simulations Failed: $failed"
  log_info "  Total Simulations:  $((passed + failed))"
  
  if [ $failed -eq 0 ]; then
    log_info "✓ All disaster simulations completed successfully!"
    return 0
  else
    log_error "✗ Some disaster simulations failed"
    return 1
  fi
}

# Function to show available scenarios
show_scenarios() {
  echo "Available disaster scenarios:"
  echo "  service_failure_postgresql  - Simulate PostgreSQL service failure"
  echo "  service_failure_pgbouncer   - Simulate pgbouncer service failure"
  echo "  service_failure_nginx       - Simulate Nginx service failure"
  echo "  service_failure_netdata     - Simulate Netdata service failure"
  echo "  database_corruption_minor   - Simulate minor database corruption"
  echo "  database_corruption_major   - Simulate major database corruption"
  echo "  network_disruption          - Simulate network connectivity issues"
  echo "  disk_exhaustion             - Simulate disk space exhaustion"
  echo "  memory_exhaustion           - Simulate memory exhaustion"
  echo "  system_reboot               - Simulate system reboot"
  echo "  comprehensive               - Run all simulations in sequence"
}

# Main function
main() {
  local scenario="${1:-}"
  local duration="${2:-60}"
  
  # Check safety mode
  check_safety_mode
  
  if [ -z "$scenario" ]; then
    echo "Usage: $0 <scenario> [duration]"
    echo ""
    show_scenarios
    exit 1
  fi
  
  if [ "$scenario" = "list" ]; then
    show_scenarios
    exit 0
  fi
  
  if [ "$scenario" = "comprehensive" ]; then
    run_comprehensive_simulation
  else
    run_disaster_simulation "$scenario" "$duration"
  fi
}

# Run main function
main "$@" 