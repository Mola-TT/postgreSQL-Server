#!/bin/bash
# postgresql_config.sh - PostgreSQL installation and configuration
# Part of Milestone 2

# Function to install PostgreSQL
install_postgresql() {
  log_info "Installing PostgreSQL..."
  
  # Add PostgreSQL repository
  echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  
  # Import PostgreSQL signing key using modern method (avoiding deprecated apt-key)
  log_info "Adding PostgreSQL repository signing key..."
  mkdir -p /etc/apt/trusted.gpg.d/
  local keyring_file="/etc/apt/trusted.gpg.d/postgresql-archive-keyring.gpg"
  
  if ! wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > "$keyring_file"; then
    log_error "Failed to download and install PostgreSQL repository key"
    # Fallback to the old method for older Ubuntu versions
    log_warn "Trying fallback method with apt-key (not recommended but may work on older systems)"
    if ! wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -; then
      log_error "Both key installation methods failed. Cannot continue with PostgreSQL installation."
      return 1
    else
      log_warn "Successfully added key using deprecated apt-key method"
    fi
  else
    chmod 644 "$keyring_file"
    log_info "Successfully added PostgreSQL repository key"
  fi
  
  # Update package lists
  log_info "Updating package lists..."
  if ! execute_silently apt-get update; then
    log_error "Failed to update package lists. Check network connection and repository configuration."
    return 1
  fi
  
  # Install PostgreSQL
  log_info "Installing PostgreSQL packages..."
  if ! execute_silently apt-get install -y postgresql postgresql-contrib; then
    log_error "Failed to install PostgreSQL packages"
    return 1
  fi
  
  # Ensure PostgreSQL is enabled and started
  log_info "Enabling and starting PostgreSQL service..."
  systemctl enable postgresql
  if ! systemctl start postgresql; then
    log_error "Failed to start PostgreSQL service"
    log_warn "Checking PostgreSQL status..."
    systemctl status postgresql
    return 1
  fi
  
  log_info "PostgreSQL installed successfully"
}

# Function to install pgbouncer
install_pgbouncer() {
  log_info "Installing pgbouncer..."
  
  # Install pgbouncer package
  execute_silently apt-get install -y pgbouncer
  
  # Ensure pgbouncer service is enabled
  systemctl enable pgbouncer
  
  log_info "pgbouncer installed successfully"
}

# Helper function to ensure a user's password is stored with scram-sha-256 encryption
ensure_scram_password() {
  local username="$1"
  local password="$2"
  
  log_info "Ensuring $username password uses scram-sha-256 encryption"
  
  # First, make sure password_encryption is set to scram-sha-256
  su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\""
  su - postgres -c "psql -c \"SELECT pg_reload_conf();\""
  
  # Verify the setting was applied
  local current_encryption
  current_encryption=$(su - postgres -c "psql -t -c \"SHOW password_encryption;\"" | tr -d ' \n\r\t')
  
  if [ "$current_encryption" != "scram-sha-256" ]; then
    log_warn "Failed to set password_encryption to scram-sha-256, current value: $current_encryption"
    log_warn "Trying alternative approach..."
    
    # Try setting in postgresql.conf directly
    PG_CONF="/etc/postgresql/*/main/postgresql.conf"
    if grep -q "password_encryption" $PG_CONF; then
      sed -i "s/^.*password_encryption.*$/password_encryption = 'scram-sha-256' # Modified by setup script/" $PG_CONF
    else
      echo "password_encryption = 'scram-sha-256' # Added by setup script" >> $PG_CONF
    fi
    
    # Restart PostgreSQL to apply changes
    systemctl restart postgresql
    
    # Verify again
    current_encryption=$(su - postgres -c "psql -t -c \"SHOW password_encryption;\"" | tr -d ' \n\r\t')
    if [ "$current_encryption" = "scram-sha-256" ]; then
      log_info "Successfully set password_encryption to scram-sha-256 after restart"
    else
      log_error "Could not set password_encryption to scram-sha-256, authentication may not work as expected"
    fi
  else
    log_info "password_encryption is correctly set to scram-sha-256"
  fi
  
  # Set/reset the user's password to ensure it uses scram-sha-256
  su - postgres -c "psql -c \"ALTER USER $username PASSWORD '$password';\""
  
  # Verify the password was stored with scram-sha-256
  if [ "$username" = "postgres" ]; then
    local password_hash
    password_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" | tr -d ' \n\r\t')
    
    if [[ "$password_hash" == SCRAM-SHA-256* ]]; then
      log_info "Verified $username password is stored with scram-sha-256 encryption"
    else
      log_error "Failed to store $username password with scram-sha-256 encryption"
      log_error "Current format: ${password_hash:0:20}..."
    fi
  fi
}

