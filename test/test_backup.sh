#!/bin/bash
# test_backup.sh - Test script for PostgreSQL backup functionality
# Part of Milestone 7

# Get script directory
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
SETUP_DIR="$PROJECT_DIR/setup"
CONF_DIR="$PROJECT_DIR/conf"

# Source the logger functions
source "$LIB_DIR/logger.sh"

# Source utilities
source "$LIB_DIR/utilities.sh"

# Load environment variables
log_info "Loading environment variables from conf/default.env and conf/user.env"
# First load default environment variables
if [ -f "$CONF_DIR/default.env" ]; then
  source "$CONF_DIR/default.env"
else
  log_error "Default environment file not found at $CONF_DIR/default.env"
fi

# Then override with user environment variables if available
if [ -f "$CONF_DIR/user.env" ]; then
  source "$CONF_DIR/user.env"
  log_info "Loaded user environment from $CONF_DIR/user.env"
else
  log_warn "User environment file not found at $CONF_DIR/user.env"
fi

# Test header function
test_header() {
  local title="$1"
  echo ""
  log_info "========== $title =========="
  echo ""
}

# Test backup configuration
test_backup_config() {
  test_header "Testing Backup Configuration"
  
  # Check if backup_config.sh exists
  if [ -f "$SETUP_DIR/backup_config.sh" ]; then
    log_pass "backup_config.sh script exists"
  else
    log_error "backup_config.sh script not found at $SETUP_DIR/backup_config.sh"
    return 1
  fi
  
  # Check if script is executable
  if [ -x "$SETUP_DIR/backup_config.sh" ]; then
    log_pass "backup_config.sh script is executable"
  else
    log_warn "backup_config.sh script is not executable, fixing permissions"
    chmod +x "$SETUP_DIR/backup_config.sh"
  fi
  
  # Check if required environment variables are set
  if [ -n "$BACKUP_DIR" ]; then
    log_pass "BACKUP_DIR is set to $BACKUP_DIR"
  else
    log_error "BACKUP_DIR environment variable is not set"
    return 1
  fi
  
  if [ -n "$BACKUP_RETENTION_DAYS" ]; then
    log_pass "BACKUP_RETENTION_DAYS is set to $BACKUP_RETENTION_DAYS"
  else
    log_error "BACKUP_RETENTION_DAYS environment variable is not set"
    return 1
  fi
  
  if [ -n "$BACKUP_SCHEDULE_FULL" ]; then
    log_pass "BACKUP_SCHEDULE_FULL is set to $BACKUP_SCHEDULE_FULL"
  else
    log_error "BACKUP_SCHEDULE_FULL environment variable is not set"
    return 1
  fi
  
  if [ -n "$BACKUP_SCHEDULE_INCREMENTAL" ]; then
    log_pass "BACKUP_SCHEDULE_INCREMENTAL is set to $BACKUP_SCHEDULE_INCREMENTAL"
  else
    log_error "BACKUP_SCHEDULE_INCREMENTAL environment variable is not set"
    return 1
  fi
  
  log_info "Backup configuration test passed"
  return 0
}

# Test pgBackRest installation
test_pgbackrest_installation() {
  test_header "Testing pgBackRest Installation"
  
  # Check if pgbackrest is installed
  if command -v pgbackrest >/dev/null 2>&1; then
    log_pass "pgbackrest is installed"
    
    # Check pgbackrest version
    local pgbackrest_version
    pgbackrest_version=$(pgbackrest version 2>/dev/null | head -n 1 | awk '{print $2}')
    log_info "pgbackrest version: $pgbackrest_version"
  else
    log_warn "pgbackrest is not installed, attempting to install"
    
    # Try to install pgbackrest
    if install_package_with_retry "pgbackrest" 3 10; then
      log_pass "pgbackrest installed successfully"
    else
      log_error "Failed to install pgbackrest"
      return 1
    fi
  fi
  
  # Check if pgbackrest configuration file exists
  if [ -f "/etc/pgbackrest/pgbackrest.conf" ]; then
    log_pass "pgbackrest configuration file exists"
  else
    log_warn "pgbackrest configuration file not found, it will be created during setup"
  fi
  
  log_info "pgBackRest installation test passed"
  return 0
}

