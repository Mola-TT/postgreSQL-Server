#!/bin/bash
# nginx_config.sh - Nginx configuration for PostgreSQL subdomain mapping
# Part of Milestone 3
# This script installs and configures Nginx to provide SSL access to PostgreSQL via pgbouncer
# and implements automatic subdomain-to-database mapping

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory - using unique variable name to avoid conflicts
NGINX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the logger functions
source "$NGINX_SCRIPT_DIR/../lib/logger.sh"

# Source utilities
source "$NGINX_SCRIPT_DIR/../lib/utilities.sh"

# Install Nginx if not already installed
install_nginx() {
  log_info "Installing Nginx..."
  
  # Check if Nginx is already installed
  if command -v nginx >/dev/null 2>&1; then
    log_info "Nginx is already installed, skipping installation"
    return 0
  fi
  
  # Update package index
  log_info "Updating package index..."
  apt_update_with_retry 5 30
  
  # Install Nginx with retry logic
  log_info "Installing Nginx packages..."
  if ! apt_install_with_retry "nginx" 5 30; then
    log_error "Failed to install Nginx, but will continue with limited functionality"
    return 1
  fi
  
  # Check if Nginx was actually installed
  if ! command -v nginx >/dev/null 2>&1; then
    log_error "Nginx command not found after installation"
    return 1
  fi
  
  # Ensure Nginx service is enabled
  log_info "Enabling Nginx service..."
  if ! systemctl enable nginx > /dev/null 2>&1; then
    log_error "Failed to enable Nginx service"
    return 1
  fi
  
  log_info "Nginx installed successfully"
  return 0
}

# Install certbot with retry mechanism
install_certbot() {
  log_info "Installing certbot..."
  
  # Update package lists first
  apt_update_with_retry 3 20
  
  # Try to install certbot and Nginx plugin with retry logic
  local max_attempts=3
  local attempt=1
  local success=false
  
  while [ $attempt -le $max_attempts ] && [ "$success" = "false" ]; do
    log_info "Attempt $attempt of $max_attempts to install certbot..."
    
    if apt-get install -y -qq certbot python3-certbot-nginx > /dev/null 2>&1; then
      # Verify installation succeeded
      if command -v certbot >/dev/null 2>&1; then
        log_info "Certbot installed successfully"
        success=true
      else
        log_warn "Certbot command not found after installation attempt $attempt"
      fi
    else
      log_warn "Failed to install certbot on attempt $attempt"
    fi
    
    if [ "$success" = "false" ]; then
      # Wait before next attempt
      sleep 5
      attempt=$((attempt + 1))
    fi
  done
  
  # Check if installation succeeded
  if [ "$success" = "true" ]; then
    return 0
  else
    log_error "Failed to install certbot after $max_attempts attempts"
    return 1
  fi
}