# Function to configure PostgreSQL
configure_postgresql() {
  log_info "Configuring PostgreSQL..."
  
  # Back up postgresql.conf
  local pg_conf
  local pg_hba_conf
  
  # Find the PostgreSQL configuration files
  pg_conf=$(find /etc/postgresql -name "postgresql.conf" | head -n 1)
  pg_hba_conf=$(find /etc/postgresql -name "pg_hba.conf" | head -n 1)
  
  if [ -z "$pg_conf" ] || [ -z "$pg_hba_conf" ]; then
    log_error "PostgreSQL configuration files not found"
    return 1
  fi
  
  # Back up the configuration files
  cp "$pg_conf" "${pg_conf}.bak"
  cp "$pg_hba_conf" "${pg_hba_conf}.bak"
  
  log_info "Backed up PostgreSQL configuration files"
  
  # Set password encryption to scram-sha-256
  if grep -q "^password_encryption" "$pg_conf"; then
    sed -i "s/^password_encryption.*$/password_encryption = 'scram-sha-256' # Modified by setup script/" "$pg_conf"
  else
    echo "password_encryption = 'scram-sha-256' # Added by setup script" >> "$pg_conf"
  fi
  
  # Configure PostgreSQL for SSL if enabled
  if [ "${PG_ENABLE_SSL:-true}" = "true" ]; then
    if grep -q "^ssl\s*=\s*" "$pg_conf"; then
      sed -i "s/^ssl\s*=\s*.*$/ssl = on # Modified by setup script/" "$pg_conf"
    else
      echo "ssl = on # Added by setup script" >> "$pg_conf"
    fi
    log_info "SSL enabled for PostgreSQL"
  fi
  
  # Modify listen_addresses to allow external connections if needed
  if grep -q "^listen_addresses" "$pg_conf"; then
    sed -i "s/^listen_addresses.*$/listen_addresses = 'localhost' # Modified by setup script - Only local connections, use pgbouncer for external/" "$pg_conf"
  else
    echo "listen_addresses = 'localhost' # Added by setup script - Only local connections, use pgbouncer for external" >> "$pg_conf"
  fi
  
  log_info "Updated PostgreSQL configuration"
  
  # Restart PostgreSQL to apply the configuration changes
  systemctl restart postgresql
  
  # Set the PostgreSQL superuser password using scram-sha-256
  log_info "Setting PostgreSQL superuser password..."
  
  if [ -n "${PG_SUPERUSER_PASSWORD}" ]; then
    # Use helper function to ensure password uses scram-sha-256
    ensure_scram_password "postgres" "${PG_SUPERUSER_PASSWORD}"
  else
    log_warn "PG_SUPERUSER_PASSWORD not set, skipping password update"
  fi
  
  # Create the specified database if it doesn't exist
  if [ -n "${PG_DATABASE}" ]; then
    log_info "Creating database: ${PG_DATABASE}"
    
    # Check if the database already exists
    if ! su - postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw ${PG_DATABASE}"; then
      # Create the database
      su - postgres -c "createdb ${PG_DATABASE}"
      log_info "Database ${PG_DATABASE} created successfully"
    else
      log_info "Database ${PG_DATABASE} already exists, skipping creation"
    fi
  else
    log_warn "PG_DATABASE not set, skipping database creation"
  fi
  
  # Update pg_hba.conf for client authentication
  log_info "Configuring client authentication..."
  
  # Start with a clean pg_hba.conf with only local connections
  {
    echo "# TYPE  DATABASE        USER            ADDRESS                 METHOD"
    echo "# PostgreSQL Client Authentication Configuration File"
    echo "# Generated by postgresql_config.sh"
    echo "local   all             postgres                                peer"
    echo "local   all             all                                     peer"
    echo "host    all             all             127.0.0.1/32            scram-sha-256"
    echo "host    all             all             ::1/128                 scram-sha-256"
  } > "$pg_hba_conf"
  
  log_info "Updated client authentication configuration"
  
  # Reload PostgreSQL to apply the authentication changes
  su - postgres -c "psql -c \"SELECT pg_reload_conf();\""
  
  log_info "PostgreSQL configuration completed successfully"
}

