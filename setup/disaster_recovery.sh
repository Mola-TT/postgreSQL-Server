#!/bin/bash
# disaster_recovery.sh - Disaster Recovery System for PostgreSQL Server
# Part of Milestone 9

# Script directory
DISASTER_RECOVERY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables if not already loaded
if [ -z "$DISASTER_RECOVERY_ENABLED" ]; then
  # Load default environment
  if [ -f "$DISASTER_RECOVERY_SCRIPT_DIR/../conf/default.env" ]; then
    source "$DISASTER_RECOVERY_SCRIPT_DIR/../conf/default.env"
  fi
  
  # Load user environment if available
  if [ -f "$DISASTER_RECOVERY_SCRIPT_DIR/../conf/user.env" ]; then
    source "$DISASTER_RECOVERY_SCRIPT_DIR/../conf/user.env"
  fi
fi

# Source required libraries
if ! type log_info &>/dev/null; then
  # Set LOG_FILE to match the disaster recovery log path for consistent logging
  export LOG_FILE="$DISASTER_RECOVERY_LOG_PATH"
  source "$DISASTER_RECOVERY_SCRIPT_DIR/../lib/logger.sh"
fi

if ! type execute_silently &>/dev/null; then
  source "$DISASTER_RECOVERY_SCRIPT_DIR/../lib/utilities.sh"
fi

# Configuration variables with defaults
DISASTER_RECOVERY_ENABLED="${DISASTER_RECOVERY_ENABLED:-true}"
DISASTER_RECOVERY_SERVICE_NAME="${DISASTER_RECOVERY_SERVICE_NAME:-disaster-recovery}"
DISASTER_RECOVERY_LOG_PATH="${DISASTER_RECOVERY_LOG_PATH:-/var/log/disaster-recovery.log}"
DISASTER_RECOVERY_STATE_FILE="${DISASTER_RECOVERY_STATE_FILE:-/var/lib/postgresql/disaster_recovery_state.json}"
DISASTER_RECOVERY_TIMEOUT="${DISASTER_RECOVERY_TIMEOUT:-300}"
DISASTER_RECOVERY_CHECK_INTERVAL="${DISASTER_RECOVERY_CHECK_INTERVAL:-30}"
DISASTER_RECOVERY_EMAIL_ENABLED="${DISASTER_RECOVERY_EMAIL_ENABLED:-true}"
DISASTER_RECOVERY_EMAIL_RECIPIENT="${DISASTER_RECOVERY_EMAIL_RECIPIENT:-$EMAIL_RECIPIENT}"
DISASTER_RECOVERY_EMAIL_SENDER="${DISASTER_RECOVERY_EMAIL_SENDER:-$EMAIL_SENDER}"

# Critical services to monitor and recover
CRITICAL_SERVICES=(
  "postgresql"
  "pgbouncer"
  "nginx"
  "netdata"
  "pg-user-monitor"
)

# Service dependencies (service:depends_on_service1,service2)
SERVICE_DEPENDENCIES=(
  "pgbouncer:postgresql"
  "pg-user-monitor:postgresql,pgbouncer"
  "nginx:postgresql,pgbouncer"
  "netdata:postgresql"
)

# Function to log recovery events
log_recovery_event() {
  local event_type="$1"
  local service="$2"
  local details="$3"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Log to main log
  log_info "[$event_type] $service: $details"
  
  # Log to recovery state file
  local state_dir=$(dirname "$DISASTER_RECOVERY_STATE_FILE")
  mkdir -p "$state_dir" 2>/dev/null
  
  # Create recovery event record
  python3 -c "
import json
import os
from datetime import datetime

state_file = '$DISASTER_RECOVERY_STATE_FILE'
event = {
    'timestamp': '$timestamp',
    'event_type': '$event_type',
    'service': '$service',
    'details': '$details'
}

# Load existing state
state = {'recovery_events': []}
if os.path.exists(state_file):
    try:
        with open(state_file, 'r') as f:
            state = json.load(f)
    except:
        state = {'recovery_events': []}

if 'recovery_events' not in state:
    state['recovery_events'] = []

# Add new event
state['recovery_events'].append(event)

# Keep only last 100 events
state['recovery_events'] = state['recovery_events'][-100:]

# Save state
with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true
}

