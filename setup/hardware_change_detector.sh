#!/bin/bash
# hardware_change_detector.sh - Detects hardware changes and triggers reconfiguration
# Part of Milestone 6
# This script implements a service to monitor hardware changes and perform reconfiguration

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory - using unique variable name to avoid conflicts
HW_DETECTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW_DETECTOR_LIB_DIR="$HW_DETECTOR_SCRIPT_DIR/../lib"
HW_DETECTOR_CONF_DIR="$HW_DETECTOR_SCRIPT_DIR/../conf"

# Source the logger functions
source "$HW_DETECTOR_LIB_DIR/logger.sh"

# Source utilities
source "$HW_DETECTOR_LIB_DIR/utilities.sh"

# Hardware specs file location
HARDWARE_SPECS_FILE="/var/lib/postgresql/hardware_specs.json"
PREVIOUS_SPECS_FILE="/var/lib/postgresql/previous_hardware_specs.json"

# Create directory if it doesn't exist
create_specs_directory() {
  if [ ! -d "$(dirname "$HARDWARE_SPECS_FILE")" ]; then
    log_info "Creating directory for hardware specs..."
    mkdir -p "$(dirname "$HARDWARE_SPECS_FILE")" 2>/dev/null || true
    chown postgres:postgres "$(dirname "$HARDWARE_SPECS_FILE")" 2>/dev/null || true
  fi
}

# Collect current hardware specifications
collect_hardware_specs() {
  log_info "Collecting current hardware specifications..."
  
  # CPU Cores
  local cpu_cores
  if command -v nproc >/dev/null 2>&1; then
    cpu_cores=$(nproc)
  else
    cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
  fi
  
  # CPU Model
  local cpu_model
  cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -n 1 | cut -d':' -f2 | xargs || echo "Unknown")
  
  # Memory
  local total_memory_kb
  local total_memory_mb
  if command -v free >/dev/null 2>&1; then
    total_memory_kb=$(free | grep -i 'Mem:' | awk '{print $2}')
  else
    total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  fi
  total_memory_mb=$((total_memory_kb / 1024))
  
  # Disk Size
  local data_directory
  local disk_size_kb
  local disk_size_gb
  
  # Get PostgreSQL data directory
  data_directory=$(su - postgres -c "psql -t -c \"SHOW data_directory;\"" 2>/dev/null | grep -v '^$' || echo "/var/lib/postgresql")
  
  # Get disk size
  disk_size_kb=$(df -k "$data_directory" | awk 'NR==2 {print $2}' || echo "0")
  disk_size_gb=$((disk_size_kb / 1024 / 1024))
  
  # Swap Size
  local swap_size_kb
  local swap_size_mb
  if command -v free >/dev/null 2>&1; then
    swap_size_kb=$(free | grep -i 'Swap:' | awk '{print $2}')
  else
    swap_size_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  fi
  swap_size_mb=$((swap_size_kb / 1024))
  
  # Timestamp
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  # Create JSON file with collected specifications
  cat > "$HARDWARE_SPECS_FILE" << EOF
{
  "timestamp": "$timestamp",
  "cpu": {
    "cores": $cpu_cores,
    "model": "$cpu_model"
  },
  "memory": {
    "total_mb": $total_memory_mb,
    "swap_mb": $swap_size_mb
  },
  "disk": {
    "data_directory": "$data_directory",
    "size_gb": $disk_size_gb
  }
}
EOF

  # Set proper permissions
  chown postgres:postgres "$HARDWARE_SPECS_FILE" 2>/dev/null || true
  chmod 644 "$HARDWARE_SPECS_FILE" 2>/dev/null || true
  
  log_info "Hardware specifications collected and saved to $HARDWARE_SPECS_FILE"
}

