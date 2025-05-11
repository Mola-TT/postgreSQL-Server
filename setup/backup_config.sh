#!/bin/bash
# backup_config.sh - PostgreSQL backup configuration and implementation
# Part of Milestone 7

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory - using unique variable name to avoid conflicts
BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_LIB_DIR="$BACKUP_SCRIPT_DIR/../lib"
BACKUP_CONF_DIR="$BACKUP_SCRIPT_DIR/../conf"

# Source the logger functions
source "$BACKUP_LIB_DIR/logger.sh"

# Source utilities
source "$BACKUP_LIB_DIR/utilities.sh"

# Load environment variables
log_info "Loading environment variables"
# First load default environment variables
if [ -f "$BACKUP_CONF_DIR/default.env" ]; then
  source "$BACKUP_CONF_DIR/default.env"
else
  log_error "Default environment file not found at $BACKUP_CONF_DIR/default.env"
  exit 1
fi

# Then override with user environment variables if available
if [ -f "$BACKUP_CONF_DIR/user.env" ]; then
  source "$BACKUP_CONF_DIR/user.env"
  log_info "Loaded user environment from $BACKUP_CONF_DIR/user.env"
fi

# Function to install required packages
install_backup_tools() {
  log_info "Installing required backup tools..."
  
  # Install required packages
  local packages="postgresql-client pgbackrest cron gzip openssl"
  
  if ! install_package_with_retry "$packages" 5 30; then
    log_error "Failed to install required backup packages"
    return 1
  fi
  
  log_info "Backup tools installed successfully"
  return 0
}

# Function to create backup directory structure
create_backup_directories() {
  log_info "Creating backup directory structure..."
  
  # Create main backup directory
  if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    log_info "Created main backup directory: $BACKUP_DIR"
  fi
  
  # Create subdirectories for different backup types
  mkdir -p "$BACKUP_DIR/full" "$BACKUP_DIR/incremental" "$BACKUP_DIR/archive"
  mkdir -p "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "$BACKUP_DIR/monthly"
  mkdir -p "$BACKUP_DIR/logs" "$BACKUP_DIR/conf"
  
  # Set proper permissions
  chown -R postgres:postgres "$BACKUP_DIR"
  chmod -R 750 "$BACKUP_DIR"
  
  log_info "Backup directory structure created successfully"
  return 0
}

# Function to configure pgBackRest
configure_pgbackrest() {
  log_info "Configuring pgBackRest..."
  
  # Create pgBackRest configuration directory if it doesn't exist
  local pgbackrest_conf_dir="/etc/pgbackrest"
  local pgbackrest_conf="$pgbackrest_conf_dir/pgbackrest.conf"
  
  if [ ! -d "$pgbackrest_conf_dir" ]; then
    mkdir -p "$pgbackrest_conf_dir"
  fi
  
  # Determine PostgreSQL data directory
  local pg_data_dir
  pg_data_dir=$(su - postgres -c "psql -t -c \"SHOW data_directory;\"" 2>/dev/null | tr -d ' \n\r\t')
  
  if [ -z "$pg_data_dir" ]; then
    log_warn "Could not determine PostgreSQL data directory, using default path"
    pg_data_dir="/var/lib/postgresql/*/main"
  fi
  
  # Create pgBackRest configuration file
  cat > "$pgbackrest_conf" << EOF
[global]
repo1-path=$BACKUP_DIR
repo1-retention-full=$BACKUP_RETENTION_MONTHS
process-max=$BACKUP_MAX_PARALLEL_JOBS
log-level-console=info
log-level-file=detail
start-fast=y
delta=y

[main]
pg1-path=$pg_data_dir
EOF

  # Set proper permissions
  chmod 640 "$pgbackrest_conf"
  chown postgres:postgres "$pgbackrest_conf"
  
  log_info "pgBackRest configured successfully"
  return 0
}

