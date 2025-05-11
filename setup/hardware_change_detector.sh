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

# Email notification settings (default values, will be overridden by environment variables)
HARDWARE_CHANGE_EMAIL_ENABLED=${HARDWARE_CHANGE_EMAIL_ENABLED:-true}
HARDWARE_CHANGE_EMAIL_RECIPIENT=${HARDWARE_CHANGE_EMAIL_RECIPIENT:-${EMAIL_RECIPIENT:-"root"}}
HARDWARE_CHANGE_EMAIL_SENDER=${HARDWARE_CHANGE_EMAIL_SENDER:-${EMAIL_SENDER:-"postgres@$(hostname -f)"}}
HARDWARE_CHANGE_EMAIL_SUBJECT=${HARDWARE_CHANGE_EMAIL_SUBJECT:-"[ALERT] Hardware Change Detected on PostgreSQL Server"}
OPTIMIZATION_EMAIL_SUBJECT=${OPTIMIZATION_EMAIL_SUBJECT:-"PostgreSQL Server Optimization Completed"}
TEST_EMAIL_SUBJECT=${TEST_EMAIL_SUBJECT:-"[TEST] PostgreSQL Server Email Test"}
# Support both new variable names and legacy Netdata variable names for backward compatibility
SMTP_SERVER=${SMTP_SERVER:-${NETDATA_SMTP_SERVER:-"localhost"}}
SMTP_PORT=${SMTP_PORT:-${NETDATA_SMTP_PORT:-25}}
SMTP_TLS=${SMTP_TLS:-${NETDATA_SMTP_TLS:-"NO"}}
SMTP_USERNAME=${SMTP_USERNAME:-${NETDATA_SMTP_USERNAME:-""}}
SMTP_PASSWORD=${SMTP_PASSWORD:-${NETDATA_SMTP_PASSWORD:-""}}

# Function to send email notifications
send_email_notification() {
  local subject="$1"
  local message="$2"
  local recipient="${3:-$HARDWARE_CHANGE_EMAIL_RECIPIENT}"
  local sender="${4:-$HARDWARE_CHANGE_EMAIL_SENDER}"
  
  # Check if email notifications are enabled
  if [ "$HARDWARE_CHANGE_EMAIL_ENABLED" != "true" ]; then
    log_info "Email notifications are disabled. Skipping email."
    return 0
  fi
  
  log_info "Sending email notification to $recipient..."
  
  # Create a temporary email file
  local email_file=$(mktemp)
  
  # Create email content
  cat > "$email_file" << EOF
From: $sender
To: $recipient
Subject: $subject
Content-Type: text/plain; charset=UTF-8

$message

--
This is an automated message from the PostgreSQL Server Hardware Change Detector
Server: $(hostname -f)
Date: $(date)
EOF
  
  # Use different methods to send email based on what's available
  if command -v msmtp >/dev/null 2>&1; then
    # Use msmtp if available (preferred method)
    log_info "Using msmtp to send email..."
    # Create a temporary log file for msmtp output
    local msmtp_log=$(mktemp)
    cat "$email_file" | msmtp -a default "$recipient" > "$msmtp_log" 2>&1
    local status=$?
    
    # Log debug information if verbose logging is enabled
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
      log_debug "msmtp output:"
      cat "$msmtp_log" | while read line; do
        log_debug "msmtp: $line"
      done
    fi
    
    # Clean up
    rm -f "$msmtp_log" 2>/dev/null || true
    
    if [ $status -ne 0 ]; then
      log_warn "msmtp failed to send email (exit code: $status)"
      return $status
    fi
  elif command -v mailx >/dev/null 2>&1; then
    # Use mailx if available
    if [ -n "$SMTP_USERNAME" ] && [ -n "$SMTP_PASSWORD" ]; then
      cat "$email_file" | mailx -S "smtp=$SMTP_SERVER:$SMTP_PORT" \
                                -S "smtp-use-starttls=$SMTP_TLS" \
                                -S "smtp-auth=login" \
                                -S "smtp-auth-user=$SMTP_USERNAME" \
                                -S "smtp-auth-password=$SMTP_PASSWORD" \
                                -t "$recipient" > /dev/null 2>&1
    else
      cat "$email_file" | mailx -S "smtp=$SMTP_SERVER:$SMTP_PORT" \
                                -t "$recipient" > /dev/null 2>&1
    fi
  elif command -v mail >/dev/null 2>&1; then
    # Use mail command if available
    cat "$email_file" | mail -s "$subject" "$recipient" > /dev/null 2>&1
  elif command -v sendmail >/dev/null 2>&1; then
    # Use sendmail if available
    cat "$email_file" | sendmail -t > /dev/null 2>&1
  elif command -v curl >/dev/null 2>&1 && [ -n "$SMTP_USERNAME" ] && [ -n "$SMTP_PASSWORD" ]; then
    # Use curl as a last resort if SMTP credentials are available
    curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
         --mail-from "$sender" \
         --mail-rcpt "$recipient" \
         --upload-file "$email_file" \
         --user "$SMTP_USERNAME:$SMTP_PASSWORD" \
         --ssl-reqd > /dev/null 2>&1
  else
    log_warn "No email sending methods available. Email notification could not be sent."
    rm -f "$email_file" 2>/dev/null || true
    return 1
  fi
  
  local status=$?
  if [ $status -eq 0 ]; then
    log_info "Email notification sent successfully."
  else
    log_warn "Failed to send email notification."
  fi
  
  # Clean up
  rm -f "$email_file" 2>/dev/null || true
  
  return $status
}