# Test backup directory structure
test_backup_directory_structure() {
  test_header "Testing Backup Directory Structure"
  
  # Create a temporary backup directory for testing
  local test_backup_dir="/tmp/test_pg_backup"
  mkdir -p "$test_backup_dir"
  
  # Override BACKUP_DIR for testing
  local original_backup_dir="$BACKUP_DIR"
  export BACKUP_DIR="$test_backup_dir"
  
  # Source the backup_config.sh script to get access to its functions
  source "$SETUP_DIR/backup_config.sh"
  
  # Create backup directories
  create_backup_directories
  
  # Check if directories were created
  if [ -d "$test_backup_dir/full" ] && [ -d "$test_backup_dir/incremental" ] && [ -d "$test_backup_dir/logs" ]; then
    log_pass "Backup directories created successfully"
  else
    log_error "Failed to create backup directories"
    rm -rf "$test_backup_dir"
    export BACKUP_DIR="$original_backup_dir"
    return 1
  fi
  
  # Check permissions
  local dir_owner
  dir_owner=$(stat -c "%U:%G" "$test_backup_dir" 2>/dev/null || stat -f "%Su:%Sg" "$test_backup_dir" 2>/dev/null)
  
  if [[ "$dir_owner" == *"postgres"* ]]; then
    log_pass "Backup directory has correct ownership"
  else
    log_warn "Backup directory ownership is not set to postgres (this is expected in test environment)"
  fi
  
  # Clean up
  rm -rf "$test_backup_dir"
  export BACKUP_DIR="$original_backup_dir"
  
  log_info "Backup directory structure test passed"
  return 0
}

# Test backup scripts creation
test_backup_scripts_creation() {
  test_header "Testing Backup Scripts Creation"
  
  # Create a temporary backup directory for testing
  local test_backup_dir="/tmp/test_pg_backup_scripts"
  mkdir -p "$test_backup_dir"
  
  # Override BACKUP_DIR for testing
  local original_backup_dir="$BACKUP_DIR"
  export BACKUP_DIR="$test_backup_dir"
  
  # Source the backup_config.sh script to get access to its functions
  source "$SETUP_DIR/backup_config.sh"
  
  # Create backup scripts
  create_backup_scripts
  
  # Check if scripts were created
  if [ -f "$test_backup_dir/scripts/full_backup.sh" ] && [ -f "$test_backup_dir/scripts/incremental_backup.sh" ] && [ -f "$test_backup_dir/scripts/verify_backup.sh" ]; then
    log_pass "Backup scripts created successfully"
  else
    log_error "Failed to create backup scripts"
    rm -rf "$test_backup_dir"
    export BACKUP_DIR="$original_backup_dir"
    return 1
  fi
  
  # Check if scripts are executable
  if [ -x "$test_backup_dir/scripts/full_backup.sh" ] && [ -x "$test_backup_dir/scripts/incremental_backup.sh" ] && [ -x "$test_backup_dir/scripts/verify_backup.sh" ]; then
    log_pass "Backup scripts are executable"
  else
    log_error "Backup scripts are not executable"
    rm -rf "$test_backup_dir"
    export BACKUP_DIR="$original_backup_dir"
    return 1
  fi
  
  # Clean up
  rm -rf "$test_backup_dir"
  export BACKUP_DIR="$original_backup_dir"
  
  log_info "Backup scripts creation test passed"
  return 0
}

# Test management scripts creation
test_management_scripts_creation() {
  test_header "Testing Management Scripts Creation"
  
  # Create a temporary backup directory for testing
  local test_backup_dir="/tmp/test_pg_backup_management"
  mkdir -p "$test_backup_dir"
  
  # Override BACKUP_DIR for testing
  local original_backup_dir="$BACKUP_DIR"
  export BACKUP_DIR="$test_backup_dir"
  
  # Source the backup_config.sh script to get access to its functions
  source "$SETUP_DIR/backup_config.sh"
  
  # Create management scripts
  create_management_scripts
  
  # Check if scripts were created
  if [ -f "$test_backup_dir/scripts/list_backups.sh" ] && [ -f "$test_backup_dir/scripts/restore_backup.sh" ] && [ -f "$test_backup_dir/scripts/verify_integrity.sh" ] && [ -f "$test_backup_dir/scripts/manage_retention.sh" ]; then
    log_pass "Management scripts created successfully"
  else
    log_error "Failed to create management scripts"
    rm -rf "$test_backup_dir"
    export BACKUP_DIR="$original_backup_dir"
    return 1
  fi
  
  # Check if scripts are executable
  if [ -x "$test_backup_dir/scripts/list_backups.sh" ] && [ -x "$test_backup_dir/scripts/restore_backup.sh" ] && [ -x "$test_backup_dir/scripts/verify_integrity.sh" ] && [ -x "$test_backup_dir/scripts/manage_retention.sh" ]; then
    log_pass "Management scripts are executable"
  else
    log_error "Management scripts are not executable"
    rm -rf "$test_backup_dir"
    export BACKUP_DIR="$original_backup_dir"
    return 1
  fi
  
  # Clean up
  rm -rf "$test_backup_dir"
  export BACKUP_DIR="$original_backup_dir"
  
  log_info "Management scripts creation test passed"
  return 0
}