# Function to create backup scripts
create_backup_scripts() {
  log_info "Creating backup scripts..."
  
  # Full backup script
  local full_backup_script="$BACKUP_DIR/scripts/full_backup.sh"
  mkdir -p "$(dirname "$full_backup_script")"
  
  cat > "$full_backup_script" << 'EOF'
#!/bin/bash
# Full backup script

# Load environment variables
source /etc/environment

# Set date variables
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/logs/full_backup_$TIMESTAMP.log"

# Start backup
echo "Starting full backup at $(date)" > "$LOG_FILE"

# Run pgBackRest full backup
if pgbackrest --stanza=main backup --type=full >> "$LOG_FILE" 2>&1; then
  echo "Full backup completed successfully at $(date)" >> "$LOG_FILE"
  
  # Send success email if enabled
  if [ "$BACKUP_EMAIL_NOTIFICATIONS" = "true" ]; then
    echo -e "Subject: $BACKUP_SUCCESS_EMAIL_SUBJECT\n\nFull backup completed successfully at $(date)\n\nBackup details:\n$(pgbackrest info)" | sendmail -f "$BACKUP_EMAIL_SENDER" "$BACKUP_EMAIL_RECIPIENT"
  fi
  
  exit 0
else
  echo "Full backup failed at $(date)" >> "$LOG_FILE"
  
  # Send failure email if enabled
  if [ "$BACKUP_EMAIL_NOTIFICATIONS" = "true" ]; then
    echo -e "Subject: $BACKUP_FAILURE_EMAIL_SUBJECT\n\nFull backup failed at $(date)\n\nSee log file: $LOG_FILE" | sendmail -f "$BACKUP_EMAIL_SENDER" "$BACKUP_EMAIL_RECIPIENT"
  fi
  
  exit 1
fi
EOF

  # Incremental backup script
  local incremental_backup_script="$BACKUP_DIR/scripts/incremental_backup.sh"
  
  cat > "$incremental_backup_script" << 'EOF'
#!/bin/bash
# Incremental backup script

# Load environment variables
source /etc/environment

# Set date variables
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/logs/incremental_backup_$TIMESTAMP.log"

# Start backup
echo "Starting incremental backup at $(date)" > "$LOG_FILE"

# Run pgBackRest incremental backup
if pgbackrest --stanza=main backup --type=incr >> "$LOG_FILE" 2>&1; then
  echo "Incremental backup completed successfully at $(date)" >> "$LOG_FILE"
  
  # Send success email if enabled
  if [ "$BACKUP_EMAIL_NOTIFICATIONS" = "true" ]; then
    echo -e "Subject: $BACKUP_SUCCESS_EMAIL_SUBJECT\n\nIncremental backup completed successfully at $(date)\n\nBackup details:\n$(pgbackrest info)" | sendmail -f "$BACKUP_EMAIL_SENDER" "$BACKUP_EMAIL_RECIPIENT"
  fi
  
  exit 0
else
  echo "Incremental backup failed at $(date)" >> "$LOG_FILE"
  
  # Send failure email if enabled
  if [ "$BACKUP_EMAIL_NOTIFICATIONS" = "true" ]; then
    echo -e "Subject: $BACKUP_FAILURE_EMAIL_SUBJECT\n\nIncremental backup failed at $(date)\n\nSee log file: $LOG_FILE" | sendmail -f "$BACKUP_EMAIL_SENDER" "$BACKUP_EMAIL_RECIPIENT"
  fi
  
  exit 1
fi
EOF

  # Backup verification script
  local verify_backup_script="$BACKUP_DIR/scripts/verify_backup.sh"
  
  cat > "$verify_backup_script" << 'EOF'
#!/bin/bash
# Backup verification script

# Load environment variables
source /etc/environment

# Set date variables
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/logs/verify_backup_$TIMESTAMP.log"

# Start verification
echo "Starting backup verification at $(date)" > "$LOG_FILE"

# Run pgBackRest check
if pgbackrest --stanza=main check >> "$LOG_FILE" 2>&1; then
  echo "Backup verification completed successfully at $(date)" >> "$LOG_FILE"
  
  # Send success email if enabled
  if [ "$BACKUP_EMAIL_NOTIFICATIONS" = "true" ]; then
    echo -e "Subject: Backup Verification Successful\n\nBackup verification completed successfully at $(date)" | sendmail -f "$BACKUP_EMAIL_SENDER" "$BACKUP_EMAIL_RECIPIENT"
  fi
  
  exit 0
else
  echo "Backup verification failed at $(date)" >> "$LOG_FILE"
  
  # Send failure email if enabled
  if [ "$BACKUP_EMAIL_NOTIFICATIONS" = "true" ]; then
    echo -e "Subject: Backup Verification Failed\n\nBackup verification failed at $(date)\n\nSee log file: $LOG_FILE" | sendmail -f "$BACKUP_EMAIL_SENDER" "$BACKUP_EMAIL_RECIPIENT"
  fi
  
  exit 1
fi
EOF

  # Set proper permissions for all scripts
  chmod 750 "$full_backup_script" "$incremental_backup_script" "$verify_backup_script"
  chown postgres:postgres "$full_backup_script" "$incremental_backup_script" "$verify_backup_script"
  
  log_info "Backup scripts created successfully"
  return 0
}

