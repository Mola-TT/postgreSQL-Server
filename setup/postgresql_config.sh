#!/bin/bash
# postgresql_config.sh - PostgreSQL and pgbouncer installation and configuration
# Part of Milestone 2

# Import our password hash extraction tool
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/tools/pg_extract_hash.sh"

# Install PostgreSQL
install_postgresql() {
    log_info "Installing PostgreSQL ${PG_VERSION}..."
    
    # Add PostgreSQL repository
    execute_silently "apt-get install -y wget ca-certificates gnupg" \
        "" \
        "Failed to install prerequisites for PostgreSQL" || return 1
    
    # Create the repository configuration file
    execute_silently "sh -c 'echo \"deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list'" \
        "" \
        "Failed to create PostgreSQL repository configuration" || return 1
    
    # Import repository signing key
    execute_silently "wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -" \
        "" \
        "Failed to import PostgreSQL repository key" || return 1
    
    # Update package lists after adding new repository
    execute_silently "apt-get update -qq" \
        "" \
        "Failed to update package lists after adding PostgreSQL repository" || return 1
    
    # Install PostgreSQL
    execute_silently "DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-${PG_VERSION} postgresql-contrib-${PG_VERSION}" \
        "PostgreSQL ${PG_VERSION} installed successfully" \
        "Failed to install PostgreSQL ${PG_VERSION}" || return 1
    
    # Ensure PostgreSQL service is enabled and started
    execute_silently "systemctl enable postgresql" \
        "" \
        "Failed to enable PostgreSQL service" || return 1
    
    execute_silently "systemctl start postgresql" \
        "PostgreSQL service started" \
        "Failed to start PostgreSQL service" || return 1
}

# Install pgbouncer
install_pgbouncer() {
    log_info "Installing pgbouncer..."
    
    execute_silently "DEBIAN_FRONTEND=noninteractive apt-get install -y pgbouncer" \
        "pgbouncer installed successfully" \
        "Failed to install pgbouncer" || return 1
    
    # Ensure pgbouncer service is enabled
    execute_silently "systemctl enable pgbouncer" \
        "" \
        "Failed to enable pgbouncer service" || return 1
}

# Configure PostgreSQL
configure_postgresql() {
    log_info "Configuring PostgreSQL..."
    
    # Backup original configuration file
    execute_silently "cp ${PG_CONF_DIR}/postgresql.conf ${PG_CONF_DIR}/postgresql.conf.bak" \
        "PostgreSQL configuration backed up" \
        "Failed to backup PostgreSQL configuration" || return 1
    
    # Configure PostgreSQL to listen on localhost only for direct connections
    execute_silently "sed -i \"s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/\" ${PG_CONF_DIR}/postgresql.conf" \
        "" \
        "Failed to configure PostgreSQL listen_addresses" || return 1
    
    # Set password_encryption method to scram-sha-256 (PostgreSQL 10+)
    execute_silently "sed -i \"s/#password_encryption = md5/password_encryption = '${PG_AUTH_METHOD}'/\" ${PG_CONF_DIR}/postgresql.conf" \
        "" \
        "Failed to set password encryption method" || return 1
    
    # Set port
    execute_silently "sed -i \"s/#port = 5432/port = ${DB_PORT}/\" ${PG_CONF_DIR}/postgresql.conf" \
        "" \
        "Failed to configure PostgreSQL port" || return 1
    
    # Configure PostgreSQL to allow connections from clients
    execute_silently "cp ${PG_CONF_DIR}/pg_hba.conf ${PG_CONF_DIR}/pg_hba.conf.bak" \
        "PostgreSQL HBA configuration backed up" \
        "Failed to backup PostgreSQL HBA configuration" || return 1
    
    # Set PostgreSQL superuser password
    execute_silently "su - postgres -c \"psql -c \\\"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}'\\\"\"" \
        "PostgreSQL superuser password set" \
        "Failed to set PostgreSQL superuser password" || return 1
    
    # Configure local access directly to PostgreSQL with scram-sha-256 auth
    # First, remove any existing entries
    execute_silently "grep -v 'host    all' ${PG_CONF_DIR}/pg_hba.conf > ${PG_CONF_DIR}/pg_hba.conf.new && mv ${PG_CONF_DIR}/pg_hba.conf.new ${PG_CONF_DIR}/pg_hba.conf" \
        "" \
        "Failed to clean pg_hba.conf" || return 1
    
    # Add entry for local connections with scram-sha-256 auth
    execute_silently "echo \"host    all             all             127.0.0.1/32            ${PG_AUTH_METHOD}\" >> ${PG_CONF_DIR}/pg_hba.conf" \
        "Configured PostgreSQL for secure local connections" \
        "Failed to configure PostgreSQL local authentication" || return 1
    
    # Add entry for local IPv6 connections
    execute_silently "echo \"host    all             all             ::1/128                 ${PG_AUTH_METHOD}\" >> ${PG_CONF_DIR}/pg_hba.conf" \
        "" \
        "Failed to configure IPv6 authentication" || return 1
    
    # Restart PostgreSQL to apply configuration changes
    execute_silently "systemctl restart postgresql" \
        "PostgreSQL configuration applied and service restarted" \
        "Failed to restart PostgreSQL service" || return 1
    
    # Create database if specified
    if [ "$DB_NAME" != "postgres" ]; then
        log_info "Creating database: ${DB_NAME}"
        execute_silently "su - postgres -c \"createdb ${DB_NAME}\"" \
            "Database ${DB_NAME} created successfully" \
            "Failed to create database ${DB_NAME}" || return 1
    fi
}