# Function to send recovery notification email
send_recovery_notification() {
  local event_type="$1"
  local service="$2"
  local details="$3"
  
  if [ "$DISASTER_RECOVERY_EMAIL_ENABLED" != "true" ]; then
    return 0
  fi
  
  local subject="[DBHub] [RECOVERY] $event_type - $service"
  local body="Disaster Recovery Event

Event Type: $event_type
Service: $service
Time: $(date '+%Y-%m-%d %H:%M:%S')
Details: $details

Server: $(hostname)
System Status: $(systemctl is-system-running 2>/dev/null || echo 'unknown')

This is an automated notification from the disaster recovery system."

  # Try to send email using available methods
  if command -v msmtp >/dev/null 2>&1; then
    echo -e "Subject: $subject\n\n$body" | msmtp "$DISASTER_RECOVERY_EMAIL_RECIPIENT" 2>/dev/null || true
  elif command -v sendmail >/dev/null 2>&1; then
    echo -e "Subject: $subject\n\n$body" | sendmail "$DISASTER_RECOVERY_EMAIL_RECIPIENT" 2>/dev/null || true
  fi
}

# Function to check if a service is running
is_service_running() {
  local service="$1"
  
  # Handle different service name patterns
  case "$service" in
    "postgresql")
      # Try multiple PostgreSQL service patterns
      for pg_service in "postgresql" "postgresql.service" "postgresql@*-main.service"; do
        if [[ "$pg_service" == *"*"* ]]; then
          # Handle wildcard services
          for actual_service in $(systemctl list-units --type=service | grep postgresql@ | awk '{print $1}' 2>/dev/null || echo ""); do
            if systemctl is-active --quiet "$actual_service" 2>/dev/null; then
              return 0
            fi
          done
        else
          if systemctl is-active --quiet "$pg_service" 2>/dev/null; then
            return 0
          fi
        fi
      done
      return 1
      ;;
    *)
      systemctl is-active --quiet "$service" 2>/dev/null
      return $?
      ;;
  esac
}

# Function to start a service with dependencies
start_service_with_dependencies() {
  local service="$1"
  local max_attempts=3
  local attempt=1
  
  log_info "Starting service: $service"
  
  # Check and start dependencies first
  for dep_rule in "${SERVICE_DEPENDENCIES[@]}"; do
    local dep_service="${dep_rule%%:*}"
    local dependencies="${dep_rule#*:}"
    
    if [ "$dep_service" = "$service" ]; then
      IFS=',' read -ra deps <<< "$dependencies"
      for dep in "${deps[@]}"; do
        if ! is_service_running "$dep"; then
          log_info "Starting dependency: $dep"
          start_service_with_dependencies "$dep"
          sleep 5
        fi
      done
      break
    fi
  done
  
  # Start the service
  while [ $attempt -le $max_attempts ]; do
    log_info "Attempting to start $service (attempt $attempt/$max_attempts)"
    
    if systemctl start "$service" >/dev/null 2>&1; then
      sleep 10  # Wait for service to fully start
      
      if is_service_running "$service"; then
        log_info "Successfully started service: $service"
        log_recovery_event "SERVICE_STARTED" "$service" "Service started successfully on attempt $attempt"
        send_recovery_notification "SERVICE_STARTED" "$service" "Service was successfully recovered and started"
        return 0
      else
        log_warn "Service $service started but not running properly"
      fi
    else
      log_warn "Failed to start service $service on attempt $attempt"
    fi
    
    ((attempt++))
    if [ $attempt -le $max_attempts ]; then
      sleep 15
    fi
  done
  
  log_error "Failed to start service $service after $max_attempts attempts"
  log_recovery_event "SERVICE_START_FAILED" "$service" "Failed to start after $max_attempts attempts"
  send_recovery_notification "SERVICE_START_FAILED" "$service" "Service failed to start after $max_attempts attempts"
  return 1
}