# Function to setup backup cron jobs
setup_backup_cron() {
  log_info "Setting up backup cron jobs..."
  
  # Create cron job file
  local cron_file="/etc/cron.d/postgresql-backups"
  
  cat > "$cron_file" << EOF
# PostgreSQL backup cron jobs
# Full backup: $BACKUP_SCHEDULE_FULL
# Incremental backup: $BACKUP_SCHEDULE_INCREMENTAL
# Verification: $BACKUP_VERIFICATION_SCHEDULE

$BACKUP_SCHEDULE_FULL postgres $BACKUP_DIR/scripts/full_backup.sh
$BACKUP_SCHEDULE_INCREMENTAL postgres $BACKUP_DIR/scripts/incremental_backup.sh
EOF

  # Add verification job if enabled
  if [ "$BACKUP_VERIFICATION" = "true" ]; then
    echo "$BACKUP_VERIFICATION_SCHEDULE postgres $BACKUP_DIR/scripts/verify_backup.sh" >> "$cron_file"
  fi
  
  # Set proper permissions
  chmod 644 "$cron_file"
  
  # Restart cron service to apply changes
  systemctl restart cron > /dev/null 2>&1
  
  log_info "Backup cron jobs set up successfully"
  return 0
}

# Function to initialize pgBackRest
initialize_pgbackrest() {
  log_info "Initializing pgBackRest..."
  
  # Create pgBackRest stanza
  su - postgres -c "pgbackrest --stanza=main stanza-create" > /dev/null 2>&1
  
  log_info "pgBackRest initialized successfully"
  return 0
}

