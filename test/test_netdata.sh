#!/bin/bash
# test_netdata.sh - Tests Netdata connectivity internally and externally
# Part of Milestone 4

# Exit on error
set -e

# Get script directory
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(dirname "$TEST_SCRIPT_DIR")"

# Source the library files
if [ -f "$SCRIPT_DIR/lib/logger.sh" ]; then
  source "$SCRIPT_DIR/lib/logger.sh"
else
  echo "ERROR: Logger library not found at $SCRIPT_DIR/lib/logger.sh"
  exit 1
fi

if [ -f "$SCRIPT_DIR/lib/utilities.sh" ]; then
  source "$SCRIPT_DIR/lib/utilities.sh"
else
  echo "ERROR: Utilities library not found at $SCRIPT_DIR/lib/utilities.sh"
  exit 1
fi

# Print section header
print_section_header() {
  local title="$1"
  log_info "=============================================="
  log_info "$title"
  log_info "=============================================="
}

# Test header function
test_header() {
  local title="$1"
  log_info "========== $title =========="
}

# Test Netdata script existence
test_script_existence() {
  test_header "Testing Netdata Script Existence"
  log_info "Checking for netdata_config.sh script..."
  
  # Check if netdata_config.sh exists
  if [ -f "$SETUP_DIR/netdata_config.sh" ]; then
    log_pass "netdata_config.sh script exists at $SETUP_DIR/netdata_config.sh"
  else
    log_error "netdata_config.sh script not found at $SETUP_DIR/netdata_config.sh"
    return 1
  fi
}

# Test internal Netdata access
test_internal_netdata() {
  log_info "Testing internal Netdata access on 127.0.0.1:19999..."
  
  # Use curl to test if Netdata is accessible internally
  if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:19999/" | grep -q "200"; then
    log_info "✓ PASS: Netdata is accessible internally on port 19999"
  else
    local status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:19999/" 2>/dev/null || echo "Failed to connect")
    log_error "✗ FAIL: Netdata is NOT accessible internally. HTTP Status: $status"
    
    # Check if Netdata is running
    if ! systemctl is-active --quiet netdata; then
      log_error "Netdata service is not running!"
      systemctl status netdata
    fi
    
    # Check netdata configuration
    if [ -f "/etc/netdata/netdata.conf" ]; then
      log_info "Netdata configuration:"
      grep -A 10 "\[web\]" /etc/netdata/netdata.conf
    else
      log_error "Netdata configuration file not found"
    fi
    
    return 1
  fi
  
  return 0
}