# Compare current hardware with previous specifications
compare_hardware_specs() {
  log_info "Comparing hardware specifications with previous state..."
  
  # Check if previous specs file exists
  if [ ! -f "$PREVIOUS_SPECS_FILE" ]; then
    log_info "No previous hardware specifications found. This might be the first run."
    return 0
  fi
  
  # Extract values from current specs
  local current_cpu_cores=$(jq -r '.cpu.cores' "$HARDWARE_SPECS_FILE")
  local current_memory_mb=$(jq -r '.memory.total_mb' "$HARDWARE_SPECS_FILE")
  local current_disk_gb=$(jq -r '.disk.size_gb' "$HARDWARE_SPECS_FILE")
  
  # Extract values from previous specs
  local previous_cpu_cores=$(jq -r '.cpu.cores' "$PREVIOUS_SPECS_FILE")
  local previous_memory_mb=$(jq -r '.memory.total_mb' "$PREVIOUS_SPECS_FILE")
  local previous_disk_gb=$(jq -r '.disk.size_gb' "$PREVIOUS_SPECS_FILE")
  
  # Calculate percentage changes
  local cpu_change=0
  local memory_change=0
  local disk_change=0
  
  if [ "$previous_cpu_cores" -gt 0 ]; then
    cpu_change=$(( (current_cpu_cores - previous_cpu_cores) * 100 / previous_cpu_cores ))
  fi
  
  if [ "$previous_memory_mb" -gt 0 ]; then
    memory_change=$(( (current_memory_mb - previous_memory_mb) * 100 / previous_memory_mb ))
  fi
  
  if [ "$previous_disk_gb" -gt 0 ]; then
    disk_change=$(( (current_disk_gb - previous_disk_gb) * 100 / previous_disk_gb ))
  fi
  
  # Create a changes summary file
  local changes_file="/var/lib/postgresql/hardware_changes.txt"
  {
    echo "Hardware Changes Report - $(date)"
    echo "================================="
    echo "CPU Cores: $previous_cpu_cores → $current_cpu_cores (${cpu_change}% change)"
    echo "Memory: $previous_memory_mb MB → $current_memory_mb MB (${memory_change}% change)"
    echo "Disk Size: $previous_disk_gb GB → $current_disk_gb GB (${disk_change}% change)"
    echo ""
  } > "$changes_file"
  
  # Set proper permissions for changes file
  chown postgres:postgres "$changes_file" 2>/dev/null || true
  chmod 644 "$changes_file" 2>/dev/null || true
  
  # Determine if significant changes occurred (±10% threshold)
  if [ "${cpu_change#-}" -ge 10 ] || [ "${memory_change#-}" -ge 10 ] || [ "${disk_change#-}" -ge 10 ]; then
    log_info "Significant hardware changes detected:"
    log_info "CPU Cores: $previous_cpu_cores → $current_cpu_cores (${cpu_change}% change)"
    log_info "Memory: $previous_memory_mb MB → $current_memory_mb MB (${memory_change}% change)"
    log_info "Disk Size: $previous_disk_gb GB → $current_disk_gb GB (${disk_change}% change)"
    return 0
  else
    log_info "No significant hardware changes detected."
    return 1
  fi
}

# Trigger reconfiguration based on hardware changes
trigger_reconfiguration() {
  log_info "Triggering reconfiguration due to hardware changes..."
  
  # Create a backup of the current configuration
  backup_current_config
  
  # Run the dynamic optimization script
  log_info "Running dynamic optimization..."
  if [ -f "$HW_DETECTOR_SCRIPT_DIR/dynamic_optimization.sh" ]; then
    bash "$HW_DETECTOR_SCRIPT_DIR/dynamic_optimization.sh"
    local result=$?
    if [ $result -eq 0 ]; then
      log_info "Dynamic optimization completed successfully."
    else
      log_error "Dynamic optimization failed with exit code $result."
      log_info "Restoring previous configuration..."
      restore_previous_config
    fi
  else
    log_error "Dynamic optimization script not found at $HW_DETECTOR_SCRIPT_DIR/dynamic_optimization.sh"
    return 1
  fi
}

