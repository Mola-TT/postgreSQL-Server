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
    log_warn "Certbot not found, attempting to install it..."
    
    # Try to install certbot using our retry function
    if apt_update_with_retry 3 20 && apt_install_with_retry "certbot" 5 30; then
      log_info "Certbot installed successfully"
    else
      log_warn "Failed to install certbot automatically, skipping certificate renewal setup"
      return 1
    fi
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
  if systemctl list-unit-files 2>/dev/null | grep -q certbot.timer; then
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
  
  # Create Nginx reload script only if Nginx is installed
  if command -v nginx >/dev/null 2>&1 || [ -d "/etc/nginx" ]; then
    log_info "Creating Nginx reload hook..."
    cat > /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh << 'EOF'
#!/bin/bash
# Reload Nginx to pick up new certificates
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx || systemctl restart nginx
  echo "$(date): Certificate renewed, Nginx reloaded" >> /var/log/letsencrypt-renewal.log
else
  echo "$(date): Certificate renewed, but Nginx is not running or not installed" >> /var/log/letsencrypt-renewal.log
fi
EOF
    
    # Make the hook executable
    chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh
  else
    log_warn "Nginx not found, skipping Nginx reload hook creation"
  fi
  
  # Create pgbouncer reload script if it's installed
  if command -v pgbouncer >/dev/null 2>&1 || [ -d "/etc/pgbouncer" ]; then
    log_info "Creating pgbouncer reload hook..."
    cat > /etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh << 'EOF'
#!/bin/bash
# Reload pgbouncer if SSL certificates are used
if command -v pgbouncer >/dev/null 2>&1 && systemctl is-active --quiet pgbouncer; then
  systemctl reload pgbouncer || systemctl restart pgbouncer
  echo "$(date): Certificate renewed, pgbouncer reloaded" >> /var/log/letsencrypt-renewal.log
else
  echo "$(date): Certificate renewed, but pgbouncer is not running or not installed" >> /var/log/letsencrypt-renewal.log
fi
EOF
    
    # Make the hook executable
    chmod +x /etc/letsencrypt/renewal-hooks/post/pgbouncer-reload.sh
  else
    log_warn "pgbouncer not found, skipping pgbouncer reload hook creation"
  fi
  
  # Create renewal log file if it doesn't exist
  touch /var/log/letsencrypt-renewal.log
  chmod 644 /var/log/letsencrypt-renewal.log
  
  # Test renewal process to ensure hooks are set up correctly
  log_info "Testing certificate renewal process (dry run)..."
  local certbot_output certbot_status
  certbot_output=$(certbot renew --dry-run 2>&1)
  certbot_status=$?
  if [ $certbot_status -eq 0 ]; then
    log_info "Certificate renewal test successful"
  else
    log_warn "⚠ WARNING: Certificate renewal dry-run failed"
    # Print only the most relevant error lines
    echo "$certbot_output" | grep -E 'Detail:|Type: unauthorized|TXT record|DNS problem|error:' | while read -r line; do
      log_warn "$line"
    done
    log_info "This warning is not critical if no certificates are installed yet"
  fi
  
  log_info "Certificate renewal configuration completed"
  
  return 0
}

# Main function to setup certificate renewal
setup_ssl_renewal() {
  log_info "Setting up SSL certificate auto-renewal..."
  
  # Check if auto-renewal is enabled
  if [ "${SSL_AUTO_RENEWAL:-true}" != "true" ]; then
    log_info "SSL certificate auto-renewal is disabled in configuration, skipping setup"
    return 0
  fi
  
  # Configure certificate renewal
  if configure_certificate_renewal; then
    log_info "SSL certificate auto-renewal setup completed successfully"
  else
    log_warn "SSL certificate auto-renewal setup encountered issues, but continuing with basic setup"
    
    # Create a simplified renewal setup that doesn't depend on certbot
    log_info "Creating minimal renewal setup..."
    
    # Create renewal log file
    touch /var/log/letsencrypt-renewal.log
    chmod 644 /var/log/letsencrypt-renewal.log
    
    # Create basic renewal directory
    mkdir -p /etc/letsencrypt/renewal-hooks/post 2>/dev/null || true
    
    # Create a basic reminder script that will run during cron
    log_info "Setting up renewal reminder script..."
    cat > /etc/cron.d/ssl-renewal-reminder << EOF
# SSL Certificate Renewal Reminder
0 0 * * 1 root echo "\$(date): SSL certificates should be checked manually for renewal" >> /var/log/letsencrypt-renewal.log
EOF
    
    chmod 644 /etc/cron.d/ssl-renewal-reminder
    
    log_info "Basic SSL certificate renewal reminder setup completed"
  fi
  
  log_info "SSL renewal setup process completed"
  return 0
}

# If script is run directly, execute setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_ssl_renewal
fi 