# Function to restart a service
restart_service() {
  local service="$1"
  local max_attempts=3
  local attempt=1
  
  log_info "Restarting service: $service"
  
  while [ $attempt -le $max_attempts ]; do
    log_info "Attempting to restart $service (attempt $attempt/$max_attempts)"
    
    if systemctl restart "$service" >/dev/null 2>&1; then
      sleep 10  # Wait for service to fully restart
      
      if is_service_running "$service"; then
        log_info "Successfully restarted service: $service"
        log_recovery_event "SERVICE_RESTARTED" "$service" "Service restarted successfully on attempt $attempt"
        send_recovery_notification "SERVICE_RESTARTED" "$service" "Service was successfully restarted"
        return 0
      else
        log_warn "Service $service restarted but not running properly"
      fi
    else
      log_warn "Failed to restart service $service on attempt $attempt"
    fi
    
    ((attempt++))
    if [ $attempt -le $max_attempts ]; then
      sleep 15
    fi
  done
  
  log_error "Failed to restart service $service after $max_attempts attempts"
  log_recovery_event "SERVICE_RESTART_FAILED" "$service" "Failed to restart after $max_attempts attempts"
  send_recovery_notification "SERVICE_RESTART_FAILED" "$service" "Service failed to restart after $max_attempts attempts"
  return 1
}

# Function to check PostgreSQL database integrity
check_database_integrity() {
  log_info "Checking PostgreSQL database integrity..."
  
  # Check if PostgreSQL is running
  if ! is_service_running "postgresql"; then
    log_error "PostgreSQL is not running, cannot check database integrity"
    return 1
  fi
  
  # Wait for PostgreSQL to be ready
  local timeout=60
  local count=0
  while [ $count -lt $timeout ]; do
    if su - postgres -c "psql -c 'SELECT 1;'" >/dev/null 2>&1; then
      break
    fi
    sleep 2
    ((count += 2))
  done
  
  if [ $count -ge $timeout ]; then
    log_error "PostgreSQL not responding after $timeout seconds"
    return 1
  fi
  
  # Check database connectivity
  if ! su - postgres -c "psql -c 'SELECT version();'" >/dev/null 2>&1; then
    log_error "Cannot connect to PostgreSQL database"
    log_recovery_event "DATABASE_CHECK_FAILED" "postgresql" "Cannot connect to database"
    return 1
  fi
  
  # Check for corruption (basic check)
  local corruption_found=false
  
  # Check system catalogs
  if ! su - postgres -c "psql -c 'SELECT count(*) FROM pg_class;'" >/dev/null 2>&1; then
    log_error "System catalog corruption detected"
    corruption_found=true
  fi
  
  # Check user database if specified
  if [ -n "$PG_DATABASE" ] && [ "$PG_DATABASE" != "postgres" ]; then
    if ! su - postgres -c "psql -d '$PG_DATABASE' -c 'SELECT 1;'" >/dev/null 2>&1; then
      log_error "User database $PG_DATABASE appears corrupted or inaccessible"
      corruption_found=true
    fi
  fi
  
  if [ "$corruption_found" = true ]; then
    log_recovery_event "DATABASE_CORRUPTION_DETECTED" "postgresql" "Database corruption detected during integrity check"
    send_recovery_notification "DATABASE_CORRUPTION_DETECTED" "postgresql" "Database corruption detected - manual intervention may be required"
    return 1
  fi
  
  log_info "Database integrity check passed"
  return 0
}