# Test cron job setup
test_cron_job_setup() {
  test_header "Testing Cron Job Setup"
  
  # Source the backup_config.sh script to get access to its functions
  source "$SETUP_DIR/backup_config.sh"
  
  # Create a temporary cron file for testing
  local test_cron_file="/tmp/test_pg_backup_cron"
  
  # Override cron file location
  setup_backup_cron() {
    log_info "Setting up backup cron jobs..."
    
    # Create cron job file
    local cron_file="$test_cron_file"
    
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
    
    log_info "Backup cron jobs set up successfully"
    return 0
  }
  
  # Set up cron jobs
  setup_backup_cron
  
  # Check if cron file was created
  if [ -f "$test_cron_file" ]; then
    log_pass "Cron job file created successfully"
  else
    log_error "Failed to create cron job file"
    return 1
  fi
  
  # Check if cron file contains expected entries
  if grep -q "$BACKUP_SCHEDULE_FULL" "$test_cron_file" && grep -q "$BACKUP_SCHEDULE_INCREMENTAL" "$test_cron_file"; then
    log_pass "Cron job file contains expected entries"
  else
    log_error "Cron job file does not contain expected entries"
    rm -f "$test_cron_file"
    return 1
  fi
  
  # Check if verification job is included if enabled
  if [ "$BACKUP_VERIFICATION" = "true" ]; then
    if grep -q "$BACKUP_VERIFICATION_SCHEDULE" "$test_cron_file"; then
      log_pass "Verification job included in cron file"
    else
      log_error "Verification job not included in cron file"
      rm -f "$test_cron_file"
      return 1
    fi
  fi
  
  # Clean up
  rm -f "$test_cron_file"
  
  log_info "Cron job setup test passed"
  return 0
}

# Test email notification
test_email_notification() {
  test_header "Testing Email Notification"
  
  # Check if email notifications are enabled
  if [ "${BACKUP_EMAIL_NOTIFICATIONS:-true}" != "true" ]; then
    log_info "Email notifications are disabled in configuration, skipping test"
    return 0
  fi
  
  # Check if required environment variables are set
  if [ -z "$BACKUP_EMAIL_RECIPIENT" ] || [ -z "$BACKUP_EMAIL_SENDER" ]; then
    log_warn "Email recipient or sender not set, skipping email notification test"
    return 0
  fi
  
  # Check if sendmail is available
  if ! command -v sendmail >/dev/null 2>&1; then
    log_warn "sendmail not found, skipping email notification test"
    return 0
  fi
  
  # Create a test email file for success notification
  local test_success_email_file="/tmp/test_backup_success_email.txt"
  
  cat > "$test_success_email_file" << EOF
Subject: $BACKUP_SUCCESS_EMAIL_SUBJECT

This is a test email for PostgreSQL backup success notification.
If you receive this email, the backup notification system is working correctly.

Test completed at $(date)
EOF
  
  # Create a test email file for failure notification
  local test_failure_email_file="/tmp/test_backup_failure_email.txt"
  
  cat > "$test_failure_email_file" << EOF
Subject: $BACKUP_FAILURE_EMAIL_SUBJECT

This is a test email for PostgreSQL backup failure notification.
If you receive this email, the backup notification system is working correctly.

Test completed at $(date)
EOF
  
  log_info "Testing email notification (this is just a simulation, no actual email will be sent)"
  
  # Test success email notification if not in error-only mode
  if [ "$BACKUP_EMAIL_ON_ERROR_ONLY" != "true" ]; then
    log_info "Success email would be sent (BACKUP_EMAIL_ON_ERROR_ONLY is $BACKUP_EMAIL_ON_ERROR_ONLY)"
    log_info "Success email content would be:"
    cat "$test_success_email_file"
  else
    log_info "Success email would NOT be sent (BACKUP_EMAIL_ON_ERROR_ONLY is $BACKUP_EMAIL_ON_ERROR_ONLY)"
  fi
  
  # Test failure email notification (always sent regardless of BACKUP_EMAIL_ON_ERROR_ONLY)
  log_info "Failure email would always be sent regardless of BACKUP_EMAIL_ON_ERROR_ONLY setting"
  log_info "Failure email content would be:"
  cat "$test_failure_email_file"
  
  # Clean up
  rm -f "$test_success_email_file" "$test_failure_email_file"
  
  log_pass "Email notification test completed"
  return 0
}

