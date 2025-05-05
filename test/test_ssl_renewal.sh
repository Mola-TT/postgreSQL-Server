#!/bin/bash
# test_ssl_renewal.sh - Tests SSL certificate renewal configuration
# Part of Milestone 5

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

# Test certbot installation and configuration
test_certbot_installation() {
  log_info "Testing certbot installation..."
  
  # Check if certbot is installed
  if command -v certbot >/dev/null 2>&1; then
    log_info "✓ PASS: Certbot is installed"
  else
    log_error "✗ FAIL: Certbot is not installed"
    return 1
  fi
  
  # Check certbot version
  local certbot_version=$(certbot --version 2>&1 | awk '{print $2}')
  log_info "Certbot version: $certbot_version"
  
  return 0
}

# Test renewal timer configuration
test_renewal_timer() {
  log_info "Testing renewal timer configuration..."
  
  # Check for systemd timer (preferred)
  if systemctl list-unit-files | grep -q certbot.timer; then
    log_info "Certbot systemd timer exists"
    
    # Check if timer is enabled
    if systemctl is-enabled --quiet certbot.timer; then
      log_info "✓ PASS: Certbot timer is enabled"
    else
      log_warn "⚠ WARNING: Certbot timer exists but is not enabled"
    fi
    
    # Check if timer is active
    if systemctl is-active --quiet certbot.timer; then
      log_info "✓ PASS: Certbot timer is active"
    else
      log_warn "⚠ WARNING: Certbot timer exists but is not active"
    fi
  else
    log_info "Certbot systemd timer not found, checking cron configuration..."
    
    # Check for cron job
    if [ -f "/etc/cron.d/certbot" ]; then
      log_info "✓ PASS: Certbot cron job exists"
      log_info "Cron configuration:"
      cat "/etc/cron.d/certbot"
    else
      log_error "✗ FAIL: No renewal timer found (neither systemd timer nor cron job)"
      return 1
    fi
  fi
  
  return 0
}

# Test renewal hooks
test_renewal_hooks() {
  log_info "Testing renewal hooks..."
  
  # Check if renewal hooks directory exists
  if [ -d "/etc/letsencrypt/renewal-hooks/post" ]; then
    log_info "✓ PASS: Renewal hooks directory exists"
    
    # Check for Nginx reload hook
    if [ -f "/etc/letsencrypt/renewal-hooks/post/nginx-reload.sh" ]; then
      log_info "✓ PASS: Nginx reload hook exists"
      
      # Check if hook is executable
      if [ -x "/etc/letsencrypt/renewal-hooks/post/nginx-reload.sh" ]; then
        log_info "✓ PASS: Nginx reload hook is executable"
      else
        log_warn "⚠ WARNING: Nginx reload hook is not executable"
        chmod +x "/etc/letsencrypt/renewal-hooks/post/nginx-reload.sh"
        log_info "Fixed: Made Nginx reload hook executable"
      fi
    else
      log_error "✗ FAIL: Nginx reload hook does not exist"
    fi
    
    # Check for pgbouncer reload hook if pgbouncer is installed
    if command -v pgbouncer >/dev/null 2>&1; then
      if [ -f "/etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh" ]; then
        log_info "✓ PASS: pgbouncer reload hook exists"
        
        # Check if hook is executable
        if [ -x "/etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh" ]; then
          log_info "✓ PASS: pgbouncer reload hook is executable"
        else
          log_warn "⚠ WARNING: pgbouncer reload hook is not executable"
          chmod +x "/etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh"
          log_info "Fixed: Made pgbouncer reload hook executable"
        fi
      else
        log_error "✗ FAIL: pgbouncer reload hook does not exist"
      fi
    else
      log_info "pgbouncer not installed, skipping pgbouncer hook check"
    fi
  else
    log_error "✗ FAIL: Renewal hooks directory does not exist"
    return 1
  fi
  
  # Check if renewal log file exists
  if [ -f "/var/log/letsencrypt-renewal.log" ]; then
    log_info "✓ PASS: Renewal log file exists"
  else
    log_warn "⚠ WARNING: Renewal log file does not exist"
    touch /var/log/letsencrypt-renewal.log
    chmod 644 /var/log/letsencrypt-renewal.log
    log_info "Fixed: Created renewal log file"
  fi
  
  return 0
}