# Backup current PostgreSQL and pgbouncer configuration
backup_current_config() {
  log_info "Backing up current configuration..."
  
  local backup_dir="/var/lib/postgresql/config_backups/$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup_dir"
  
  # Backup PostgreSQL configuration
  local pg_conf_dir="/etc/postgresql/$(pg_lsclusters | grep -v Cluster | awk '{print $1}')/main"
  if [ -d "$pg_conf_dir" ]; then
    log_info "Backing up PostgreSQL configuration..."
    cp -r "$pg_conf_dir/postgresql.conf" "$pg_conf_dir/pg_hba.conf" "$pg_conf_dir/conf.d" "$backup_dir/" 2>/dev/null || true
  fi
  
  # Backup pgbouncer configuration
  if [ -f "/etc/pgbouncer/pgbouncer.ini" ]; then
    log_info "Backing up pgbouncer configuration..."
    cp "/etc/pgbouncer/pgbouncer.ini" "$backup_dir/" 2>/dev/null || true
  fi
  
  # Create backup info file
  cat > "$backup_dir/backup_info.txt" << EOF
Backup created on $(date)
Hardware specs at backup time:
$(cat "$HARDWARE_SPECS_FILE")
EOF

  # Set proper permissions
  chown -R postgres:postgres "$backup_dir" 2>/dev/null || true
  
  log_info "Configuration backup completed: $backup_dir"
}