# Function to configure pgbouncer for external connections
configure_pgbouncer() {
  log_info "Configuring pgbouncer..."
  
  # Back up pgbouncer configuration file
  local pgb_conf="/etc/pgbouncer/pgbouncer.ini"
  local pgb_userlist="/etc/pgbouncer/userlist.txt"
  
  if [ ! -f "$pgb_conf" ]; then
    log_error "pgbouncer configuration file not found: $pgb_conf"
    return 1
  fi
  
  # Create a backup of the original configuration
  cp "$pgb_conf" "${pgb_conf}.bak"
  
  # Determine authentication type (default to scram-sha-256 for security)
  local auth_type="${PGB_AUTH_TYPE:-scram-sha-256}"
  log_info "Using pgbouncer authentication type: $auth_type"
  
  # Enable log file
  local pgb_log_dir="/var/log/pgbouncer"
  mkdir -p "$pgb_log_dir"
  chown postgres:postgres "$pgb_log_dir"
  
  # Configure pgbouncer with settings from environment variables
  {
    echo "[databases]"
    # If database name specified, add it to pgbouncer.ini
    if [ -n "${PG_DATABASE}" ]; then
      echo "${PG_DATABASE} = host=127.0.0.1 port=5432 dbname=${PG_DATABASE}"
    fi
    echo "* = host=127.0.0.1 port=5432"
    echo ""
    echo "[pgbouncer]"
    echo "logfile = $pgb_log_dir/pgbouncer.log"
    echo "pidfile = /var/run/postgresql/pgbouncer.pid"
    echo "listen_addr = ${PGB_LISTEN_ADDR:-*}"
    echo "listen_port = ${PGB_LISTEN_PORT:-6432}"
    echo "unix_socket_dir = /var/run/postgresql"
    echo "auth_type = ${auth_type}"
    echo "auth_file = /etc/pgbouncer/userlist.txt"
    echo "admin_users = postgres"
    # Use default authentication query for scram-sha-256
    if [ "$auth_type" = "scram-sha-256" ]; then
      echo "auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=$1"
    fi
    echo "pool_mode = ${PGB_POOL_MODE:-transaction}"
    echo "max_client_conn = ${PGB_MAX_CLIENT_CONN:-100}"
    echo "default_pool_size = ${PGB_DEFAULT_POOL_SIZE:-20}"
    echo ""
  } > "$pgb_conf"
  
  log_info "Updated pgbouncer configuration in $pgb_conf"
  
  # Create or update the auth file for pgbouncer
  log_info "Setting up pgbouncer authentication..."
  
  # Source the extract_hash utility
  source "$(dirname "${BASH_SOURCE[0]}")/../tools/pg_extract_hash.sh"
  
  # Extract hash for PostgreSQL superuser
  if [ -n "${PG_SUPERUSER_PASSWORD}" ]; then
    extract_hash "postgres" "$pgb_userlist"
    
    # Verify the hash was successfully created
    if [ -f "$pgb_userlist" ] && [ -s "$pgb_userlist" ]; then
      log_info "Successfully created pgbouncer auth file: $pgb_userlist"
      
      # Verify hash format
      if [ "$auth_type" = "scram-sha-256" ] && ! grep -q "SCRAM-SHA-256" "$pgb_userlist"; then
        log_warn "WARNING: Password hash in $pgb_userlist might not be in SCRAM-SHA-256 format"
        log_warn "This might cause authentication issues with pgbouncer"
        
        # Try to force the correct password hash again
        log_info "Attempting to force correct password hash format..."
        ensure_scram_password "postgres" "${PG_SUPERUSER_PASSWORD}"
        extract_hash "postgres" "$pgb_userlist"
        
        # Final verification
        if grep -q "SCRAM-SHA-256" "$pgb_userlist"; then
          log_info "Successfully fixed password hash format to SCRAM-SHA-256"
        else
          log_error "Failed to get proper SCRAM-SHA-256 hash in userlist.txt"
          log_error "Authentication may not work correctly"
        fi
      fi
    else
      log_error "Failed to create pgbouncer auth file: $pgb_userlist"
      log_error "pgbouncer authentication will not work correctly"
    fi
  else
    log_warn "PG_SUPERUSER_PASSWORD not set, cannot create pgbouncer auth file"
  fi
  
  # Set correct ownership for pgbouncer files
  chown postgres:postgres "$pgb_conf"
  chown postgres:postgres "$pgb_userlist"
  chmod 640 "$pgb_conf"
  chmod 640 "$pgb_userlist"
  
  # Restart pgbouncer to apply the configuration changes
  systemctl restart pgbouncer
  
  # Configure firewall if enabled
  if [ "${CONFIGURE_FIREWALL:-true}" = "true" ]; then
    log_info "Configuring firewall for pgbouncer..."
    
    # Allow connections to pgbouncer port
    ufw allow ${PGB_LISTEN_PORT:-6432}/tcp comment "pgbouncer postgresql connection pooling"
    
    # Block direct connections to PostgreSQL port (5432) from external sources
    # Allow only from localhost
    ufw deny 5432/tcp comment "block direct postgresql connections"
    
    log_info "Firewall configured for pgbouncer"
  fi
  
  log_info "pgbouncer configuration completed successfully"
}

# Main function to install and configure PostgreSQL with pgbouncer
setup_postgresql() {
  log_info "Setting up PostgreSQL server with pgbouncer..."
  
  # Install PostgreSQL
  install_postgresql
  
  # Install pgbouncer
  install_pgbouncer
  
  # Configure PostgreSQL
  configure_postgresql
  
  # Configure pgbouncer
  configure_pgbouncer
  
  log_info "PostgreSQL setup completed successfully"
}

# If script is run directly, execute setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_postgresql
fi