# Install SSL certificate using Let's Encrypt if enabled
install_ssl_certificate() {
  local domain="${NGINX_DOMAIN:-localhost}"
  local staging_arg=""
  
  # Check if we should use Let's Encrypt staging environment
  if [ "${PRODUCTION:-false}" != "true" ]; then
    log_info "Using Let's Encrypt staging environment (PRODUCTION=false)"
    staging_arg="--test-cert"
  else
    log_info "Using Let's Encrypt production environment"
  fi
  
  if [ "$domain" = "localhost" ]; then
    log_info "Using localhost for domain, skipping Let's Encrypt certificate"
    generate_self_signed_cert "$domain"
    return 0
  fi
  
  log_info "Setting up SSL certificate for $domain..."
  
  # Install certbot if needed
  if ! command -v certbot >/dev/null 2>&1; then
    if ! install_certbot; then
      log_error "Failed to install certbot - falling back to self-signed certificate"
      generate_self_signed_cert "$domain"
      return 0
    fi
  fi
  
  # Check if this is a wildcard domain request (needs DNS validation)
  if [ "${USE_CLOUDFLARE_DNS:-false}" = "true" ]; then
    log_info "Cloudflare DNS validation requested for certificate..."
    
    # Install Cloudflare DNS plugin for certbot
    if ! dpkg -l | grep -q python3-certbot-dns-cloudflare; then
      log_info "Installing Cloudflare DNS plugin for certbot..."
      
      # Try to install Cloudflare plugin with retry logic
      local max_attempts=3
      local attempt=1
      local plugin_success=false
      
      while [ $attempt -le $max_attempts ] && [ "$plugin_success" = "false" ]; do
        if apt-get install -y -qq python3-certbot-dns-cloudflare > /dev/null 2>&1; then
          # Verify plugin installation succeeded
          if dpkg -l | grep -q python3-certbot-dns-cloudflare; then
            log_info "Cloudflare DNS plugin installed successfully"
            plugin_success=true
          else
            log_warn "Cloudflare DNS plugin installation verification failed on attempt $attempt"
          fi
        else
          log_warn "Failed to install Cloudflare DNS plugin on attempt $attempt"
        fi
        
        if [ "$plugin_success" = "false" ]; then
          # Wait before next attempt
          sleep 5
          attempt=$((attempt + 1))
        fi
      done
      
      # Check if plugin installation succeeded
      if [ "$plugin_success" != "true" ]; then
        log_error "Failed to install Cloudflare DNS plugin - falling back to self-signed certificate"
        generate_self_signed_cert "$domain"
        return 0
      fi
    fi
    
    # Create Cloudflare credentials directory and file if needed
    local cloudflare_credentials="/etc/letsencrypt/cloudflare/credentials.ini"
    mkdir -p "$(dirname "$cloudflare_credentials")" 2>/dev/null
    
    # Create or update Cloudflare credentials file
    if [ -n "${CLOUDFLARE_API_TOKEN}" ]; then
      {
        echo "# Cloudflare API token for DNS validation"
        echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}"
      } > "$cloudflare_credentials"
      # Secure the credentials file
      chmod 600 "$cloudflare_credentials"
      log_info "Cloudflare credentials file created at $cloudflare_credentials"
      
      # Validate the Cloudflare API token has proper permissions (requires dns_cloudflare and curl)
      log_info "Validating Cloudflare API token permissions..."
      
      # Install needed tools if missing
      if ! command -v curl >/dev/null 2>&1; then
        apt-get install -y -qq curl > /dev/null 2>&1
      fi
      
      # Test the API token using Cloudflare's API
      local token_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
                         -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                         -H "Content-Type: application/json")
      
      # Check if token is valid and has proper permissions
      if echo "$token_check" | grep -q "\"success\":true"; then
        log_info "Cloudflare API token is valid"
        
        # Check if domain is in Cloudflare
        local zone_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain" \
                          -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                          -H "Content-Type: application/json")
        
        if echo "$zone_check" | grep -q "\"success\":true" && ! echo "$zone_check" | grep -q "\"count\":0"; then
          log_info "Domain $domain found in your Cloudflare account"
          
          # Request certificate with Cloudflare DNS plugin for both domain and wildcard
          log_info "Requesting Let's Encrypt certificate using Cloudflare DNS validation..."
          
          # Run certbot with output to temporary file to capture errors
          local certbot_output="/tmp/certbot_output.$$"
          if ! certbot certonly $staging_arg --dns-cloudflare --dns-cloudflare-credentials "$cloudflare_credentials" \
             -d "$domain" -d "*.$domain" --non-interactive --agree-tos --email "${SSL_EMAIL:-admin@$domain}" > "$certbot_output" 2>&1; then
            
            # Output the error for debugging
            log_warn "Failed to obtain Let's Encrypt certificate using Cloudflare DNS validation:"
            cat "$certbot_output" | while read -r line; do
              log_warn "  $line"
            done
            
            # Check for common errors
            if grep -q "DNS problem" "$certbot_output"; then
              log_warn "There appears to be a DNS validation issue. Make sure your Cloudflare API token has permission to modify DNS records."
            elif grep -q "Rate limit" "$certbot_output"; then
              log_warn "Let's Encrypt rate limit reached. You may need to wait before trying again."
            elif grep -q "invalid email" "$certbot_output"; then
              log_warn "Invalid email address provided: ${SSL_EMAIL:-admin@$domain}"
            fi
            
            # Clean up
            rm -f "$certbot_output"
            
            # Fall back to self-signed certificate
            log_info "Using self-signed certificate instead"
            generate_self_signed_cert "$domain"
          else
            # Clean up
            rm -f "$certbot_output"
            log_info "SSL certificate for $domain and *.$domain installed successfully using Cloudflare DNS validation"
          fi
        else
          log_warn "Domain $domain not found in your Cloudflare account or API token doesn't have zone permissions"
          log_warn "Using self-signed certificate instead"
          generate_self_signed_cert "$domain"
          return 0
        fi
      else
        log_error "CLOUDFLARE_API_TOKEN is not set, cannot perform DNS validation"
        log_warn "Using self-signed certificate instead"
        generate_self_signed_cert "$domain"
        return 0
      fi
    else
      log_error "CLOUDFLARE_API_TOKEN is not set, cannot perform DNS validation"
      log_warn "Using self-signed certificate instead"
      generate_self_signed_cert "$domain"
      return 0
    fi
  else
    # Standard HTTP validation - Note: This will not work for wildcard domains
    log_info "Requesting Let's Encrypt certificate using HTTP validation..."
    if ! certbot --nginx $staging_arg -d "$domain" --non-interactive --agree-tos --email "${SSL_EMAIL:-admin@$domain}" > /dev/null 2>&1; then
      log_warn "Failed to obtain Let's Encrypt certificate, using self-signed certificate instead"
      generate_self_signed_cert "$domain"
    else
      log_info "SSL certificate for $domain installed successfully using HTTP validation"
    fi
  fi
}