# Function to send hardware change notification
send_hardware_change_notification() {
  local current_cpu_cores="$1"
  local previous_cpu_cores="$2"
  local cpu_change="$3"
  local current_memory_mb="$4"
  local previous_memory_mb="$5"
  local memory_change="$6"
  local current_disk_gb="$7"
  local previous_disk_gb="$8"
  local disk_change="$9"
  
  local message="Hardware changes have been detected on the PostgreSQL server.

HARDWARE CHANGE DETAILS:
-----------------------
CPU Cores: $previous_cpu_cores → $current_cpu_cores (${cpu_change}% change)
Memory: $previous_memory_mb MB → $current_memory_mb MB (${memory_change}% change)
Disk Size: $previous_disk_gb GB → $current_disk_gb GB (${disk_change}% change)

ACTION TAKEN:
------------
The PostgreSQL server has been automatically reconfigured to optimize for the new hardware specifications.
A backup of the previous configuration has been created before making changes.

OPTIMIZATION REPORT:
------------------
A detailed optimization report is available at:
$OPTIMIZATION_REPORT_DIR/optimization_report_$(date +%Y%m%d%H%M%S).txt

Please review the changes and monitor system performance.
"

  send_email_notification "$HARDWARE_CHANGE_EMAIL_SUBJECT" "$message"
}

# Function to send optimization notification
send_optimization_notification() {
  local report_file="$1"
  
  # Check if the report file exists
  if [ ! -f "$report_file" ]; then
    log_warn "Optimization report file not found: $report_file"
    return 1
  fi
  
  # Read the report file content
  local report_content=$(cat "$report_file")
  
  local message="PostgreSQL server optimization has been completed successfully.

OPTIMIZATION REPORT:
------------------
$report_content

The server has been reconfigured to optimize performance based on the current hardware specifications.
A backup of the previous configuration has been created before making changes.

Please monitor system performance and review the changes if necessary.
"

  send_email_notification "$OPTIMIZATION_EMAIL_SUBJECT" "$message"
}

