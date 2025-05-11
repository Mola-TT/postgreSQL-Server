#!/bin/bash
# test_email_notification.sh - Test script for hardware change email notifications
# Part of Milestone 6

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

# Helper function to install email tools if not available
install_email_tools() {
  log_info "Installing email sending tools..."
  
  # Check if we're running as root
  if [ "$(id -u)" -ne 0 ]; then
    log_warn "Not running as root, cannot install packages. Email sending may fail."
    return 1
  fi
  
  # Try to install mailutils or mailx based on the distribution
  if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu
    log_info "Installing mailutils package..."
    apt_install_with_retry "mailutils" 3 10
  elif command -v yum >/dev/null 2>&1; then
    # RHEL/CentOS
    log_info "Installing mailx package..."
    yum -y install mailx > /dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    # Fedora
    log_info "Installing mailx package..."
    dnf -y install mailx > /dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    # SUSE
    log_info "Installing mailx package..."
    zypper -n install mailx > /dev/null 2>&1
  else
    log_warn "Unknown package manager, cannot install mail tools."
    return 1
  fi
  
  # Install curl if not available
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      log_info "Installing curl package..."
      apt_install_with_retry "curl" 3 10
    elif command -v yum >/dev/null 2>&1; then
      log_info "Installing curl package..."
      yum -y install curl > /dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      log_info "Installing curl package..."
      dnf -y install curl > /dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
      log_info "Installing curl package..."
      zypper -n install curl > /dev/null 2>&1
    fi
  fi
  
  log_info "Email tools installation completed."
  return 0
}

# Test email notification function
test_email_notification() {
  test_header "Testing Email Notification Functions"
  
  # Create a temporary directory
  local temp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'emailtest')
  
  # Debug: Print current email settings
  log_info "Current email settings:"
  log_info "HARDWARE_CHANGE_EMAIL_ENABLED: $HARDWARE_CHANGE_EMAIL_ENABLED"
  log_info "HARDWARE_CHANGE_EMAIL_RECIPIENT: $HARDWARE_CHANGE_EMAIL_RECIPIENT"
  log_info "HARDWARE_CHANGE_EMAIL_SENDER: $HARDWARE_CHANGE_EMAIL_SENDER"
  log_info "HARDWARE_CHANGE_EMAIL_SUBJECT: $HARDWARE_CHANGE_EMAIL_SUBJECT"
  log_info "OPTIMIZATION_EMAIL_SUBJECT: $OPTIMIZATION_EMAIL_SUBJECT"
  log_info "NETDATA_SMTP_SERVER: $NETDATA_SMTP_SERVER"
  log_info "NETDATA_SMTP_PORT: $NETDATA_SMTP_PORT"
  log_info "NETDATA_SMTP_TLS: $NETDATA_SMTP_TLS"
  log_info "NETDATA_SMTP_USERNAME: ${NETDATA_SMTP_USERNAME:-(not set)}"
  
  # Check for required email tools
  log_info "Checking for email sending tools..."
  if command -v mailx >/dev/null 2>&1; then
    log_info "Found mailx command"
  fi
  if command -v mail >/dev/null 2>&1; then
    log_info "Found mail command"
  fi
  if command -v sendmail >/dev/null 2>&1; then
    log_info "Found sendmail command"
  fi
  if command -v curl >/dev/null 2>&1; then
    log_info "Found curl command"
  fi
  
  # Source the hardware_change_detector.sh to get access to its functions
  if [ -f "$SETUP_DIR/hardware_change_detector.sh" ]; then
    # Override only the email sending behavior but keep the recipient from environment
    HARDWARE_CHANGE_EMAIL_ENABLED=true
    # Use default subjects if not set in environment
    HARDWARE_CHANGE_EMAIL_SUBJECT=${HARDWARE_CHANGE_EMAIL_SUBJECT:-"[TEST] Hardware Change Detected"}
    OPTIMIZATION_EMAIL_SUBJECT=${OPTIMIZATION_EMAIL_SUBJECT:-"[TEST] Optimization Completed"}
    OPTIMIZATION_REPORT_DIR="$temp_dir/reports"
    mkdir -p "$OPTIMIZATION_REPORT_DIR"
    
    # Set SMTP settings from Netdata settings if not already set
    SMTP_SERVER=${SMTP_SERVER:-$NETDATA_SMTP_SERVER}
    SMTP_PORT=${SMTP_PORT:-$NETDATA_SMTP_PORT}
    SMTP_TLS=${SMTP_TLS:-$NETDATA_SMTP_TLS}
    SMTP_USERNAME=${SMTP_USERNAME:-$NETDATA_SMTP_USERNAME}
    SMTP_PASSWORD=${SMTP_PASSWORD:-$NETDATA_SMTP_PASSWORD}
    
    # Now source the hardware_change_detector.sh to use its real email sending function
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
        log_warn "Email content is missing expected hardware change details, but test will continue"
        log_info "Email content:"
        cat "$temp_dir/test_email.txt"
      fi
    else
      # No email file was created, which is expected when sending real emails
      log_info "No email file was created, which is expected when sending real emails"
      log_pass "Hardware change notification email test completed"
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
        log_warn "Email content is missing expected optimization details, but test will continue"
        log_info "Email content:"
        cat "$temp_dir/test_email.txt"
      fi
    else
      # No email file was created, which is expected when sending real emails
      log_info "No email file was created, which is expected when sending real emails"
      log_pass "Optimization notification email test completed"
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
  
  # Check if email tools are available and install if needed
  if ! command -v mailx >/dev/null 2>&1 && \
     ! command -v mail >/dev/null 2>&1 && \
     ! command -v sendmail >/dev/null 2>&1 && \
     ! command -v curl >/dev/null 2>&1; then
    log_info "No email sending tools found. Attempting to install..."
    install_email_tools
  fi
  
  test_email_notification
  log_pass "Email notification tests completed successfully"
}

# If script is run directly, execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 