# Generate self-signed certificate as fallback
generate_self_signed_cert() {
  local domain="$1"
  local ssl_dir="/etc/nginx/ssl"
  
  log_info "Generating self-signed SSL certificate for $domain..."
  
  # Create SSL directory if it doesn't exist
  mkdir -p "$ssl_dir"
  
  # Generate self-signed certificate
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$ssl_dir/$domain.key" \
    -out "$ssl_dir/$domain.crt" \
    -subj "/CN=*.$domain/O=PostgreSQL Server/C=HK" > /dev/null 2>&1
  
  # Set proper permissions
  chmod 400 "$ssl_dir/$domain.key"
  chmod 444 "$ssl_dir/$domain.crt"
  
  log_info "Self-signed SSL certificate generated for $domain"
}

# Configure Nginx for subdomain to database mapping
configure_nginx() {
  local domain="${NGINX_DOMAIN:-localhost}"
  local port="${PGB_LISTEN_PORT:-6432}"
  local nginx_conf="/etc/nginx/sites-available/postgresql"
  
  log_info "Configuring Nginx for subdomain to database mapping..."
  
  # Create Nginx configuration file
  {
    echo "# PostgreSQL subdomain to database mapping"
    echo "# Generated by nginx_config.sh"
    echo ""
    echo "map \$http_host \$dbname {"
    echo "    default \"postgres\";"
    echo "    \"~^([^.]+)\.$domain\" \$1;"
    echo "}"
    echo ""
    echo "# Redirect HTTP to HTTPS"
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name *.$domain;"
    echo ""
    echo "    location / {"
    echo "        return 301 https://\$host\$request_uri;"
    echo "    }"
    echo "}"
    echo ""
    echo "# Main server block for PostgreSQL connections"
    echo "server {"
    echo "    listen 443 ssl http2;"
    echo "    listen [::]:443 ssl http2;"
    echo "    server_name *.$domain;"
    echo ""
    
    # Certificate paths - use Let's Encrypt paths first, fallback to self-signed
    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
      echo "    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;"
      echo "    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;"
    else
      echo "    ssl_certificate /etc/nginx/ssl/$domain.crt;"
      echo "    ssl_certificate_key /etc/nginx/ssl/$domain.key;"
    fi
    
    echo ""
    echo "    # SSL Configuration"
    echo "    ssl_protocols TLSv1.2 TLSv1.3;"
    echo "    ssl_prefer_server_ciphers on;"
    echo "    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;"
    echo "    ssl_session_timeout 1d;"
    echo "    ssl_session_cache shared:SSL:10m;"
    echo "    ssl_session_tickets off;"
    echo ""
    echo "    # Proxy to pgbouncer"
    echo "    location / {"
    echo "        # Rewrite phase: set \$pgdb variable to database name from subdomain"
    echo "        set \$pgdb \$dbname;"
    echo ""
    echo "        # Proxy settings for PostgreSQL"
    echo "        proxy_pass http://127.0.0.1:$port/\$pgdb;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_set_header X-Forwarded-Host \$host;"
    echo "        proxy_set_header X-Forwarded-Port \$server_port;"
    echo "        proxy_connect_timeout 60s;"
    echo "        proxy_send_timeout 90s;"
    echo "        proxy_read_timeout 90s;"
    echo "        proxy_buffering off;"
    echo "        proxy_request_buffering off;"
    echo "        proxy_http_version 1.1;"
    echo "    }"
    echo "}"
  } > "$nginx_conf"
  
  log_info "Nginx configuration created: $nginx_conf"
  
  # Create symbolic link to enable site
  if [ ! -f "/etc/nginx/sites-enabled/postgresql" ]; then
    ln -s "$nginx_conf" "/etc/nginx/sites-enabled/postgresql"
    log_info "Nginx site enabled"
  fi
  
  # Remove default site if it exists
  if [ -f "/etc/nginx/sites-enabled/default" ]; then
    rm -f "/etc/nginx/sites-enabled/default"
    log_info "Default Nginx site removed"
  fi
  
  # Test Nginx configuration
  if ! nginx -t > /dev/null 2>&1; then
    log_error "Nginx configuration test failed"
    nginx -t  # Show the actual error
    return 1
  fi
  
  # Reload Nginx to apply configuration
  systemctl reload nginx > /dev/null 2>&1
  
  log_info "Nginx configured successfully for subdomain-to-database mapping"
}