# Configure pgbouncer
configure_pgbouncer() {
    log_info "Configuring pgbouncer for external connections..."
    
    # Backup original configuration file
    execute_silently "cp /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini.bak" \
        "pgbouncer configuration backed up" \
        "Failed to backup pgbouncer configuration" || return 1
    
    # Configure pgbouncer
    cat > /etc/pgbouncer/pgbouncer.ini <<EOL
[databases]
* = host=127.0.0.1 port=${DB_PORT} dbname=\${DATABASE} user=postgres

[pgbouncer]
listen_addr = ${PGB_LISTEN_ADDR}
listen_port = ${PGB_LISTEN_PORT}
auth_type = ${PGB_AUTH_TYPE}
auth_file = /etc/pgbouncer/userlist.txt
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
admin_users = postgres
stats_users = postgres
pool_mode = ${PGB_POOL_MODE}
server_reset_query = DISCARD ALL
max_client_conn = ${PGB_MAX_CLIENT_CONN}
default_pool_size = ${PGB_DEFAULT_POOL_SIZE}
EOL
    
    # Using our robust password hash extraction tool
    log_info "Creating pgbouncer authentication file..."
    
    # Create a temporary file to store the password hash
    local auth_temp_file=$(mktemp)
    
    # Use our specialized extraction function
    if extract_hash "postgres" "$auth_temp_file"; then
        # Success - copy the file to its final location
        execute_silently "cp ${auth_temp_file} /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to copy pgbouncer userlist" || return 1
            
        # Set proper permissions
        execute_silently "chown postgres:postgres /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to set ownership on pgbouncer userlist.txt" || return 1
        
        execute_silently "chmod 640 /etc/pgbouncer/userlist.txt" \
            "pgbouncer authentication configured successfully with ${PGB_AUTH_TYPE}" \
            "Failed to set permissions on pgbouncer userlist.txt" || return 1
    else
        # Extraction failed, fall back to plain auth as a last resort
        log_warn "Failed to extract secure password hash, falling back to plain auth"
        
        # Update config file to use plain auth
        execute_silently "sed -i 's/auth_type = .*/auth_type = plain/' /etc/pgbouncer/pgbouncer.ini" \
            "" \
            "Failed to update pgbouncer auth type" || return 1
            
        # Create userlist with plain password
        execute_silently "echo \"\\\"postgres\\\" \\\"${PG_SUPERUSER_PASSWORD}\\\"\" > /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to create pgbouncer userlist with plain auth" || return 1
            
        # Set more restrictive permissions for plain text
        execute_silently "chown postgres:postgres /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to set ownership on pgbouncer userlist.txt" || return 1
        
        execute_silently "chmod 600 /etc/pgbouncer/userlist.txt" \
            "pgbouncer configured with fallback plain authentication" \
            "Failed to set permissions on pgbouncer userlist.txt" || return 1
    fi
    
    # Clean up
    rm -f "$auth_temp_file"
    
    # Configure firewall to route external connections through pgbouncer
    if [ "$ENABLE_FIREWALL" = true ]; then
        log_info "Configuring firewall for PostgreSQL and pgbouncer..."
        
        # Install ufw if not already installed
        execute_silently "apt-get install -y ufw" \
            "" \
            "Failed to install ufw firewall" || return 1
        
        # Allow SSH to prevent lockout
        execute_silently "ufw allow ssh" \
            "" \
            "Failed to configure firewall for SSH" || return 1
        
        # Open pgbouncer port for external connections
        if [ "$ALLOWED_IP_RANGES" != "*" ]; then
            # Split the comma-separated IP ranges and add each one
            IFS=',' read -ra IP_RANGES <<< "$ALLOWED_IP_RANGES"
            for ip_range in "${IP_RANGES[@]}"; do
                execute_silently "ufw allow from ${ip_range} to any port ${PGB_LISTEN_PORT}" \
                    "" \
                    "Failed to configure firewall for pgbouncer from ${ip_range}" || return 1
            done
            log_info "Firewall configured to allow connections to pgbouncer from ${#IP_RANGES[@]} IP range(s)"
        else
            # Allow from any IP if ALLOWED_IP_RANGES is "*"
            execute_silently "ufw allow ${PGB_LISTEN_PORT}/tcp" \
                "Firewall configured to allow connections to pgbouncer from any IP (not recommended for production)" \
                "Failed to configure firewall for pgbouncer" || return 1
        fi
        
        # Block external access to PostgreSQL's direct port for security
        execute_silently "ufw deny ${DB_PORT}/tcp" \
            "Firewall configured to block direct external access to PostgreSQL" \
            "Failed to configure firewall to block PostgreSQL" || return 1
        
        # Enable firewall
        execute_silently "echo y | ufw enable" \
            "Firewall enabled" \
            "Failed to enable firewall" || return 1
    fi
    
    # Restart pgbouncer to apply configuration changes
    execute_silently "systemctl restart pgbouncer" \
        "pgbouncer configuration applied and service restarted" \
        "Failed to restart pgbouncer service" || return 1
}

# Setup PostgreSQL with pgbouncer
setup_postgresql() {
    log_info "Starting PostgreSQL and pgbouncer setup..."
    
    # Install PostgreSQL
    install_postgresql || return 1
    
    # Install pgbouncer
    install_pgbouncer || return 1
    
    # Configure PostgreSQL
    configure_postgresql || return 1
    
    # Configure pgbouncer
    configure_pgbouncer || return 1
    
    log_info "PostgreSQL and pgbouncer setup completed successfully"
    log_info "  - PostgreSQL is configured for direct local access on port ${DB_PORT}"
    log_info "  - pgbouncer is configured for external access on port ${PGB_LISTEN_PORT}"
    return 0
}

# Export functions
export -f install_postgresql
export -f install_pgbouncer
export -f configure_postgresql
export -f configure_pgbouncer
export -f setup_postgresql 