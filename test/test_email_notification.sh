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
  
  # Create a mock email sending function
  local mock_email_script="$temp_dir/mock_send_email.sh"
  cat > "$mock_email_script" << 'MOCKEOF'
#!/bin/bash
# Mock email sending function for testing

# Get the email content from stdin
email_content=$(cat)

# Extract recipient, subject, and message
recipient=$(echo "$email_content" | grep -i "^To:" | sed 's/^To: //')
subject=$(echo "$email_content" | grep -i "^Subject:" | sed 's/^Subject: //')

# Save the email to a file for verification
echo "$email_content" > "$1"

# Output success message
echo "Email would be sent to: $recipient"
echo "Subject: $subject"
echo "Email content saved to: $1"

# Return success
exit 0
MOCKEOF
  chmod +x "$mock_email_script"
  
  # Create a mock hardware change detector script
  local mock_detector_script="$temp_dir/mock_hardware_detector.sh"
  cat > "$mock_detector_script" << 'DETECTOREOF'
#!/bin/bash
# Mock hardware change detector for testing

# Source the actual hardware_change_detector.sh but override the email sending function
source "$SETUP_DIR/hardware_change_detector.sh"

# Override the email sending function to use our mock
send_email_notification() {
  local subject="$1"
  local message="$2"
  local recipient="${3:-$HARDWARE_CHANGE_EMAIL_RECIPIENT}"
  local sender="${4:-$HARDWARE_CHANGE_EMAIL_SENDER}"
  
  log_info "Mock: Sending email notification to $recipient..."
  
  # Create a temporary email file
  local email_file="$temp_dir/test_email.txt"
  
  # Create email content
  cat > "$email_file" << MAIL
From: $sender
To: $recipient
Subject: $subject
Content-Type: text/plain; charset=UTF-8

$message

--
This is an automated message from the PostgreSQL Server Hardware Change Detector
Server: $(hostname -f)
Date: $(date)
MAIL
  
  log_info "Mock: Email saved to $email_file"
  return 0
}

# Test hardware change notification
test_hardware_change_email() {
  log_info "Testing hardware change email notification..."
  
  # Set up test parameters
  HARDWARE_CHANGE_EMAIL_ENABLED=true
  HARDWARE_CHANGE_EMAIL_RECIPIENT="admin@example.com"
  HARDWARE_CHANGE_EMAIL_SENDER="postgres@example.com"
  HARDWARE_CHANGE_EMAIL_SUBJECT="[TEST] Hardware Change Detected"
  OPTIMIZATION_REPORT_DIR="$temp_dir/reports"
  mkdir -p "$OPTIMIZATION_REPORT_DIR"
  
  # Call the notification function with test data
  send_hardware_change_notification "4" "2" "100" "8192" "4096" "100" "100" "50" "100"
  
  # Check if the email file was created
  if [ -f "$temp_dir/test_email.txt" ]; then
    log_pass "Hardware change email notification created successfully"
    
    # Check email content
    if grep -q "CPU Cores: 2 → 4" "$temp_dir/test_email.txt" && \
       grep -q "Memory: 4096 MB → 8192 MB" "$temp_dir/test_email.txt" && \
       grep -q "Disk Size: 50 GB → 100 GB" "$temp_dir/test_email.txt"; then
      log_pass "Email contains correct hardware change details"
    else
      log_error "Email content is missing hardware change details"
      cat "$temp_dir/test_email.txt"
      return 1
    fi
  else
    log_error "Failed to create hardware change email notification"
    return 1
  fi
  
  return 0
}

# Test optimization notification
test_optimization_email() {
  log_info "Testing optimization completion email notification..."
  
  # Create a mock optimization report
  local report_dir="$temp_dir/reports"
  mkdir -p "$report_dir"
  local report_file="$report_dir/optimization_report_test.txt"
  
  cat > "$report_file" << REPORT
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
REPORT
  
  # Set up test parameters
  HARDWARE_CHANGE_EMAIL_ENABLED=true
  HARDWARE_CHANGE_EMAIL_RECIPIENT="admin@example.com"
  HARDWARE_CHANGE_EMAIL_SENDER="postgres@example.com"
  OPTIMIZATION_EMAIL_SUBJECT="[TEST] Optimization Completed"
  
  # Clear previous test email
  rm -f "$temp_dir/test_email.txt" 2>/dev/null || true
  
  # Call the notification function with the test report
  send_optimization_notification "$report_file"
  
  # Check if the email file was created
  if [ -f "$temp_dir/test_email.txt" ]; then
    log_pass "Optimization email notification created successfully"
    
    # Check email content
    if grep -q "PostgreSQL server optimization has been completed successfully" "$temp_dir/test_email.txt" && \
       grep -q "Hardware Specifications" "$temp_dir/test_email.txt" && \
       grep -q "PostgreSQL Configuration" "$temp_dir/test_email.txt"; then
      log_pass "Email contains correct optimization report"
    else
      log_error "Email content is missing optimization details"
      cat "$temp_dir/test_email.txt"
      return 1
    fi
  else
    log_error "Failed to create optimization email notification"
    return 1
  fi
  
  return 0
}

# Run the tests
test_hardware_change_email
test_optimization_email

# Clean up
rm -rf "$temp_dir"

log_info "Email notification tests completed."
DETECTOREOF

# Main function
main() {
  log_info "Starting email notification test suite..."
  
  # Source the hardware_change_detector.sh to get access to its functions
  if [ -f "$SETUP_DIR/hardware_change_detector.sh" ]; then
    # Create a temporary directory for testing
    local temp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'emailtest')
    
    # Override the actual email sending to prevent real emails during testing
    HARDWARE_CHANGE_EMAIL_ENABLED=true
    HARDWARE_CHANGE_EMAIL_RECIPIENT="test@example.com"
    HARDWARE_CHANGE_EMAIL_SENDER="postgres@test.local"
    HARDWARE_CHANGE_EMAIL_SUBJECT="[TEST] Hardware Change Detected"
    OPTIMIZATION_EMAIL_SUBJECT="[TEST] Optimization Completed"
    OPTIMIZATION_REPORT_DIR="$temp_dir/reports"
    mkdir -p "$OPTIMIZATION_REPORT_DIR"
    
    # Test hardware change notification
    test_header "Testing Hardware Change Email Notification"
    
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

# If script is run directly, execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 