# Restore previous configuration in case of failure
restore_previous_config() {
  log_info "Restoring previous configuration..."
  
  # Find the latest backup
  local latest_backup
  latest_backup=$(find /var/lib/postgresql/config_backups -mindepth 1 -maxdepth 1 -type d | sort -r | head -n 1)
  
  if [ -z "$latest_backup" ]; then
    log_error "No backup found to restore from."
    return 1
  fi
  
  log_info "Restoring from backup: $latest_backup"
  
  # Restore PostgreSQL configuration
  local pg_conf_dir="/etc/postgresql/$(pg_lsclusters | grep -v Cluster | awk '{print $1}')/main"
  if [ -f "$latest_backup/postgresql.conf" ] && [ -d "$pg_conf_dir" ]; then
    log_info "Restoring PostgreSQL configuration..."
    cp "$latest_backup/postgresql.conf" "$pg_conf_dir/" 2>/dev/null || true
    cp "$latest_backup/pg_hba.conf" "$pg_conf_dir/" 2>/dev/null || true
    
    # Restore conf.d if it exists
    if [ -d "$latest_backup/conf.d" ]; then
      cp -r "$latest_backup/conf.d"/* "$pg_conf_dir/conf.d/" 2>/dev/null || true
    fi
    
    # Reload PostgreSQL configuration
    systemctl reload postgresql > /dev/null 2>&1
  fi
  
  # Restore pgbouncer configuration
  if [ -f "$latest_backup/pgbouncer.ini" ]; then
    log_info "Restoring pgbouncer configuration..."
    cp "$latest_backup/pgbouncer.ini" "/etc/pgbouncer/" 2>/dev/null || true
    
    # Restart pgbouncer to apply changes
    systemctl restart pgbouncer > /dev/null 2>&1
  fi
  
  log_info "Previous configuration restored successfully."
}

# Check if executed during production hours
is_production_hours() {
  local current_hour
  current_hour=$(date +%H)
  
  # Default production hours: 8 AM - 8 PM (08-20)
  local prod_start=${PRODUCTION_HOURS_START:-8}
  local prod_end=${PRODUCTION_HOURS_END:-20}
  
  if [ "$current_hour" -ge "$prod_start" ] && [ "$current_hour" -lt "$prod_end" ]; then
    return 0  # It is production hours
  else
    return 1  # It is not production hours
  fi
}

# Perform phased optimization during production hours
perform_phased_optimization() {
  log_info "Performing phased optimization during production hours..."
  
  # Create a backup first
  backup_current_config
  
  # Step 1: Apply minimal changes that don't require restart
  log_info "Phase 1: Applying minimal non-restart changes..."
  
  # Run dynamic_optimization with minimal flag
  bash "$HW_DETECTOR_SCRIPT_DIR/dynamic_optimization.sh" --minimal
  
  # Step 2: Schedule major changes for non-production hours
  log_info "Phase 2: Scheduling full optimization for non-production hours..."
  
  # Create a scheduled task using at command if available
  if command -v at >/dev/null 2>&1; then
    # Schedule for 1 AM
    echo "bash $HW_DETECTOR_SCRIPT_DIR/dynamic_optimization.sh --full" | at 1:00 > /dev/null 2>&1
    log_info "Full optimization scheduled for 1:00 AM."
  else
    # Create a systemd timer as alternative
    log_info "The 'at' command is not available. Setting up systemd timer instead."
    
    # Create systemd service file
    cat > "/etc/systemd/system/pg-full-optimization.service" << EOF
[Unit]
Description=PostgreSQL Full Optimization Service
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/bin/bash $HW_DETECTOR_SCRIPT_DIR/dynamic_optimization.sh --full
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer file - run at 1 AM
    cat > "/etc/systemd/system/pg-full-optimization.timer" << EOF
[Unit]
Description=Run PostgreSQL Full Optimization at 1 AM

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

    # Reload systemd, enable and start the timer
    systemctl daemon-reload
    systemctl enable pg-full-optimization.timer > /dev/null 2>&1
    systemctl start pg-full-optimization.timer > /dev/null 2>&1
    
    log_info "Systemd timer set up for full optimization at 1:00 AM."
  fi
}

# Install systemd service for hardware monitoring
install_service() {
  log_info "Installing hardware change detector service..."
  
  # Create systemd service file
  cat > "/etc/systemd/system/hardware-change-detector.service" << EOF
[Unit]
Description=Hardware Change Detector for PostgreSQL
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/bin/bash $HW_DETECTOR_SCRIPT_DIR/hardware_change_detector.sh --check
User=root

[Install]
WantedBy=multi-user.target
EOF

  # Create systemd timer file - run daily
  cat > "/etc/systemd/system/hardware-change-detector.timer" << EOF
[Unit]
Description=Run Hardware Change Detector Daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Reload systemd, enable and start the timer
  systemctl daemon-reload
  systemctl enable hardware-change-detector.timer > /dev/null 2>&1
  systemctl start hardware-change-detector.timer > /dev/null 2>&1
  
  log_info "Hardware change detector service installed successfully."
}

# Main function
main() {
  log_info "Starting hardware change detector..."
  
  # Check if jq is installed (needed for JSON processing)
  if ! command -v jq >/dev/null 2>&1; then
    log_info "Installing jq for JSON processing..."
    apt_install_with_retry "jq" 5 30
  fi
  
  # Create directory for specs files
  create_specs_directory
  
  # Check for --install flag
  if [[ "$1" == "--install" ]]; then
    install_service
    exit 0
  fi
  
  # Check for --check flag
  if [[ "$1" == "--check" ]]; then
    # If previous specs exist, back them up before collecting new ones
    if [ -f "$HARDWARE_SPECS_FILE" ]; then
      cp "$HARDWARE_SPECS_FILE" "$PREVIOUS_SPECS_FILE"
    fi
    
    # Collect current hardware specifications
    collect_hardware_specs
    
    # Compare with previous specifications
    if compare_hardware_specs; then
      log_info "Hardware changes detected, initiating reconfiguration..."
      
      # Check if we're in production hours
      if is_production_hours; then
        log_info "Currently in production hours, using phased approach..."
        perform_phased_optimization
      else
        log_info "Outside production hours, performing full optimization..."
        trigger_reconfiguration
      fi
    else
      log_info "No significant hardware changes detected, no action needed."
    fi
    
    exit 0
  fi
  
  # Default behavior - just collect hardware specs
  collect_hardware_specs
  
  log_info "Hardware change detector completed successfully."
}

# If script is run directly, execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 