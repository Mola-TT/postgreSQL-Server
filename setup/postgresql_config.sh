#!/bin/bash
# postgresql_config.sh - PostgreSQL installation and configuration
# Part of Milestone 2

# Script directory - using unique variable name to avoid conflicts
PG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the PostgreSQL extraction utilities
source "$PG_SCRIPT_DIR/../lib/pg_extract_hash.sh"

# Function to install PostgreSQL
install_postgresql() {
  log_info "Installing PostgreSQL..."
  
  # Add PostgreSQL repository
  local os_codename
  
  # Install postgresql-common first (needed for pg_lsclusters)
  log_info "Installing postgresql-common from default repositories..."
  
  if ! install_package_with_retry "postgresql-common" 5 30; then
    log_error "Failed to install postgresql-common"
    return 1
  fi
  
  # Get Ubuntu codename
  os_codename=$(lsb_release -cs 2>/dev/null || echo "")
  if [ -z "$os_codename" ]; then
    # Try to get it from /etc/os-release
    if [ -f /etc/os-release ]; then
      os_codename=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
  fi
  
  if [ -z "$os_codename" ]; then
    log_warn "Could not determine OS codename, using 'focal' as default"
    os_codename="focal"
  fi
  
  log_info "Adding PostgreSQL repository..."
  
  # Download PostgreSQL repository key
  log_info "Downloading PostgreSQL repository key..."
  if ! curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg > /dev/null 2>&1; then
    log_error "Failed to download PostgreSQL repository key"
    return 1
  fi
  
  # Create repository configuration file
  log_info "Creating repository configuration file..."
  echo "deb http://apt.postgresql.org/pub/repos/apt/ ${os_codename}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  
  log_info "Successfully added PostgreSQL repository for ${os_codename}"
  
  # Update package lists
  log_info "Updating package lists..."
  if ! apt_update_with_retry 5 30; then
    log_error "Failed to update package lists"
    return 1
  fi
  
  # Install PostgreSQL
  log_info "Installing PostgreSQL packages..."
  
  if ! install_package_with_retry "postgresql postgresql-contrib" 5 30; then
    log_error "Failed to install PostgreSQL packages after multiple retries"
    return 1
  fi
  
  # Enable and start PostgreSQL service
  log_info "Enabling and starting PostgreSQL service..."
  systemctl enable postgresql > /dev/null 2>&1
  systemctl start postgresql > /dev/null 2>&1
  
  # Check if PostgreSQL service is running
  if ! systemctl is-active --quiet postgresql; then
    log_error "PostgreSQL service failed to start"
    return 1
  fi
  
  log_info "PostgreSQL installed successfully"
}

# Function to install pgbouncer
install_pgbouncer() {
  log_info "Installing pgbouncer..."
  
  # Install pgbouncer package using the retry mechanism
  # Parameters: package name, max retries, wait time between retries, silent mode
  if ! apt_install_with_retry "pgbouncer" 5 30 true; then
    log_error "Failed to install pgbouncer after multiple attempts"
    return 1
  fi
  
  # Ensure pgbouncer service is enabled
  log_info "Enabling pgbouncer service..."
  if ! systemctl enable pgbouncer > /dev/null 2>&1; then
    log_error "Failed to enable pgbouncer service"
    return 1
  fi
  
  log_info "pgbouncer installed successfully"
}