# Test external Netdata access via Nginx
test_external_netdata() {
  # Get the configured domain
  local domain
  if [ -f "$SCRIPT_DIR/conf/user.env" ]; then
    domain=$(grep -E "^NGINX_DOMAIN=" "$SCRIPT_DIR/conf/user.env" | cut -d '=' -f 2 | tr -d '"' || echo "")
  fi
  domain="${domain:-localhost}"
  
  log_info "Testing external Netdata access via Nginx (monitor.$domain)..."
  
  # Test HTTP redirect
  log_info "Testing HTTP to HTTPS redirect..."
  local redirect_status=$(curl -s -o /dev/null -w "%{http_code}" -I "http://monitor.$domain/" 2>/dev/null || echo "Failed to connect")
  
  if [[ "$redirect_status" == "301" || "$redirect_status" == "302" ]]; then
    log_info "✓ PASS: HTTP to HTTPS redirect is working (Status: $redirect_status)"
  else
    log_error "✗ FAIL: HTTP to HTTPS redirect is NOT working (Status: $redirect_status)"
    log_error "Checking Nginx configuration..."
    
    # Check Nginx configuration
    if [ -f "/etc/nginx/sites-available/netdata" ]; then
      log_info "Nginx netdata configuration:"
      grep -A 10 "server_name monitor" /etc/nginx/sites-available/netdata
    else
      log_error "Nginx netdata configuration file not found"
    fi
    
    # Check if Nginx is running
    if ! systemctl is-active --quiet nginx; then
      log_error "Nginx service is not running!"
      systemctl status nginx
    fi
  fi
  
  # Test HTTPS access (with --insecure to ignore self-signed certificates)
  log_info "Testing HTTPS access..."
  local https_status=$(curl -s -o /dev/null -w "%{http_code}" --insecure "https://monitor.$domain/" 2>/dev/null || echo "Failed to connect")
  
  if [[ "$https_status" == "200" || "$https_status" == "401" ]]; then
    # 401 is expected if basic auth is configured
    if [[ "$https_status" == "401" ]]; then
      log_info "✓ PASS: Netdata is accessible externally via HTTPS with basic auth protection (Status: $https_status)"
      
      # Try with credentials if available
      local admin_user="admin"
      local admin_pass
      
      # First check for credentials in the credentials file
      if [ -f "/etc/netdata/netdata_credentials.txt" ]; then
        log_info "Found netdata credentials file, using stored credentials..."
        admin_user=$(grep "NETDATA_ADMIN_USER" /etc/netdata/netdata_credentials.txt | cut -d= -f2)
        admin_pass=$(grep "NETDATA_ADMIN_PASSWORD" /etc/netdata/netdata_credentials.txt | cut -d= -f2)
      # Next check in the Nginx htpasswd file
      elif [ -f "/etc/nginx/.htpasswd.netdata" ]; then
        log_info "Found htpasswd file, checking credentials..."
        # Read the password from the setup script output in the log
        if [ -f "/var/log/postgresql-setup.log" ]; then
          admin_pass=$(grep "Password for Netdata access:" /var/log/postgresql-setup.log | tail -1 | awk '{print $NF}')
        fi
      fi
      
      # If still no password, provide instructions for finding it
      if [ -z "$admin_pass" ]; then
        log_info "No admin password found. Check the installation log for: 'Password for Netdata access:'"
        log_info "You can also manually retrieve it by checking: cat /etc/nginx/.htpasswd.netdata"
        
        # Try a default password as a last resort
        admin_pass="admin"
        log_info "Trying with default credentials (admin:admin)..."
      else
        log_info "Testing with credentials ($admin_user:$admin_pass)..."
      fi
      
      local auth_status=$(curl -s -o /dev/null -w "%{http_code}" --insecure -u "$admin_user:$admin_pass" "https://monitor.$domain/" 2>/dev/null || echo "Failed to connect")
      
      if [[ "$auth_status" == "200" ]]; then
        log_info "✓ PASS: Successfully authenticated with credentials"
      else
        log_warn "⚠ WARNING: Authentication with credentials failed (Status: $auth_status)"
        log_info "This is normal if the password is not correctly configured in this test script."
        log_info "You can find the correct password in the installation log or set it in conf/user.env"
      fi
    else
      log_info "✓ PASS: Netdata is accessible externally via HTTPS without basic auth (Status: $https_status)"
    fi
  else
    log_error "✗ FAIL: Netdata is NOT accessible externally via HTTPS (Status: $https_status)"
    
    # Check SSL certificate
    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
      log_info "Let's Encrypt SSL certificate exists"
    elif [ -f "/etc/nginx/ssl/$domain.crt" ]; then
      log_info "Self-signed SSL certificate exists"
    else
      log_error "No SSL certificate found"
    fi
    
    # Check Nginx error log
    if [ -f "/var/log/nginx/error.log" ]; then
      log_info "Last 10 lines of Nginx error log:"
      tail -10 /var/log/nginx/error.log
    fi
  fi
  
  # Check if Netdata port is properly blocked for external access
  log_info "Checking if Netdata port 19999 is properly blocked..."
  local netdata_port_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://$domain:19999/" 2>/dev/null || echo "Connection refused")
  
  if [[ "$netdata_port_status" == "Connection refused" || "$netdata_port_status" == "000" || "$netdata_port_status" == "000Connection refused" ]]; then
    log_info "✓ PASS: Netdata port 19999 is properly blocked for external access"
  else
    log_warn "⚠ WARNING: Netdata port 19999 appears to be accessible externally (Status: $netdata_port_status)"
    log_warn "Firewall rules should block direct access to Netdata"
  fi
}

# Main function to run all tests
run_tests() {
  print_section_header "NETDATA CONNECTIVITY TESTS"
  
  # Test internal access
  test_internal_netdata
  local internal_test_result=$?
  
  # Test external access
  test_external_netdata
  local external_test_result=$?
  
  # Print test summary
  print_section_header "TEST SUMMARY"
  
  if [ $internal_test_result -eq 0 ] && [ $external_test_result -eq 0 ]; then
    log_info "All tests PASSED!"
    log_info "Netdata monitoring system is properly configured and accessible"
  else
    log_error "Some tests FAILED! See above for details."
    
    if [ $internal_test_result -ne 0 ]; then
      log_error "Internal Netdata access test failed"
    fi
    
    if [ $external_test_result -ne 0 ]; then
      log_error "External Netdata access test failed"
    fi
    
    log_info "Possible solutions:"
    log_info "1. Check that Netdata service is running: systemctl status netdata"
    log_info "2. Check that Nginx service is running: systemctl status nginx"
    log_info "3. Verify that Netdata is properly configured to listen on 127.0.0.1:19999"
    log_info "4. Verify that Nginx is properly configured to proxy to Netdata"
    log_info "5. Check firewall settings: ufw status"
    log_info "6. Check DNS settings if using a domain name"
  fi
}

# Run all tests
run_tests 