# Function to perform database recovery
perform_database_recovery() {
  log_info "Performing database recovery procedures..."
  
  # Stop PostgreSQL if running
  if is_service_running "postgresql"; then
    log_info "Stopping PostgreSQL for recovery..."
    systemctl stop postgresql >/dev/null 2>&1
    sleep 5
  fi
  
  # Check for PostgreSQL crash recovery
  local pg_data_dir="/var/lib/postgresql/*/main"
  for data_dir in $pg_data_dir; do
    if [ -d "$data_dir" ]; then
      # Check for recovery files
      if [ -f "$data_dir/recovery.signal" ] || [ -f "$data_dir/standby.signal" ]; then
        log_info "Found recovery signals in $data_dir"
      fi
      
      # Check for WAL files that need recovery
      if [ -d "$data_dir/pg_wal" ] && [ "$(ls -A "$data_dir/pg_wal" 2>/dev/null)" ]; then
        log_info "WAL files found, PostgreSQL will perform automatic recovery"
      fi
    fi
  done
  
  # Start PostgreSQL and let it perform automatic recovery
  log_info "Starting PostgreSQL for automatic recovery..."
  if start_service_with_dependencies "postgresql"; then
    # Wait for recovery to complete
    sleep 30
    
    # Check if recovery was successful
    if check_database_integrity; then
      log_info "Database recovery completed successfully"
      log_recovery_event "DATABASE_RECOVERY_SUCCESS" "postgresql" "Database recovery completed successfully"
      send_recovery_notification "DATABASE_RECOVERY_SUCCESS" "postgresql" "Database recovery completed successfully"
      return 0
    else
      log_error "Database recovery failed integrity check"
      log_recovery_event "DATABASE_RECOVERY_FAILED" "postgresql" "Database recovery failed integrity check"
      send_recovery_notification "DATABASE_RECOVERY_FAILED" "postgresql" "Database recovery failed - manual intervention required"
      return 1
    fi
  else
    log_error "Failed to start PostgreSQL for recovery"
    return 1
  fi
}

# Function to check system resources
check_system_resources() {
  local issues_found=false
  
  # Check disk space
  local disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
  if [ "$disk_usage" -gt 90 ]; then
    log_warn "Disk usage is at ${disk_usage}% - critically high"
    log_recovery_event "RESOURCE_WARNING" "system" "Disk usage at ${disk_usage}%"
    issues_found=true
  fi
  
  # Check memory usage
  local mem_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')
  if [ "$mem_usage" -gt 95 ]; then
    log_warn "Memory usage is at ${mem_usage}% - critically high"
    log_recovery_event "RESOURCE_WARNING" "system" "Memory usage at ${mem_usage}%"
    issues_found=true
  fi
  
  # Check load average
  local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
  local cpu_count=$(nproc)
  local load_threshold=$((cpu_count * 2))
  
  if (( $(echo "$load_avg > $load_threshold" | bc -l 2>/dev/null || echo "0") )); then
    log_warn "Load average $load_avg is high (threshold: $load_threshold)"
    log_recovery_event "RESOURCE_WARNING" "system" "High load average: $load_avg"
    issues_found=true
  fi
  
  if [ "$issues_found" = true ]; then
    send_recovery_notification "RESOURCE_WARNING" "system" "System resources are under stress - monitoring closely"
    return 1
  fi
  
  return 0
}

# Function to monitor and recover services
monitor_and_recover_services() {
  log_info "Starting service monitoring and recovery..."
  
  local services_recovered=0
  local services_failed=0
  
  for service in "${CRITICAL_SERVICES[@]}"; do
    if ! is_service_running "$service"; then
      log_warn "Service $service is not running - attempting recovery"
      log_recovery_event "SERVICE_DOWN" "$service" "Service detected as down, starting recovery"
      
      if start_service_with_dependencies "$service"; then
        ((services_recovered++))
      else
        ((services_failed++))
      fi
    else
      log_info "Service $service is running normally"
    fi
  done
  
  # Special check for PostgreSQL database integrity
  if is_service_running "postgresql"; then
    if ! check_database_integrity; then
      log_warn "Database integrity issues detected - attempting recovery"
      if perform_database_recovery; then
        ((services_recovered++))
      else
        ((services_failed++))
      fi
    fi
  fi
  
  # Check system resources
  check_system_resources
  
  if [ $services_recovered -gt 0 ]; then
    log_info "Recovery completed: $services_recovered services recovered, $services_failed failed"
    log_recovery_event "RECOVERY_SUMMARY" "system" "Recovered $services_recovered services, $services_failed failed"
  fi
  
  return $services_failed
}