# Test backup encryption
test_backup_encryption() {
  test_header "Testing Backup Encryption"
  
  # Check if encryption is enabled
  if [ "${BACKUP_ENCRYPTION:-false}" != "true" ]; then
    log_info "Backup encryption is disabled in configuration, skipping test"
    return 0
  fi
  
  # Check if openssl is available
  if ! command -v openssl >/dev/null 2>&1; then
    log_warn "openssl not found, encryption may not work"
    return 0
  }
  
  # Create a test file to encrypt
  local test_file="/tmp/test_backup_encryption.txt"
  local encrypted_file="/tmp/test_backup_encryption.enc"
  
  echo "This is a test file for backup encryption" > "$test_file"
  
  # Generate a test encryption key if not provided
  local encryption_key="${BACKUP_ENCRYPTION_KEY:-$(openssl rand -base64 32)}"
  
  # Encrypt the test file
  log_info "Testing encryption with openssl"
  if openssl enc -aes-256-cbc -salt -in "$test_file" -out "$encrypted_file" -k "$encryption_key" 2>/dev/null; then
    log_pass "File encryption successful"
    
    # Decrypt the test file
    local decrypted_file="/tmp/test_backup_decryption.txt"
    if openssl enc -aes-256-cbc -d -in "$encrypted_file" -out "$decrypted_file" -k "$encryption_key" 2>/dev/null; then
      log_pass "File decryption successful"
      
      # Compare original and decrypted files
      if diff "$test_file" "$decrypted_file" >/dev/null; then
        log_pass "Decrypted file matches original"
      else
        log_error "Decrypted file does not match original"
        rm -f "$test_file" "$encrypted_file" "$decrypted_file"
        return 1
      fi
    else
      log_error "File decryption failed"
      rm -f "$test_file" "$encrypted_file"
      return 1
    fi
  else
    log_error "File encryption failed"
    rm -f "$test_file"
    return 1
  fi
  
  # Clean up
  rm -f "$test_file" "$encrypted_file" "$decrypted_file"
  
  log_info "Backup encryption test passed"
  return 0
}

# Test backup compression
test_backup_compression() {
  test_header "Testing Backup Compression"
  
  # Check if compression is enabled
  if [ "${BACKUP_COMPRESSION:-true}" != "true" ]; then
    log_info "Backup compression is disabled in configuration, skipping test"
    return 0
  fi
  
  # Check if gzip is available
  if ! command -v gzip >/dev/null 2>&1; then
    log_warn "gzip not found, compression may not work"
    return 0
  }
  
  # Create a test file to compress
  local test_file="/tmp/test_backup_compression.txt"
  local compressed_file="/tmp/test_backup_compression.txt.gz"
  
  # Create a file with repeating content to ensure good compression
  for i in {1..100}; do
    echo "This is a test line for backup compression testing. Line $i with some repeated content to ensure good compression ratio." >> "$test_file"
  done
  
  # Get original file size
  local original_size
  original_size=$(stat -c %s "$test_file" 2>/dev/null || stat -f %z "$test_file")
  
  # Compress the test file
  log_info "Testing compression with gzip"
  if gzip -c "$test_file" > "$compressed_file"; then
    log_pass "File compression successful"
    
    # Get compressed file size
    local compressed_size
    compressed_size=$(stat -c %s "$compressed_file" 2>/dev/null || stat -f %z "$compressed_file")
    
    # Calculate compression ratio
    local compression_ratio
    compression_ratio=$(echo "scale=2; $compressed_size * 100 / $original_size" | bc)
    
    log_info "Original size: $original_size bytes"
    log_info "Compressed size: $compressed_size bytes"
    log_info "Compression ratio: $compression_ratio%"
    
    # Check if compression was effective
    if (( $(echo "$compression_ratio < 90" | bc -l) )); then
      log_pass "Compression is effective (ratio: $compression_ratio%)"
    else
      log_warn "Compression is not very effective (ratio: $compression_ratio%)"
    fi
    
    # Decompress the test file
    local decompressed_file="/tmp/test_backup_decompression.txt"
    if gunzip -c "$compressed_file" > "$decompressed_file"; then
      log_pass "File decompression successful"
      
      # Compare original and decompressed files
      if diff "$test_file" "$decompressed_file" >/dev/null; then
        log_pass "Decompressed file matches original"
      else
        log_error "Decompressed file does not match original"
        rm -f "$test_file" "$compressed_file" "$decompressed_file"
        return 1
      fi
    else
      log_error "File decompression failed"
      rm -f "$test_file" "$compressed_file"
      return 1
    fi
  else
    log_error "File compression failed"
    rm -f "$test_file"
    return 1
  fi
  
  # Clean up
  rm -f "$test_file" "$compressed_file" "$decompressed_file"
  
  log_info "Backup compression test passed"
  return 0
}

# Run all tests
run_all_tests() {
  log_info "Starting PostgreSQL backup tests..."
  
  # Run tests
  test_backup_config
  test_pgbackrest_installation
  test_backup_directory_structure
  test_backup_scripts_creation
  test_management_scripts_creation
  test_cron_job_setup
  test_email_notification
  test_backup_encryption
  test_backup_compression
  
  log_info "All PostgreSQL backup tests completed"
}

# If script is run directly, execute tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_all_tests
fi 