# Function to send test email notification
send_test_email_notification() {
  local message="This is a test email from the PostgreSQL Server.

This email confirms that the email notification system is working correctly.

Server Information:
-----------------
Hostname: $(hostname -f)
Date: $(date)
IP Address: $(hostname -I | awk '{print $1}')

If you received this email, it means the email configuration is correct.
"

  send_email_notification "$TEST_EMAIL_SUBJECT" "$message"
}

# Create directory if it doesn't exist
create_specs_directory() {
  if [ ! -d "$(dirname "$HARDWARE_SPECS_FILE")" ]; then
    log_info "Creating directory for hardware specs..." >&2
    mkdir -p "$(dirname "$HARDWARE_SPECS_FILE")" 2>/dev/null || true
    chown postgres:postgres "$(dirname "$HARDWARE_SPECS_FILE")" 2>/dev/null || true
  fi
}

# Collect current hardware specifications
collect_hardware_specs() {
  log_info "Collecting current hardware specifications..." >&2
  
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
  
  # Try multiple methods to get PostgreSQL data directory
  # Method 1: Direct psql query (most accurate)
  if command -v psql >/dev/null 2>&1; then
    data_directory=$(su - postgres -c "psql -t -c \"SHOW data_directory;\"" 2>/dev/null | grep -v '^$' | tr -d ' ' || echo "")
  fi
  
  # Method 2: Check common locations if Method 1 failed
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    # Try common PostgreSQL data directory locations (expanded list with more versions)
    for possible_dir in "/var/lib/postgresql/16/main" "/var/lib/postgresql/15/main" "/var/lib/postgresql/14/main" "/var/lib/postgresql/13/main" "/var/lib/postgresql/12/main" "/var/lib/postgresql/11/main" "/var/lib/postgresql/10/main" "/var/lib/postgresql/9.6/main" "/var/lib/pgsql/data" "/usr/local/pgsql/data"; do
      if [ -d "$possible_dir" ]; then
        data_directory="$possible_dir"
        break
      fi
    done
  fi
  
  # Method 3: Try to find the postgresql.conf file and extract its directory
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    local conf_file
    
    # Search in more potential locations
    for possible_conf in /etc/postgresql/*/main/postgresql.conf /var/lib/pgsql/*/data/postgresql.conf /usr/local/pgsql/data/postgresql.conf; do
      if [ -f "$possible_conf" ]; then
        conf_file="$possible_conf"
        break
      fi
    done
    
    if [ -n "$conf_file" ]; then
      # Try to extract data_directory from config file
      data_directory=$(grep "^[[:space:]]*data_directory" "$conf_file" 2>/dev/null | sed "s/.*[=]['\"]\(.*\)['\"].*$/\1/" || echo "")
    fi
  fi
  
  # Method 4: Try to get PGDATA from environment or postgres user's environment
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    if [ -n "$PGDATA" ] && [ -d "$PGDATA" ]; then
      data_directory="$PGDATA"
    elif command -v su >/dev/null 2>&1; then
      # Try to get PGDATA from postgres user environment
      local pg_data=$(su - postgres -c "echo \$PGDATA" 2>/dev/null || echo "")
      if [ -n "$pg_data" ] && [ -d "$pg_data" ]; then
        data_directory="$pg_data"
      fi
    fi
  fi

  # Method 5: Try to find pg_hba.conf file and use its directory
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    local hba_file
    
    # Search for pg_hba.conf in various locations
    for possible_hba in /etc/postgresql/*/main/pg_hba.conf /var/lib/postgresql/*/main/pg_hba.conf /var/lib/pgsql/*/data/pg_hba.conf /usr/local/pgsql/data/pg_hba.conf; do
      if [ -f "$possible_hba" ]; then
        hba_file="$possible_hba"
        data_directory=$(dirname "$hba_file")
        break
      fi
    done
  fi
  
  # Method 6: Use PostgreSQL directory if data directory wasn't found
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    # If no specific data directory found, use the general PostgreSQL directory
    if [ -d "/var/lib/postgresql" ]; then
      data_directory="/var/lib/postgresql"
    elif [ -d "/var/lib/pgsql" ]; then
      data_directory="/var/lib/pgsql"
    else
      # Fallback to root filesystem as last resort
      data_directory="/"
    fi
  fi
  
  # Get disk size using df with better error handling
  # Function to safely run df command with fallbacks
  get_disk_size() {
    local dir="$1"
    local disk_size=""
    
    # Try with -P flag first (POSIX format)
    if ! disk_size=$(df -P -k "$dir" 2>/dev/null | awk 'NR==2 {print $2}'); then
      # Try without -P flag
      if ! disk_size=$(df -k "$dir" 2>/dev/null | awk 'NR==2 {print $2}'); then
        # Return empty to indicate failure
        echo ""
        return 1
      fi
    fi
    
    # Validate that disk_size is a number
    if [[ ! "$disk_size" =~ ^[0-9]+$ ]]; then
      echo ""
      return 1
    fi
    
    echo "$disk_size"
    return 0
  }
  
  # Try multiple directories with fallbacks
  disk_size_kb=$(get_disk_size "$data_directory")
  
  # If first attempt failed, try parent directory
  if [ -z "$disk_size_kb" ]; then
    local parent_dir=$(dirname "$data_directory")
    disk_size_kb=$(get_disk_size "$parent_dir")
    
    # If parent directory failed, try grandparent directory
    if [ -z "$disk_size_kb" ]; then
      local grandparent_dir=$(dirname "$parent_dir")
      disk_size_kb=$(get_disk_size "$grandparent_dir")
      
      # If all attempts failed, use root directory
      if [ -z "$disk_size_kb" ]; then
        disk_size_kb=$(get_disk_size "/" || echo "0")
      fi
    fi
  fi
  
  # Calculate GB from KB with error handling
  if [ -n "$disk_size_kb" ] && [ "$disk_size_kb" -gt 0 ]; then
    disk_size_gb=$((disk_size_kb / 1024 / 1024))
  else
    # Default to 50GB if detection failed
    disk_size_gb=50
  fi
  
  # Ensure a minimum value
  if [ "$disk_size_gb" -lt 1 ]; then
    disk_size_gb=50
  fi
  
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
  
  log_info "Hardware specifications collected and saved to $HARDWARE_SPECS_FILE" >&2
}

# Compare current hardware with previous specifications
compare_hardware_specs() {
  log_info "Comparing hardware specifications with previous state..." >&2
  
  # Check if previous specs file exists
  if [ ! -f "$PREVIOUS_SPECS_FILE" ]; then
    log_info "No previous hardware specifications found. This might be the first run." >&2
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
    log_info "Significant hardware changes detected:" >&2
    log_info "CPU Cores: $previous_cpu_cores → $current_cpu_cores (${cpu_change}% change)" >&2
    log_info "Memory: $previous_memory_mb MB → $current_memory_mb MB (${memory_change}% change)" >&2
    log_info "Disk Size: $previous_disk_gb GB → $current_disk_gb GB (${disk_change}% change)" >&2
    
    # Send email notification about hardware changes
    send_hardware_change_notification "$current_cpu_cores" "$previous_cpu_cores" "$cpu_change" \
                                     "$current_memory_mb" "$previous_memory_mb" "$memory_change" \
                                     "$current_disk_gb" "$previous_disk_gb" "$disk_change"
    
    return 0
  else
    log_info "No significant hardware changes detected." >&2
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
      
      # Find the latest optimization report
      local latest_report
      latest_report=$(find "$OPTIMIZATION_REPORT_DIR" -name "optimization_report_*.txt" | sort -r | head -n 1)
      
      # Send email notification with the optimization report
      if [ -n "$latest_report" ]; then
        send_optimization_notification "$latest_report"
      else
        log_warn "No optimization report found. Email notification not sent."
      fi
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