# Function to run the disaster recovery monitoring loop
run_disaster_recovery_loop() {
  log_info "Starting disaster recovery monitoring loop (interval: ${DISASTER_RECOVERY_CHECK_INTERVAL}s)"
  
  while true; do
    monitor_and_recover_services
    
    # Wait for next check
    sleep "$DISASTER_RECOVERY_CHECK_INTERVAL"
  done
}

# Function to create systemd service for disaster recovery
create_systemd_service() {
  local service_name="$DISASTER_RECOVERY_SERVICE_NAME"
  local service_file="/etc/systemd/system/${service_name}.service"
  local script_path="$DISASTER_RECOVERY_SCRIPT_DIR/disaster_recovery.sh"
  
  log_info "Creating systemd service: $service_name"
  
  # Ensure log directory and file exist
  local log_dir=$(dirname "$DISASTER_RECOVERY_LOG_PATH")
  mkdir -p "$log_dir" 2>/dev/null
  touch "$DISASTER_RECOVERY_LOG_PATH" 2>/dev/null
  chmod 644 "$DISASTER_RECOVERY_LOG_PATH" 2>/dev/null
  
  # Create service file
  cat > "$service_file" << EOF
[Unit]
Description=Disaster Recovery System for PostgreSQL Server
After=network.target
Wants=postgresql.service pgbouncer.service nginx.service netdata.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/bin/bash $script_path --daemon
Restart=always
RestartSec=30
StandardOutput=append:$DISASTER_RECOVERY_LOG_PATH
StandardError=append:$DISASTER_RECOVERY_LOG_PATH

# Environment variables
Environment=DISASTER_RECOVERY_ENABLED=$DISASTER_RECOVERY_ENABLED
Environment=DISASTER_RECOVERY_CHECK_INTERVAL=$DISASTER_RECOVERY_CHECK_INTERVAL
Environment=DISASTER_RECOVERY_LOG_PATH=$DISASTER_RECOVERY_LOG_PATH
Environment=DISASTER_RECOVERY_STATE_FILE=$DISASTER_RECOVERY_STATE_FILE
Environment=DISASTER_RECOVERY_TIMEOUT=$DISASTER_RECOVERY_TIMEOUT
Environment=DISASTER_RECOVERY_EMAIL_ENABLED=$DISASTER_RECOVERY_EMAIL_ENABLED
Environment=DISASTER_RECOVERY_EMAIL_RECIPIENT=$DISASTER_RECOVERY_EMAIL_RECIPIENT
Environment=DISASTER_RECOVERY_EMAIL_SENDER=$DISASTER_RECOVERY_EMAIL_SENDER

[Install]
WantedBy=multi-user.target
EOF

  # Set proper permissions
  chmod 644 "$service_file" 2>/dev/null
  
  # Reload systemd and enable service
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable "$service_name" >/dev/null 2>&1
  
  log_info "Systemd service created and enabled: $service_name"
}

# Function to start the disaster recovery service
start_disaster_recovery_service() {
  local service_name="$DISASTER_RECOVERY_SERVICE_NAME"
  
  log_info "Starting disaster recovery service..."
  
  # Stop service if it's already running
  systemctl stop "$service_name" >/dev/null 2>&1
  
  # Start the service
  if systemctl start "$service_name" >/dev/null 2>&1; then
    log_info "Disaster recovery service started successfully"
    
    # Check service status
    if systemctl is-active --quiet "$service_name"; then
      log_info "Service is running and active"
      return 0
    else
      log_error "Service started but is not active"
      return 1
    fi
  else
    log_error "Failed to start disaster recovery service"
    return 1
  fi
}

# Function to stop the disaster recovery service
stop_disaster_recovery_service() {
  local service_name="$DISASTER_RECOVERY_SERVICE_NAME"
  
  log_info "Stopping disaster recovery service..."
  
  if systemctl stop "$service_name" >/dev/null 2>&1; then
    log_info "Disaster recovery service stopped successfully"
    return 0
  else
    log_error "Failed to stop disaster recovery service"
    return 1
  fi
}