# Test certificate permissions
test_certificate_permissions() {
  log_info "Testing certificate file permissions..."
  
  # Get the domain
  local domain="${NGINX_DOMAIN:-localhost}"
  
  # Skip test for localhost
  if [ "$domain" = "localhost" ]; then
    log_info "Using localhost for domain, skipping certificate permission tests"
    return 0
  fi
  
  # Check Let's Encrypt certificate directory
  if [ -d "/etc/letsencrypt/live/$domain" ]; then
    log_info "✓ PASS: Let's Encrypt certificate directory exists for $domain"
    
    # Check key permissions
    if [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
      local key_permissions=$(stat -c "%a" "/etc/letsencrypt/live/$domain/privkey.pem" 2>/dev/null || echo "unknown")
      if [ "$key_permissions" = "600" ] || [ "$key_permissions" = "400" ]; then
        log_info "✓ PASS: Private key has secure permissions: $key_permissions"
      else
        log_warn "⚠ WARNING: Private key has possibly insecure permissions: $key_permissions"
      fi
    else
      log_warn "⚠ WARNING: Let's Encrypt private key not found"
    fi
    
    # Check certificate permissions
    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
      local cert_permissions=$(stat -c "%a" "/etc/letsencrypt/live/$domain/fullchain.pem" 2>/dev/null || echo "unknown")
      if [ "$cert_permissions" = "644" ] || [ "$cert_permissions" = "640" ] || [ "$cert_permissions" = "600" ]; then
        log_info "✓ PASS: Certificate has appropriate permissions: $cert_permissions"
      else
        log_warn "⚠ WARNING: Certificate has unusual permissions: $cert_permissions"
      fi
    else
      log_warn "⚠ WARNING: Let's Encrypt certificate not found"
    fi
  else
    # Check for self-signed certificate
    log_info "Let's Encrypt certificate directory not found, checking for self-signed certificate..."
    if [ -f "/etc/nginx/ssl/$domain.crt" ] && [ -f "/etc/nginx/ssl/$domain.key" ]; then
      log_info "✓ PASS: Self-signed certificate exists for $domain"
      
      # Check key permissions
      local key_permissions=$(stat -c "%a" "/etc/nginx/ssl/$domain.key" 2>/dev/null || echo "unknown")
      if [ "$key_permissions" = "600" ] || [ "$key_permissions" = "400" ]; then
        log_info "✓ PASS: Self-signed private key has secure permissions: $key_permissions"
      else
        log_warn "⚠ WARNING: Self-signed private key has possibly insecure permissions: $key_permissions"
        chmod 600 "/etc/nginx/ssl/$domain.key"
        log_info "Fixed: Updated self-signed key permissions to 600"
      fi
    else
      log_warn "⚠ WARNING: No certificates found (neither Let's Encrypt nor self-signed)"
    fi
  fi
  
  return 0
}

# Test renewal simulation
test_renewal_simulation() {
  log_info "Testing certificate renewal simulation..."
  
  # Run a dry-run renewal to verify everything works correctly
  log_info "Running a simulated renewal with --dry-run..."
  if certbot renew --dry-run > /dev/null 2>&1; then
    log_info "✓ PASS: Certificate renewal dry-run successful"
  else
    log_error "✗ FAIL: Certificate renewal dry-run failed"
    log_info "Running detailed renewal test for troubleshooting..."
    certbot renew --dry-run --verbose 2>&1 | tail -20
    return 1
  fi
  
  return 0
}

# Main function to run all tests
run_tests() {
  print_section_header "SSL CERTIFICATE RENEWAL TESTS"
  
  # Test certbot installation
  test_certbot_installation
  local certbot_result=$?
  
  # Test renewal timer
  test_renewal_timer
  local timer_result=$?
  
  # Test renewal hooks
  test_renewal_hooks
  local hooks_result=$?
  
  # Test certificate permissions
  test_certificate_permissions
  local permissions_result=$?
  
  # Test renewal simulation
  test_renewal_simulation
  local simulation_result=$?
  
  # Print test summary
  print_section_header "TEST SUMMARY"
  
  local all_passed=true
  
  if [ $certbot_result -eq 0 ]; then
    log_info "✓ PASS: Certbot installation test"
  else
    log_error "✗ FAIL: Certbot installation test"
    all_passed=false
  fi
  
  if [ $timer_result -eq 0 ]; then
    log_info "✓ PASS: Renewal timer test"
  else
    log_error "✗ FAIL: Renewal timer test"
    all_passed=false
  fi
  
  if [ $hooks_result -eq 0 ]; then
    log_info "✓ PASS: Renewal hooks test"
  else
    log_error "✗ FAIL: Renewal hooks test"
    all_passed=false
  fi
  
  if [ $permissions_result -eq 0 ]; then
    log_info "✓ PASS: Certificate permissions test"
  else
    log_error "✗ FAIL: Certificate permissions test"
    all_passed=false
  fi
  
  if [ $simulation_result -eq 0 ]; then
    log_info "✓ PASS: Renewal simulation test"
  else
    log_error "✗ FAIL: Renewal simulation test"
    all_passed=false
  fi
  
  if [ "$all_passed" = true ]; then
    log_info "All SSL certificate renewal tests PASSED!"
    return 0
  else
    log_error "Some SSL certificate renewal tests FAILED. See details above."
    return 1
  fi
}

# Execute tests if this script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_tests
  exit $?
fi 