# Helper function to ensure a user's password is stored with scram-sha-256 encryption
ensure_scram_password() {
  local username="$1"
  local password="$2"
  
  log_info "Ensuring $username password uses scram-sha-256 encryption"
  
  # First, make sure password_encryption is set to scram-sha-256
  su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
  su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
  
  # Verify the setting was applied
  local current_encryption
  current_encryption=$(su - postgres -c "psql -t -c \"SHOW password_encryption;\"" 2>/dev/null | tr -d ' \n\r\t')
  
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
    systemctl restart postgresql > /dev/null 2>&1
    
    # Verify again
    current_encryption=$(su - postgres -c "psql -t -c \"SHOW password_encryption;\"" 2>/dev/null | tr -d ' \n\r\t')
    if [ "$current_encryption" = "scram-sha-256" ]; then
      log_info "Successfully set password_encryption to scram-sha-256 after restart"
    else
      log_error "Could not set password_encryption to scram-sha-256, authentication may not work as expected"
    fi
  else
    log_info "password_encryption is correctly set to scram-sha-256"
  fi
  
  # Set/reset the user's password to ensure it uses scram-sha-256
  su - postgres -c "psql -c \"ALTER USER $username PASSWORD '$password';\"" > /dev/null 2>&1
  
  # Verify the password was stored with scram-sha-256
  if [ "$username" = "postgres" ]; then
    local password_hash
    password_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | tr -d ' \n\r\t')
    
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
  cp "$pg_conf" "${pg_conf}.bak" 2>/dev/null
  cp "$pg_hba_conf" "${pg_hba_conf}.bak" 2>/dev/null
  
  log_info "Backed up PostgreSQL configuration files"
  
  # Set password encryption to scram-sha-256
  if grep -q "^password_encryption" "$pg_conf"; then
    sed -i "s/^password_encryption.*$/password_encryption = 'scram-sha-256' # Modified by setup script/" "$pg_conf" 2>/dev/null
  else
    echo "password_encryption = 'scram-sha-256' # Added by setup script" >> "$pg_conf" 2>/dev/null
  fi
  
  # Configure PostgreSQL for SSL if enabled
  if [ "${PG_ENABLE_SSL:-true}" = "true" ]; then
    log_info "Configuring PostgreSQL SSL..."
    
    # Determine PostgreSQL data directory
    local pg_data_dir
    pg_data_dir=$(su - postgres -c "psql -t -c \"SHOW data_directory;\"" 2>/dev/null | tr -d ' \n\r\t')
    
    if [ -z "$pg_data_dir" ]; then
      log_warn "Could not determine PostgreSQL data directory, using default path"
      pg_data_dir="/var/lib/postgresql/*/main"
    fi
    
    # Create SSL certificate and key if they don't exist
    local ssl_cert="$pg_data_dir/server.crt"
    local ssl_key="$pg_data_dir/server.key"
    
    if [ ! -f "$ssl_cert" ] || [ ! -f "$ssl_key" ]; then
      log_info "Generating PostgreSQL SSL certificate and key..."
      
      # Generate SSL certificate and key for PostgreSQL
      su - postgres -c "openssl req -new -x509 -days 3650 -nodes -text \
        -out $ssl_cert \
        -keyout $ssl_key \
        -subj '/CN=PostgreSQL/O=Database Server/C=HK'" > /dev/null 2>&1
      
      # Set appropriate permissions
      su - postgres -c "chmod 600 $ssl_key" > /dev/null 2>&1
      su - postgres -c "chmod 644 $ssl_cert" > /dev/null 2>&1
      
      log_info "SSL certificate and key generated successfully"
    else
      log_info "SSL certificate and key already exist, using existing files"
    fi
    
    # Enable SSL in postgresql.conf
    if grep -q "^ssl\s*=\s*" "$pg_conf"; then
      sed -i "s/^ssl\s*=\s*.*$/ssl = on # Modified by setup script/" "$pg_conf" 2>/dev/null
    else
      echo "ssl = on # Added by setup script" >> "$pg_conf" 2>/dev/null
    fi
    
    # Set SSL certificate and key file paths
    if grep -q "^ssl_cert_file\s*=\s*" "$pg_conf"; then
      sed -i "s|^ssl_cert_file\s*=\s*.*$|ssl_cert_file = '$ssl_cert' # Modified by setup script|" "$pg_conf" 2>/dev/null
    else
      echo "ssl_cert_file = '$ssl_cert' # Added by setup script" >> "$pg_conf" 2>/dev/null
    fi
    
    if grep -q "^ssl_key_file\s*=\s*" "$pg_conf"; then
      sed -i "s|^ssl_key_file\s*=\s*.*$|ssl_key_file = '$ssl_key' # Modified by setup script|" "$pg_conf" 2>/dev/null
    else
      echo "ssl_key_file = '$ssl_key' # Added by setup script" >> "$pg_conf" 2>/dev/null
    fi
    
    log_info "SSL enabled for PostgreSQL with certificate and key configuration"
  fi
  
  # Modify listen_addresses to allow external connections if needed
  if grep -q "^listen_addresses" "$pg_conf"; then
    sed -i "s/^listen_addresses.*$/listen_addresses = 'localhost' # Modified by setup script - Only local connections, use pgbouncer for external/" "$pg_conf" 2>/dev/null
  else
    echo "listen_addresses = 'localhost' # Added by setup script - Only local connections, use pgbouncer for external" >> "$pg_conf" 2>/dev/null
  fi
  
  log_info "Updated PostgreSQL configuration"
  
  # Restart PostgreSQL to apply the configuration changes
  systemctl restart postgresql > /dev/null 2>&1
  
  # Set the PostgreSQL superuser password using scram-sha-256
  log_info "Setting PostgreSQL superuser password..."
  
  if [ -n "${PG_SUPERUSER_PASSWORD}" ]; then
    # Use helper function to ensure password uses scram-sha-256
    ensure_scram_password "postgres" "${PG_SUPERUSER_PASSWORD}"
  else
    log_info "Using default PostgreSQL superuser password (PG_SUPERUSER_PASSWORD not specified)"
  fi
  
  # Create the specified database if it doesn't exist
  if [ -n "${PG_DATABASE}" ]; then
    log_info "Creating database: ${PG_DATABASE}"
    
    # Check if the database already exists
    if ! su - postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw ${PG_DATABASE}" 2>/dev/null; then
      # Create the database
      su - postgres -c "createdb ${PG_DATABASE}" > /dev/null 2>&1
      log_info "Database ${PG_DATABASE} created successfully"
    else
      log_info "Database ${PG_DATABASE} already exists, skipping creation"
    fi
  else
    log_info "Using default 'postgres' database (PG_DATABASE not specified)"
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
  } > "$pg_hba_conf" 2>/dev/null
  
  log_info "Updated client authentication configuration"
  
  # Reload PostgreSQL to apply the authentication changes
  su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
  
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
  cp "$pgb_conf" "${pgb_conf}.bak" 2>/dev/null
  
  # Determine authentication type (default to scram-sha-256 for security)
  local auth_type="${PGB_AUTH_TYPE:-scram-sha-256}"
  log_info "Using pgbouncer authentication type: $auth_type"
  
  # Enable log file
  local pgb_log_dir="/var/log/pgbouncer"
  mkdir -p "$pgb_log_dir" 2>/dev/null
  chown postgres:postgres "$pgb_log_dir" 2>/dev/null
  
  # Configure pgbouncer with settings from environment variables
  {
    echo "[databases]"
    # If database name specified, add it to pgbouncer.ini
    if [ -n "${PG_DATABASE}" ]; then
      # If SSL is enabled, we need to handle connection differently
      # Note: pgbouncer doesn't support sslmode in the [databases] section
      echo "${PG_DATABASE} = host=127.0.0.1 port=5432 dbname=${PG_DATABASE}"
    fi
    
    # Configure wildcard database
    # Note: pgbouncer doesn't support sslmode in the [databases] section
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
    echo "ignore_startup_parameters = ${PGB_IGNORE_PARAMS:-extra_float_digits}"
    
    # Configure SSL for pgbouncer if enabled
    if [ "${PG_ENABLE_SSL:-true}" = "true" ]; then
      echo "# Server-side SSL configuration (pgbouncer to PostgreSQL)"
      echo "server_tls_sslmode = require"  # Require SSL for connections to PostgreSQL
      
      # Get PostgreSQL data directory to find SSL certificate files
      local pg_data_dir
      pg_data_dir=$(su - postgres -c "psql -t -c \"SHOW data_directory;\"" 2>/dev/null | tr -d ' \n\r\t')
      
      if [ -z "$pg_data_dir" ]; then
        log_warn "Could not determine PostgreSQL data directory, using default path"
        pg_data_dir="/var/lib/postgresql/*/main"
      fi
      
      # Set the server certificate and key files
      local ssl_cert="$pg_data_dir/server.crt"
      local ssl_key="$pg_data_dir/server.key"
      
      # Use the same certificate files for client connections
      echo "# Client-side SSL configuration"
      echo "client_tls_sslmode = require"  # Requiring SSL from clients to pgbouncer 
      echo "client_tls_cert_file = $ssl_cert"
      echo "client_tls_key_file = $ssl_key"
    else
      # Explicitly disable SSL if not enabled
      echo "# SSL is disabled"
      echo "server_tls_sslmode = disable"
      echo "client_tls_sslmode = disable"
    fi
    
    echo ""
  } > "$pgb_conf" 2>/dev/null
  
  log_info "Updated pgbouncer configuration in $pgb_conf"
  
  # Create or update the auth file for pgbouncer
  log_info "Setting up pgbouncer authentication..."
  
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
    log_info "Authentication file not created (PG_SUPERUSER_PASSWORD not specified)"
  fi
  
  # Set correct ownership for pgbouncer files
  chown postgres:postgres "$pgb_conf" 2>/dev/null
  chown postgres:postgres "$pgb_userlist" 2>/dev/null
  chmod 640 "$pgb_conf" 2>/dev/null
  chmod 640 "$pgb_userlist" 2>/dev/null
  
  # Restart pgbouncer to apply the configuration changes
  systemctl restart pgbouncer > /dev/null 2>&1
  
  # Configure firewall if enabled
  if [ "${CONFIGURE_FIREWALL:-true}" = "true" ]; then
    log_info "Configuring firewall for pgbouncer..."
    
    # Allow connections to pgbouncer port
    ufw allow ${PGB_LISTEN_PORT:-6432}/tcp comment "pgbouncer postgresql connection pooling" > /dev/null 2>&1
    
    # Block direct connections to PostgreSQL port (5432) from external sources
    # Allow only from localhost
    ufw deny 5432/tcp comment "block direct postgresql connections" > /dev/null 2>&1
    
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