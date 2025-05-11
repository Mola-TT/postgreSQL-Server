#!/bin/bash
# test_email_notification.sh - Test script for hardware change email notifications
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

# Test email notification function
test_email_notification() {
  test_header "Testing Email Notification Functions"
  
  # Create a temporary directory
  local temp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'emailtest')
  
  # Source the hardware_change_detector.sh to get access to its functions
  if [ -f "$SETUP_DIR/hardware_change_detector.sh" ]; then
    # Override the actual email sending to prevent real emails during testing
    HARDWARE_CHANGE_EMAIL_ENABLED=true
    HARDWARE_CHANGE_EMAIL_RECIPIENT="test@example.com"
    HARDWARE_CHANGE_EMAIL_SENDER="postgres@test.local"
    HARDWARE_CHANGE_EMAIL_SUBJECT="[TEST] Hardware Change Detected"
    OPTIMIZATION_EMAIL_SUBJECT="[TEST] Optimization Completed"
    OPTIMIZATION_REPORT_DIR="$temp_dir/reports"
    mkdir -p "$OPTIMIZATION_REPORT_DIR"
    
    # Create a mock function to capture email instead of sending it
    send_email_notification() {
      local subject="$1"
      local message="$2"
      local recipient="${3:-$HARDWARE_CHANGE_EMAIL_RECIPIENT}"
      local sender="${4:-$HARDWARE_CHANGE_EMAIL_SENDER}"
      
      log_info "Mock: Would send email to $recipient with subject: $subject"
      
      # Save the email content to a file for verification
      local email_file="$temp_dir/test_email.txt"
      cat > "$email_file" << EMAILEOF
From: $sender
To: $recipient
Subject: $subject
Content-Type: text/plain; charset=UTF-8

$message

--
This is an automated message from the PostgreSQL Server Hardware Change Detector
Server: $(hostname -f)
Date: $(date)
EMAILEOF
      
      log_pass "Email content saved to: $email_file"
      return 0
    }
    
    # Source the hardware_change_detector.sh with our mock function
    source "$SETUP_DIR/hardware_change_detector.sh"
    
    # Test hardware change notification
    test_header "Testing Hardware Change Email Notification"
    log_info "Testing hardware change notification email..."
    send_hardware_change_notification "4" "2" "100" "8192" "4096" "100" "100" "50" "100"
    
    # Check if the email file was created and contains the expected content
    if [ -f "$temp_dir/test_email.txt" ]; then
      log_pass "Hardware change notification email created successfully"
      
      # Check email content
      if grep -q "CPU Cores: 2 → 4" "$temp_dir/test_email.txt" && \
         grep -q "Memory: 4096 MB → 8192 MB" "$temp_dir/test_email.txt" && \
         grep -q "Disk Size: 50 GB → 100 GB" "$temp_dir/test_email.txt"; then
        log_pass "Email contains correct hardware change details"
      else
        log_error "Email content is missing hardware change details"
      fi
    else
      log_error "Failed to create hardware change notification email"
    fi
    
    # Test optimization notification
    test_header "Testing Optimization Completion Email Notification"
    
    # Create a mock optimization report
    local report_file="$OPTIMIZATION_REPORT_DIR/optimization_report_test.txt"
    cat > "$report_file" << REPORTEOF
PostgreSQL Dynamic Optimization Report
=====================================
Generated on: $(date)

Hardware Specifications
---------------------
CPU Cores: 4
Total Memory: 8192 MB
Disk Size: 100 GB

PostgreSQL Configuration
----------------------
max_connections: 200
shared_buffers: 2048MB
work_mem: 16MB
effective_cache_size: 4096MB
maintenance_work_mem: 512MB

pgbouncer Configuration
---------------------
max_client_conn: 500
default_pool_size: 8
reserve_pool_size: 2
pool_mode: transaction
REPORTEOF
    
    # Clear previous test email
    rm -f "$temp_dir/test_email.txt" 2>/dev/null || true
    
    # Test optimization notification
    log_info "Testing optimization completion notification email..."
    send_optimization_notification "$report_file"
    
    # Check if the email file was created and contains the expected content
    if [ -f "$temp_dir/test_email.txt" ]; then
      log_pass "Optimization notification email created successfully"
      
      # Check email content
      if grep -q "PostgreSQL server optimization has been completed successfully" "$temp_dir/test_email.txt" && \
         grep -q "Hardware Specifications" "$temp_dir/test_email.txt" && \
         grep -q "PostgreSQL Configuration" "$temp_dir/test_email.txt"; then
        log_pass "Email contains correct optimization report"
      else
        log_error "Email content is missing optimization details"
      fi
    else
      log_error "Failed to create optimization notification email"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    log_info "All email notification tests completed!"
  else
    log_error "hardware_change_detector.sh not found at $SETUP_DIR/hardware_change_detector.sh"
    return 1
  fi
}

# Main function
main() {
  log_info "Starting email notification test suite..."
  test_email_notification
}

# If script is run directly, execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 