# Function to check service status
check_service_status() {
  local service_name="$DISASTER_RECOVERY_SERVICE_NAME"
  
  if systemctl is-active --quiet "$service_name"; then
    log_info "Disaster recovery service is running"
    return 0
  else
    log_warn "Disaster recovery service is not running"
    return 1
  fi
}

# Function to perform immediate system recovery
perform_immediate_recovery() {
  log_info "Performing immediate system recovery..."
  
  log_recovery_event "IMMEDIATE_RECOVERY_START" "system" "Manual immediate recovery initiated"
  send_recovery_notification "IMMEDIATE_RECOVERY_START" "system" "Immediate recovery procedure started"
  
  # Run one-time recovery check
  if monitor_and_recover_services; then
    log_info "Immediate recovery completed successfully"
    log_recovery_event "IMMEDIATE_RECOVERY_SUCCESS" "system" "Manual immediate recovery completed successfully"
    send_recovery_notification "IMMEDIATE_RECOVERY_SUCCESS" "system" "Immediate recovery completed successfully"
    return 0
  else
    log_error "Immediate recovery encountered issues"
    log_recovery_event "IMMEDIATE_RECOVERY_ISSUES" "system" "Manual immediate recovery completed with issues"
    send_recovery_notification "IMMEDIATE_RECOVERY_ISSUES" "system" "Immediate recovery completed but some issues remain"
    return 1
  fi
}

# Main setup function
setup_disaster_recovery() {
  log_info "Setting up disaster recovery system..."
  
  # Check if disaster recovery is enabled
  if [ "$DISASTER_RECOVERY_ENABLED" != "true" ]; then
    log_info "Disaster recovery is disabled (DISASTER_RECOVERY_ENABLED != true)"
    return 0
  fi
  
  # Check dependencies
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "Python3 is required for disaster recovery system"
    return 1
  fi
  
  if ! command -v bc >/dev/null 2>&1; then
    log_info "Installing bc for mathematical calculations..."
    apt-get update >/dev/null 2>&1
    apt-get install -y bc >/dev/null 2>&1
  fi
  
  # Create log directory
  local log_dir=$(dirname "$DISASTER_RECOVERY_LOG_PATH")
  mkdir -p "$log_dir" 2>/dev/null
  
  # Create log file with proper permissions
  touch "$DISASTER_RECOVERY_LOG_PATH" 2>/dev/null
  chown root:root "$DISASTER_RECOVERY_LOG_PATH" 2>/dev/null
  chmod 644 "$DISASTER_RECOVERY_LOG_PATH" 2>/dev/null
  
  # Create state directory
  local state_dir=$(dirname "$DISASTER_RECOVERY_STATE_FILE")
  mkdir -p "$state_dir" 2>/dev/null
  chown postgres:postgres "$state_dir" 2>/dev/null
  
  # Create systemd service
  create_systemd_service
  
  # Start disaster recovery service
  start_disaster_recovery_service
  
  log_info "Disaster recovery system setup completed successfully"
}

# Command line interface
case "${1:-setup}" in
  "setup")
    setup_disaster_recovery
    ;;
  "--daemon")
    run_disaster_recovery_loop
    ;;
  "start")
    start_disaster_recovery_service
    ;;
  "stop")
    stop_disaster_recovery_service
    ;;
  "restart")
    stop_disaster_recovery_service
    sleep 2
    start_disaster_recovery_service
    ;;
  "status")
    check_service_status
    ;;
  "recover")
    perform_immediate_recovery
    ;;
  "check")
    monitor_and_recover_services
    ;;
  *)
    echo "Usage: $0 {setup|start|stop|restart|status|recover|check|--daemon}"
    echo "  setup    - Set up the disaster recovery system"
    echo "  start    - Start the disaster recovery service"
    echo "  stop     - Stop the disaster recovery service"
    echo "  restart  - Restart the disaster recovery service"
    echo "  status   - Check service status"
    echo "  recover  - Perform immediate recovery"
    echo "  check    - Run one-time service check and recovery"
    echo "  --daemon - Run in daemon mode (used by systemd)"
    exit 1
    ;;
esac 