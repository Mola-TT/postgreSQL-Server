#!/bin/bash
# ssl_renewal.sh - Configure automatic renewal of Let's Encrypt SSL certificates
# Part of Milestone 5
# This script ensures that SSL certificates are automatically renewed before expiry

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory - using unique variable name to avoid conflicts
SSL_RENEWAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_RENEWAL_LIB_DIR="$SSL_RENEWAL_SCRIPT_DIR/../lib"

# Source the logger functions
source "$SSL_RENEWAL_LIB_DIR/logger.sh"

# Source utilities
source "$SSL_RENEWAL_LIB_DIR/utilities.sh"

# Configure automatic SSL certificate renewal
configure_certificate_renewal() {
  log_info "Setting up automatic certificate renewal..."
  
  # Check if certbot is installed
  if ! command -v certbot >/dev/null 2>&1; then
    log_warn "Certbot not found, skipping certificate renewal setup"
    return 1
  fi
  
  # Ensure cron or systemd timer is properly configured
  if [ -f "/etc/cron.d/certbot" ]; then
    log_info "Certbot renewal cron job already exists"
  else
    log_info "Setting up certbot renewal cron job"
    echo "0 */12 * * * root test -x /usr/bin/certbot && perl -e 'sleep int(rand(43200))' && certbot renew -q" > /etc/cron.d/certbot
    chmod 644 /etc/cron.d/certbot
  fi
  
  # Check for systemd timer (preferred on Ubuntu 18.04+)
  if systemctl list-unit-files | grep -q certbot.timer; then
    log_info "Certbot renewal systemd timer exists, enabling it"
    systemctl enable certbot.timer > /dev/null 2>&1
    systemctl start certbot.timer > /dev/null 2>&1
    
    # Verify it's active
    if systemctl is-active --quiet certbot.timer; then
      log_info "Certbot renewal timer is active"
    else
      log_warn "Certbot renewal timer is not active, falling back to cron"
    fi
  else
    log_info "Certbot systemd timer not found, using cron job for renewal"
  fi
  
  # Handle Cloudflare DNS validation for renewals if used
  if [ "${USE_CLOUDFLARE_DNS:-false}" = "true" ]; then
    log_info "Configuring renewal for Cloudflare DNS validation..."
    
    # Ensure renewal configuration has the correct DNS plugin
    local domain="${NGINX_DOMAIN:-localhost}"
    if [ -f "/etc/letsencrypt/renewal/$domain.conf" ]; then
      # Check if authenticator is already set to dns-cloudflare
      if ! grep -q "authenticator = dns-cloudflare" "/etc/letsencrypt/renewal/$domain.conf"; then
        log_info "Updating renewal configuration for DNS validation"
        sed -i 's/authenticator = .*/authenticator = dns-cloudflare/' "/etc/letsencrypt/renewal/$domain.conf"
      fi
      
      # Ensure credentials are referenced
      if ! grep -q "dns_cloudflare_credentials" "/etc/letsencrypt/renewal/$domain.conf"; then
        log_info "Adding Cloudflare credentials to renewal configuration"
        echo "dns_cloudflare_credentials = /etc/letsencrypt/cloudflare/credentials.ini" >> "/etc/letsencrypt/renewal/$domain.conf"
      fi
    else
      log_warn "Renewal configuration for $domain not found. Certificate renewal may not work properly."
    fi
  fi
  
  # Setup reload hooks for services
  log_info "Setting up reload hooks for renewed certificates..."
  
  # Create renewal hook directory if it doesn't exist
  mkdir -p /etc/letsencrypt/renewal-hooks/post
  
  # Create Nginx reload script
  cat > /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh << 'EOF'
#!/bin/bash
# Reload Nginx to pick up new certificates
systemctl reload nginx || systemctl restart nginx
echo "$(date): Certificate renewed, Nginx reloaded" >> /var/log/letsencrypt-renewal.log
EOF
  
  # Make the hook executable
  chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh
  
  # Create pgbouncer reload script if it's installed
  if command -v pgbouncer >/dev/null 2>&1; then
    cat > /etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh << 'EOF'
#!/bin/bash
# Reload pgbouncer if SSL certificates are used
systemctl reload pgbouncer || systemctl restart pgbouncer
echo "$(date): Certificate renewed, pgbouncer reloaded" >> /var/log/letsencrypt-renewal.log
EOF
    
    # Make the hook executable
    chmod +x /etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh
  fi
  
  # Create renewal log file if it doesn't exist
  touch /var/log/letsencrypt-renewal.log
  chmod 644 /var/log/letsencrypt-renewal.log
  
  # Test renewal process to ensure hooks are set up correctly
  log_info "Testing certificate renewal process (dry run)..."
  certbot renew --dry-run > /dev/null 2>&1
  
  if [ $? -eq 0 ]; then
    log_info "Certificate renewal test successful"
  else
    log_warn "Certificate renewal test failed, please check certbot configuration"
    # Get detailed output for troubleshooting
    log_info "Running detailed renewal test for troubleshooting..."
    certbot renew --dry-run --verbose 2>&1 | tail -20
  fi
  
  log_info "Certificate renewal configuration completed"
  
  return 0
}

# Main function to setup certificate renewal
setup_ssl_renewal() {
  log_info "Setting up SSL certificate auto-renewal..."
  
  # Configure certificate renewal
  if configure_certificate_renewal; then
    log_info "SSL certificate auto-renewal setup completed successfully"
  else
    log_warn "SSL certificate auto-renewal setup encountered issues"
  fi
}

# If script is run directly, execute setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_ssl_renewal
fi 