# Function to create backup management scripts
create_management_scripts() {
  log_info "Creating backup management scripts..."
  
  # List backups script
  local list_backups_script="$BACKUP_DIR/scripts/list_backups.sh"
  
  cat > "$list_backups_script" << 'EOF'
#!/bin/bash
# Script to list available backups

# Run pgBackRest info command
pgbackrest info

# Exit with success
exit 0
EOF

  # Restore backup script
  local restore_backup_script="$BACKUP_DIR/scripts/restore_backup.sh"
  
  cat > "$restore_backup_script" << 'EOF'
#!/bin/bash
# Script to restore from a specific backup

# Check if backup ID is provided
if [ -z "$1" ]; then
  echo "Error: Backup ID not provided"
  echo "Usage: $0 <backup-id> [target-directory]"
  echo "Example: $0 latest /var/lib/postgresql/restore"
  echo "Example: $0 20230101-123456 /var/lib/postgresql/restore"
  exit 1
fi

# Set backup ID
BACKUP_ID="$1"

# Set target directory
TARGET_DIR="${2:-/var/lib/postgresql/restore}"

# Create target directory if it doesn't exist
mkdir -p "$TARGET_DIR"
chown postgres:postgres "$TARGET_DIR"

# Set date variables
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/logs/restore_$TIMESTAMP.log"

# Start restore
echo "Starting restore of backup $BACKUP_ID at $(date)" > "$LOG_FILE"

# Run pgBackRest restore command
if [ "$BACKUP_ID" = "latest" ]; then
  # Restore latest backup
  su - postgres -c "pgbackrest --stanza=main restore --target=$TARGET_DIR" >> "$LOG_FILE" 2>&1
else
  # Restore specific backup
  su - postgres -c "pgbackrest --stanza=main restore --target=$TARGET_DIR --set=$BACKUP_ID" >> "$LOG_FILE" 2>&1
fi

# Check if restore was successful
if [ $? -eq 0 ]; then
  echo "Restore completed successfully at $(date)" >> "$LOG_FILE"
  echo "Backup $BACKUP_ID restored to $TARGET_DIR"
  exit 0
else
  echo "Restore failed at $(date)" >> "$LOG_FILE"
  echo "Failed to restore backup $BACKUP_ID. See log file: $LOG_FILE"
  exit 1
fi
EOF

  # Verify backup integrity script
  local verify_integrity_script="$BACKUP_DIR/scripts/verify_integrity.sh"
  
  cat > "$verify_integrity_script" << 'EOF'
#!/bin/bash
# Script to verify backup integrity

# Check if backup ID is provided
if [ -z "$1" ]; then
  echo "Error: Backup ID not provided"
  echo "Usage: $0 <backup-id>"
  echo "Example: $0 latest"
  echo "Example: $0 20230101-123456"
  exit 1
fi

# Set backup ID
BACKUP_ID="$1"

# Set date variables
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/logs/verify_integrity_$TIMESTAMP.log"

# Start verification
echo "Starting integrity verification of backup $BACKUP_ID at $(date)" > "$LOG_FILE"

# Run pgBackRest check command
if [ "$BACKUP_ID" = "latest" ]; then
  # Verify latest backup
  pgbackrest --stanza=main check >> "$LOG_FILE" 2>&1
else
  # Verify specific backup
  pgbackrest --stanza=main check --set=$BACKUP_ID >> "$LOG_FILE" 2>&1
fi

# Check if verification was successful
if [ $? -eq 0 ]; then
  echo "Integrity verification completed successfully at $(date)" >> "$LOG_FILE"
  echo "Backup $BACKUP_ID integrity verified successfully"
  exit 0
else
  echo "Integrity verification failed at $(date)" >> "$LOG_FILE"
  echo "Failed to verify backup $BACKUP_ID integrity. See log file: $LOG_FILE"
  exit 1
fi
EOF

  # Manage retention policy script
  local manage_retention_script="$BACKUP_DIR/scripts/manage_retention.sh"
  
  cat > "$manage_retention_script" << 'EOF'
#!/bin/bash
# Script to manage backup retention policies

# Set date variables
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/logs/retention_$TIMESTAMP.log"

# Start retention management
echo "Starting backup retention management at $(date)" > "$LOG_FILE"

# Run pgBackRest expire command
pgbackrest --stanza=main expire >> "$LOG_FILE" 2>&1

# Check if retention management was successful
if [ $? -eq 0 ]; then
  echo "Retention management completed successfully at $(date)" >> "$LOG_FILE"
  echo "Backup retention policies applied successfully"
  exit 0
else
  echo "Retention management failed at $(date)" >> "$LOG_FILE"
  echo "Failed to apply backup retention policies. See log file: $LOG_FILE"
  exit 1
fi
EOF

  # Set proper permissions for all scripts
  chmod 750 "$list_backups_script" "$restore_backup_script" "$verify_integrity_script" "$manage_retention_script"
  chown postgres:postgres "$list_backups_script" "$restore_backup_script" "$verify_integrity_script" "$manage_retention_script"
  
  # Create symbolic links in /usr/local/bin for easier access
  ln -sf "$list_backups_script" /usr/local/bin/pg_list_backups
  ln -sf "$restore_backup_script" /usr/local/bin/pg_restore_backup
  ln -sf "$verify_integrity_script" /usr/local/bin/pg_verify_backup
  ln -sf "$manage_retention_script" /usr/local/bin/pg_manage_retention
  
  log_info "Backup management scripts created successfully"
  return 0
}

