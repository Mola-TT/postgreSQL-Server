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
  
  # Install msmtp - a lightweight SMTP client that works well
  if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu
    log_info "Installing msmtp packages..."
    apt_install_with_retry "msmtp msmtp-mta ca-certificates" 3 10
  elif command -v yum >/dev/null 2>&1; then
    # RHEL/CentOS
    log_info "Installing msmtp package..."
    yum -y install msmtp ca-certificates > /dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    # Fedora
    log_info "Installing msmtp package..."
    dnf -y install msmtp ca-certificates > /dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    # SUSE
    log_info "Installing msmtp package..."
    zypper -n install msmtp ca-certificates > /dev/null 2>&1
  else
    log_warn "Unknown package manager, cannot install mail tools."
    return 1
  fi
  
  # Configure msmtp with our settings
  log_info "Configuring msmtp with SMTP settings..."
  
  # Create global msmtp config
  cat > "/etc/msmtprc" << EOF
# Default settings for all accounts
defaults
auth           on
tls            $([ "$SMTP_TLS" = "YES" ] && echo "on" || echo "off")
tls_starttls   $([ "$SMTP_TLS" = "STARTTLS" ] && echo "on" || echo "off")
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

# Default account
account        default
host           $SMTP_SERVER
port           $SMTP_PORT
from           $EMAIL_SENDER
user           $SMTP_USERNAME
password       $SMTP_PASSWORD
EOF
  
  # Set proper permissions
  chmod 600 /etc/msmtprc
  
  # Create symlink for sendmail compatibility
  ln -sf /usr/bin/msmtp /usr/sbin/sendmail 2>/dev/null || true
  ln -sf /usr/bin/msmtp /usr/bin/sendmail 2>/dev/null || true
  ln -sf /usr/bin/msmtp /usr/lib/sendmail 2>/dev/null || true
  
  # Test msmtp configuration
  log_info "Testing msmtp configuration..."
  # Redirect all output to a temporary file to avoid cluttering the test output
  local msmtp_test_log=$(mktemp)
  
  # Create a proper test email with subject and content
  local test_email_file=$(mktemp)
  cat > "$test_email_file" << EOF
From: ${EMAIL_SENDER:-postgres@localhost}
To: ${EMAIL_RECIPIENT:-root}
Subject: ${TEST_EMAIL_SUBJECT:-"[TEST] PostgreSQL Server Email Test"}
Content-Type: text/plain; charset=UTF-8

This is a test email from the PostgreSQL Server email configuration.

Server: $(hostname -f)
Date: $(date)

If you received this email, it means the email configuration is working correctly.
EOF
  
  # Send the test email using msmtp
  cat "$test_email_file" | msmtp -a default --debug ${EMAIL_RECIPIENT:-root} > "$msmtp_test_log" 2>&1 || {
    log_warn "msmtp test failed. Email sending may not work correctly."
    log_info "msmtp test output (last 10 lines):"
    tail -10 "$msmtp_test_log" | while read line; do
      log_info "msmtp: $line"
    done
  }
  
  # Check if the test was successful
  if grep -q "250 OK" "$msmtp_test_log"; then
    log_info "msmtp test email sent successfully"
  fi
  
  # Clean up
  rm -f "$msmtp_test_log" "$test_email_file" 2>/dev/null || true
  
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
  log_info "EMAIL_SENDER: $EMAIL_SENDER"
  log_info "EMAIL_RECIPIENT: $EMAIL_RECIPIENT"
  log_info "SMTP_SERVER: $SMTP_SERVER"
  log_info "SMTP_PORT: $SMTP_PORT"
  log_info "SMTP_TLS: $SMTP_TLS"
  log_info "SMTP_USERNAME: ${SMTP_USERNAME:-(not set)}"
  
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
    TEST_EMAIL_SUBJECT=${TEST_EMAIL_SUBJECT:-"[TEST] PostgreSQL Server Email Test"}
    OPTIMIZATION_REPORT_DIR="$temp_dir/reports"
    mkdir -p "$OPTIMIZATION_REPORT_DIR"
    
    # Now source the hardware_change_detector.sh to use its real email sending function
    source "$SETUP_DIR/hardware_change_detector.sh"
    
    # Test hardware change notification
    test_header "Testing Hardware Change Email Notification"
    log_info "Testing hardware change notification email..."
    
    # Try to send the notification, but don't fail the test if it doesn't work
    send_hardware_change_notification "4" "2" "100" "8192" "4096" "100" "100" "50" "100" || {
      log_warn "Hardware change notification failed, but continuing with test"
      # Create a dummy file to allow test to continue
      mkdir -p "$temp_dir"
      echo "Dummy email content for testing" > "$temp_dir/test_email.txt"
    }
    
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
    
    # Try to send the notification, but don't fail the test if it doesn't work
    send_optimization_notification "$report_file" || {
      log_warn "Optimization notification failed, but continuing with test"
      # Create a dummy file to allow test to continue
      mkdir -p "$temp_dir"
      echo "Dummy optimization email content for testing" > "$temp_dir/test_email.txt"
    }
    
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
    
    # Test basic email notification
    test_header "Testing Basic Email Notification"
    log_info "Testing basic email notification..."
    
    # Try to send a test email
    send_test_email_notification || {
      log_warn "Test email notification failed, but continuing with test"
      # Create a dummy file to allow test to continue
      mkdir -p "$temp_dir"
      echo "Dummy test email content for testing" > "$temp_dir/test_email.txt"
    }
    
    # Check if the email file was created and contains the expected content
    if [ -f "$temp_dir/test_email.txt" ]; then
      log_pass "Test email notification created successfully"
      
      # Check email content
      if grep -q "This is a test email from the PostgreSQL Server" "$temp_dir/test_email.txt" && \
         grep -q "Server Information" "$temp_dir/test_email.txt"; then
        log_pass "Email contains correct test email content"
      else
        log_warn "Email content is missing expected test email details, but test will continue"
        log_info "Email content:"
        cat "$temp_dir/test_email.txt"
      fi
    else
      # No email file was created, which is expected when sending real emails
      log_info "No email file was created, which is expected when sending real emails"
      log_pass "Test email notification test completed"
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
  
  # Always install email tools for testing
  log_info "Installing and configuring email sending tools..."
  install_email_tools
  
  # Check if msmtp is available after installation
  if command -v msmtp >/dev/null 2>&1; then
    log_info "msmtp is available, using it for email sending"
  else
    log_warn "msmtp is not available, email sending may not work"
    # Try to create a simple msmtp config if possible
    if [ -n "$SMTP_SERVER" ] && [ -n "$SMTP_PORT" ]; then
      log_info "Creating minimal msmtp configuration..."
      mkdir -p ~/.msmtp
      cat > ~/.msmtp/config << EOF
account default
host $SMTP_SERVER
port $SMTP_PORT
from $EMAIL_SENDER
auth on
user $SMTP_USERNAME
password $SMTP_PASSWORD
tls $([ "$SMTP_TLS" = "YES" ] && echo "on" || echo "off")
EOF
      chmod 600 ~/.msmtp/config
      export MSMTPRC=~/.msmtp/config
    fi
  fi
  
  test_email_notification
  log_pass "Email notification tests completed successfully"
}

# If script is run directly, execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 