# Configure firewall for Nginx if enabled
configure_firewall() {
  if [ "${CONFIGURE_FIREWALL:-true}" = "true" ]; then
    log_info "Configuring firewall for Nginx..."
    
    # Allow HTTP and HTTPS connections
    ufw allow 80/tcp comment "http (nginx)" > /dev/null 2>&1
    ufw allow 443/tcp comment "https (nginx)" > /dev/null 2>&1
    
    log_info "Firewall configured for Nginx"
  fi
}

# Update pgbouncer to handle database name from hostname
update_pgbouncer_config() {
  local pgb_conf="/etc/pgbouncer/pgbouncer.ini"
  
  log_info "Updating pgbouncer configuration for subdomain mapping..."
  
  # Back up original config if not already done
  if [ ! -f "${pgb_conf}.bak.nginx" ]; then
    cp "$pgb_conf" "${pgb_conf}.bak.nginx" 2>/dev/null
  fi
  
  # Check if the database section already has a * entry
  if grep -q "^\* = " "$pgb_conf"; then
    log_info "pgbouncer already has a wildcard database entry, no update needed"
  else
    # Add wildcard database entry if not present
    if grep -q "^\[databases\]" "$pgb_conf"; then
      # Add after the [databases] section
      sed -i '/^\[databases\]/a * = host=127.0.0.1 port=5432' "$pgb_conf"
      log_info "Added wildcard database entry to pgbouncer configuration"
    else
      log_error "Could not find [databases] section in pgbouncer.ini"
      return 1
    fi
  fi
  
  # Restart pgbouncer to apply changes
  systemctl restart pgbouncer > /dev/null 2>&1
  
  log_info "pgbouncer configuration updated successfully"
}

# Configure Nginx main configuration with proper log format for Netdata
configure_nginx_main() {
  log_info "Configuring main Nginx configuration with Netdata-compatible log format..."
  
  local nginx_main_conf="/etc/nginx/nginx.conf"
  
  # Back up original nginx.conf if not already done
  if [ ! -f "${nginx_main_conf}.bak.setup" ]; then
    cp "$nginx_main_conf" "${nginx_main_conf}.bak.setup" 2>/dev/null
  fi
  
  # Create a new nginx.conf with proper log format for Netdata
  cat > "$nginx_main_conf" << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
    # multi_accept on;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    # server_tokens off;

    # server_names_hash_bucket_size 64;
    # server_name_in_redirect off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##
    # SSL Settings
    ##
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ##
    # Logging Settings - Netdata Compatible Format
    ##
    log_format netdata_combined '\$remote_addr - \$remote_user [\$time_local] '
                                '"\$request" \$status \$body_bytes_sent '
                                '"\$http_referer" "\$http_user_agent"';
    
    access_log /var/log/nginx/access.log netdata_combined;
    error_log /var/log/nginx/error.log;

    ##
    # Gzip Settings
    ##
    gzip on;
    # gzip_vary on;
    # gzip_proxied any;
    # gzip_comp_level 6;
    # gzip_buffers 16 8k;
    # gzip_http_version 1.1;
    # gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    ##
    # Virtual Host Configs
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

  log_info "Updated main Nginx configuration with Netdata-compatible log format"
}