# Function to configure Netdata monitoring for backups
configure_backup_monitoring() {
  log_info "Configuring backup monitoring..."
  
  # Check if Netdata is installed
  if ! command -v netdata >/dev/null 2>&1; then
    log_warn "Netdata not found, skipping backup monitoring configuration"
    return 0
  fi
  
  # Create backup status check script
  local backup_status_script="/usr/lib/netdata/plugins.d/backup_status.sh"
  
  cat > "$backup_status_script" << 'EOF'
#!/bin/bash
# Netdata plugin for monitoring PostgreSQL backups

# Load environment variables
source /etc/environment

# Check if pgBackRest is installed
if ! command -v pgbackrest >/dev/null 2>&1; then
  exit 1
fi

# Configuration
BACKUP_LOG_DIR="$BACKUP_DIR/logs"
INTERVAL=60  # Update interval in seconds

# Function to check backup status
check_backup_status() {
  # Get latest full backup timestamp
  LATEST_FULL=$(pgbackrest info --output=json | jq -r '.[0].backup[] | select(.type=="full") | .timestamp' | sort -r | head -n 1)
  
  # Get latest incremental backup timestamp
  LATEST_INCR=$(pgbackrest info --output=json | jq -r '.[0].backup[] | select(.type=="incr") | .timestamp' | sort -r | head -n 1)
  
  # Calculate time since last full backup (in seconds)
  if [ -n "$LATEST_FULL" ]; then
    LAST_FULL_TIME=$(date -d "$LATEST_FULL" +%s)
    CURRENT_TIME=$(date +%s)
    FULL_BACKUP_AGE=$((CURRENT_TIME - LAST_FULL_TIME))
  else
    FULL_BACKUP_AGE=-1
  fi
  
  # Calculate time since last incremental backup (in seconds)
  if [ -n "$LATEST_INCR" ]; then
    LAST_INCR_TIME=$(date -d "$LATEST_INCR" +%s)
    CURRENT_TIME=$(date +%s)
    INCR_BACKUP_AGE=$((CURRENT_TIME - LAST_INCR_TIME))
  else
    INCR_BACKUP_AGE=-1
  fi
  
  # Get backup size
  BACKUP_SIZE=$(du -sb "$BACKUP_DIR" 2>/dev/null | cut -f1)
  
  # Check for recent backup failures
  RECENT_FAILURES=$(grep -l "backup failed" "$BACKUP_LOG_DIR"/*_backup_*.log 2>/dev/null | wc -l)
  
  # Output data in Netdata format
  echo "BEGIN pg_backup_age"
  echo "SET full_backup_age = $FULL_BACKUP_AGE"
  echo "SET incremental_backup_age = $INCR_BACKUP_AGE"
  echo "END"
  
  echo "BEGIN pg_backup_size"
  echo "SET backup_size = $BACKUP_SIZE"
  echo "END"
  
  echo "BEGIN pg_backup_failures"
  echo "SET recent_failures = $RECENT_FAILURES"
  echo "END"
}

# Netdata plugin main loop
while true; do
  check_backup_status
  sleep $INTERVAL
done
EOF

  # Set proper permissions
  chmod 755 "$backup_status_script"
  
  # Create Netdata configuration for backup monitoring
  local netdata_conf="/etc/netdata/health.d/pg_backup_checks.conf"
  mkdir -p "$(dirname "$netdata_conf")"
  
  cat > "$netdata_conf" << EOF
# PostgreSQL Backup Health Checks

# Alert if no full backup in the last 8 days
template: pg_full_backup_age
      on: pg_backup_age.full_backup_age
    calc: \$full_backup_age / 86400
   units: days
   every: 1m
    warn: \$this > 7
    crit: \$this > 8
   delay: up 30m down 5m
    info: Time since last full backup
      to: $BACKUP_EMAIL_RECIPIENT

# Alert if no incremental backup in the last 2 days
template: pg_incremental_backup_age
      on: pg_backup_age.incremental_backup_age
    calc: \$incremental_backup_age / 86400
   units: days
   every: 1m
    warn: \$this > 1
    crit: \$this > 2
   delay: up 30m down 5m
    info: Time since last incremental backup
      to: $BACKUP_EMAIL_RECIPIENT

# Alert on backup failures
template: pg_backup_failures
      on: pg_backup_failures.recent_failures
    calc: \$recent_failures
   every: 1m
    warn: \$this > 0
    crit: \$this > 2
   delay: down 15m multiplier 1.5 max 1h
    info: Number of recent backup failures
      to: $BACKUP_EMAIL_RECIPIENT
EOF

  # Restart Netdata to apply changes
  systemctl restart netdata > /dev/null 2>&1
  
  log_info "Backup monitoring configured successfully"
  return 0
}

# Main function to set up PostgreSQL backups
setup_postgresql_backups() {
  log_info "Setting up PostgreSQL backups..."
  
  # Check if backups are enabled
  if [ "${ENABLE_BACKUPS:-true}" != "true" ]; then
    log_info "PostgreSQL backups are disabled in configuration, skipping setup"
    return 0
  fi
  
  # Install required packages
  install_backup_tools
  
  # Create backup directory structure
  create_backup_directories
  
  # Configure pgBackRest
  configure_pgbackrest
  
  # Initialize pgBackRest
  initialize_pgbackrest
  
  # Create backup scripts
  create_backup_scripts
  
  # Create backup management scripts
  create_management_scripts
  
  # Set up backup cron jobs
  setup_backup_cron
  
  # Configure backup monitoring
  configure_backup_monitoring
  
  log_info "PostgreSQL backup setup completed successfully"
  return 0
}

# If script is run directly, execute setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_postgresql_backups
fi 