# Main function to install and configure Nginx
setup_nginx() {
  log_info "Setting up Nginx for subdomain to database mapping..."
  
  # Check if Nginx is already running properly
  if systemctl is-active --quiet nginx; then
    log_info "Nginx service is already running, proceeding with configuration"
  else
    log_info "Nginx service not running, installing and configuring"
  fi
  
  # Track feature availability
  local nginx_installed=false
  local ssl_configured=false
  local config_success=false
  local pgbouncer_updated=false
  local firewall_configured=false
  
  # Install Nginx
  install_nginx && nginx_installed=true || {
    log_error "Failed to install Nginx, but will continue with limited functionality"
  }
  
  # Only continue with configuration if Nginx was installed
  if [ "$nginx_installed" = "true" ]; then
    # Install SSL certificate
    install_ssl_certificate && ssl_configured=true || {
      log_warn "Failed to install SSL certificate, continuing with limited functionality"
    }
    
    # Configure Nginx
    configure_nginx && config_success=true || {
      log_error "Failed to configure Nginx for subdomain mapping"
      
      # Try a minimal configuration if the full configuration failed
      log_info "Attempting minimal Nginx configuration..."
      
      # Create a minimal configuration file
      local minimal_conf="/etc/nginx/sites-available/postgresql-minimal"
      {
        echo "# Minimal PostgreSQL proxy configuration"
        echo "# Generated by nginx_config.sh fallback"
        echo ""
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name _;"
        echo ""
        echo "    location / {"
        echo "        # Proxy to pgbouncer"
        echo "        proxy_pass http://127.0.0.1:${PGB_LISTEN_PORT:-6432}/postgres;"
        echo "        proxy_set_header Host \$host;"
        echo "        proxy_connect_timeout 60s;"
        echo "        proxy_send_timeout 90s;"
        echo "        proxy_read_timeout 90s;"
        echo "        proxy_buffering off;"
        echo "    }"
        echo "}"
      } > "$minimal_conf"
      
      # Enable the minimal configuration
      if [ ! -f "/etc/nginx/sites-enabled/postgresql-minimal" ]; then
        ln -s "$minimal_conf" "/etc/nginx/sites-enabled/postgresql-minimal" 2>/dev/null || true
      fi
      
      # Remove any potentially conflicting configurations
      rm -f "/etc/nginx/sites-enabled/default" 2>/dev/null || true
      
      # Test the minimal configuration
      if nginx -t > /dev/null 2>&1; then
        log_info "Minimal Nginx configuration applied successfully"
        config_success=true
        
        # Reload Nginx with minimal configuration
        systemctl reload nginx > /dev/null 2>&1 || systemctl restart nginx > /dev/null 2>&1
      else
        log_error "Even minimal Nginx configuration failed, giving up on Nginx setup"
      fi
    }
    
    # Configure firewall
    configure_firewall && firewall_configured=true || {
      log_warn "Failed to configure firewall for Nginx, but continuing"
    }
  fi
  
  # Always attempt to update pgbouncer configuration, even if Nginx setup failed
  update_pgbouncer_config && pgbouncer_updated=true || {
    log_warn "Failed to update pgbouncer configuration, functionality may be limited"
  }
  
  # Configure Nginx main configuration with proper log format for Netdata
  configure_nginx_main
  
  # Print setup summary
  log_info "-----------------------------------------------"
  log_info "NGINX SETUP SUMMARY"
  log_info "-----------------------------------------------"
  if [ "$nginx_installed" = "true" ]; then
    log_info "✓ Nginx installation: SUCCESS"
  else
    log_error "✗ Nginx installation: FAILED"
  fi
  
  if [ "$ssl_configured" = "true" ]; then
    log_info "✓ SSL configuration: SUCCESS"
  else
    log_warn "⚠ SSL configuration: NOT CONFIGURED"
  fi
  
  if [ "$config_success" = "true" ]; then
    log_info "✓ Nginx configuration: SUCCESS"
  else
    log_error "✗ Nginx configuration: FAILED"
  fi
  
  if [ "$pgbouncer_updated" = "true" ]; then
    log_info "✓ pgbouncer wildcard configuration: SUCCESS"
  else
    log_warn "⚠ pgbouncer wildcard configuration: NOT CONFIGURED"
  fi
  
  if [ "$firewall_configured" = "true" ]; then
    log_info "✓ Firewall configuration: SUCCESS"
  else
    log_warn "⚠ Firewall configuration: NOT CONFIGURED"
  fi
  log_info "-----------------------------------------------"
  
  # Return success if at least pgbouncer was updated, which is the minimum required for basic functionality
  if [ "$pgbouncer_updated" = "true" ]; then
    log_info "Basic Nginx/pgbouncer functionality configured successfully"
    if [ "$nginx_installed" = "true" ] && [ "$config_success" = "true" ]; then
      log_info "Nginx setup completed successfully with full subdomain mapping support"
    else
      log_warn "Nginx setup completed with limited functionality (no subdomain mapping)"
    fi
    return 0
  else
    log_error "Failed to configure even basic functionality"
    return 1
  fi
}

# If script is run directly, execute setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_nginx
fi 