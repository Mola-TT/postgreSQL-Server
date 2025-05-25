#!/bin/bash
# test_pg_connection.sh - Test script for PostgreSQL and pgbouncer connections
# Part of Milestone 2

# Find the script directory and import essentials
SCRIPT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib/logger.sh"

# Set LOG_FILE to prevent warnings
if [ -z "$LOG_FILE" ]; then
    export LOG_FILE="/var/log/server_init.log"
fi

source "$SCRIPT_DIR/lib/utilities.sh"
source "$SCRIPT_DIR/lib/pg_extract_hash.sh"

# Load default environment variables
source "$SCRIPT_DIR/conf/default.env"

# Override with user environment if available
if [ -f "$SCRIPT_DIR/conf/user.env" ]; then
    source "$SCRIPT_DIR/conf/user.env"
fi

# Status indicators with logger
log_status_pass() {
    log_info "✓ PASS: $1"
}

log_status_fail() {
    log_error "✗ FAIL: $1"
}

log_status_warn() {
    log_warn "! WARN: $1"
}

log_status_skip() {
    log_info "- SKIP: $1"
}

log_section() {
    log_info "=============================================="
    log_info "$1"
    log_info "=============================================="
}

# Test header function
test_header() {
  local title="$1"
  echo ""
  log_info "========== $title =========="
}

# Service status function
test_service_status() {
  test_header "POSTGRESQL CONNECTION TEST RESULTS"
  
  # Check PostgreSQL service status
  local pg_service_name="postgresql.service postgresql@*-main.service postgresql@14-main.service"
  local pg_service_status="inactive"
  local service_found=false
  
  # Try multiple service patterns to find the right one
  for service in $pg_service_name; do
    # Use wildcard expansion for postgresql@*-main.service
    if [[ "$service" == *"*"* ]]; then
      # Try to find matching service
      for actual_service in $(systemctl list-units --type=service | grep postgresql@ | awk '{print $1}'); do
        if systemctl is-active --quiet "$actual_service"; then
          pg_service_status="active"
          service_found=true
          break
        fi
      done
    else
      # Check direct service name
      if systemctl is-active --quiet "$service"; then
        pg_service_status="active"
        service_found=true
        break
      fi
    fi
  done
  
  # Fall back to general PostgreSQL check if no specific service found
  if [ "$service_found" = false ] && systemctl is-active --quiet postgresql; then
    pg_service_status="active"
    service_found=true
  fi
  
  if [ "$pg_service_status" = "active" ]; then
    log_pass "PostgreSQL service is active"
    return 0
  else
    log_error "PostgreSQL service is not active: $pg_service_status"
    return 1
  fi
}

# Test function to check if PostgreSQL is running
check_postgresql_status() {
    # Use the same logic as test_service_status
    local pg_service_name="postgresql.service postgresql@*-main.service postgresql@14-main.service"
    local service_found=false
    
    # Try multiple service patterns to find the right one
    for service in $pg_service_name; do
        # Use wildcard expansion for postgresql@*-main.service
        if [[ "$service" == *"*"* ]]; then
            # Try to find matching service
            for actual_service in $(systemctl list-units --type=service | grep postgresql@ | awk '{print $1}' 2>/dev/null || echo ""); do
                if systemctl is-active --quiet "$actual_service" 2>/dev/null; then
                    service_found=true
                    break
                fi
            done
        else
            # Check direct service name
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                service_found=true
                break
            fi
        fi
    done
    
    # Fall back to general PostgreSQL check if no specific service found
    if [ "$service_found" = false ] && systemctl is-active --quiet postgresql 2>/dev/null; then
        service_found=true
    fi
    
    if [ "$service_found" = true ]; then
        log_status_pass "PostgreSQL service is running"
        return 0
    else
        log_status_fail "PostgreSQL service is NOT running"
        return 1
    fi
}

# Test function to check if pgbouncer is running
check_pgbouncer_status() {
    if systemctl is-active --quiet pgbouncer; then
        log_status_pass "pgbouncer service is running"
        return 0
    else
        log_status_fail "pgbouncer service is NOT running"
        return 1
    fi
}

# Test direct connection to PostgreSQL
test_direct_connection() {
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${DB_PORT}" -U postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            log_status_pass "Connected to PostgreSQL directly on port ${DB_PORT}"
            return 0
        else
            log_status_fail "Unexpected output from PostgreSQL direct connection"
            return 1
        fi
    else
        log_status_warn "Failed to connect to PostgreSQL directly on port ${DB_PORT} (expected if firewall blocks direct access)"
        return 1
    fi
}

# Test connection through pgbouncer
test_pgbouncer_connection() {
    # Test first with postgres database explicitly
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT}"
            return 0
        else
            log_status_fail "Unexpected output from pgbouncer connection"
            return 1
        fi
    else
        log_warn "Failed to connect through pgbouncer with explicit database. Trying default connection..."
        
        # Try connecting without specifying the database
        if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
            if [[ "$output" == *"1"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} (default connection)"
                return 0
            fi
        fi
        
        # Try one more attempt with the user-specified database
        if [ "$DB_NAME" != "postgres" ]; then
            log_warn "Trying to connect with user-specified database: ${DB_NAME}"
            if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d "${DB_NAME}" -c "SELECT 1 as connected;" -t 2>/dev/null); then
                if [[ "$output" == *"1"* ]]; then
                    log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} using ${DB_NAME} database"
                    return 0
                fi
            fi
        fi
        
        # Check pgbouncer status for troubleshooting
        log_warn "Checking pgbouncer service status for troubleshooting..."
        service_status=$(systemctl status pgbouncer 2>&1)
        log_warn "$service_status"
        
        # Check pgbouncer configuration as well
        if [ -f "/etc/pgbouncer/pgbouncer.ini" ]; then
            log_warn "Current pgbouncer configuration:"
            pgbouncer_config=$(cat /etc/pgbouncer/pgbouncer.ini 2>&1)
            log_warn "$pgbouncer_config"
        fi
        
        log_status_fail "Failed to connect through pgbouncer on port ${PGB_LISTEN_PORT}"
        return 1
    fi
}

# Test connection to specific database if configured
test_database_connection() {
    if [ "$DB_NAME" != "postgres" ]; then
        if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d "${DB_NAME}" -c "SELECT 1 as connected;" -t 2>/dev/null); then
            if [[ "$output" == *"1"* ]]; then
                log_status_pass "Connected to database '${DB_NAME}'"
                return 0
            else
                log_status_fail "Unexpected output from database '${DB_NAME}' connection"
                return 1
            fi
        else
            log_status_fail "Failed to connect to database '${DB_NAME}'"
            return 1
        fi
    else
        log_status_skip "Database test (using default postgres database)"
        return 0
    fi
}

# Test pgbouncer authentication file
test_pgbouncer_auth() {
    if [ ! -f "/etc/pgbouncer/userlist.txt" ]; then
        log_status_fail "pgbouncer authentication file not found"
        return 1
    fi
    
    # Check permissions (should be 640 or 600)
    permissions=$(stat -c "%a" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%p" /etc/pgbouncer/userlist.txt 2>/dev/null)
    
    # Check ownership
    owner=$(stat -c "%U:%G" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%Su:%Sg" /etc/pgbouncer/userlist.txt 2>/dev/null)
    
    if [[ ("$permissions" == "640" || "$permissions" == "600") && "$owner" == "postgres:postgres" ]]; then
        log_status_pass "pgbouncer authentication file has correct permissions and ownership"
        return 0
    else
        log_status_warn "pgbouncer authentication file has unusual permissions or ownership (permissions: $permissions, owner: $owner)"
        
        # Try to fix the permissions and ownership
        log_info "Attempting to fix pgbouncer authentication file permissions and ownership"
        execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to fix ownership on pgbouncer authentication file" || log_warn "Could not fix ownership on pgbouncer authentication file"
        
        execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to fix permissions on pgbouncer authentication file" || log_warn "Could not fix permissions on pgbouncer authentication file"
        
        # Check again after fixing
        permissions=$(stat -c "%a" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%p" /etc/pgbouncer/userlist.txt 2>/dev/null)
        owner=$(stat -c "%U:%G" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%Su:%Sg" /etc/pgbouncer/userlist.txt 2>/dev/null)
        
        if [[ ("$permissions" == "640" || "$permissions" == "600") && "$owner" == "postgres:postgres" ]]; then
            log_status_pass "Successfully fixed pgbouncer authentication file permissions and ownership"
            return 0
        else
            log_status_warn "Could not fix pgbouncer authentication file permissions and ownership"
            return 1
        fi
    fi
}

# Check if firewall is configured as expected
test_firewall_configuration() {
    if [ "$ENABLE_FIREWALL" = true ]; then
        if ! command -v ufw >/dev/null 2>&1; then
            log_status_fail "ufw firewall not installed"
            return 1
        fi
        
        ufw_status=$(ufw status | grep -i active)
        if [ -z "$ufw_status" ]; then
            log_status_warn "Firewall is installed but not active"
            return 1
        fi
        
        # Check pgbouncer port
        pgb_port_open=$(ufw status | grep "${PGB_LISTEN_PORT}")
        # Check PostgreSQL direct port
        pg_port_blocked=$(ufw status | grep "${DB_PORT}" | grep -i deny)
        
        if [ -n "$pgb_port_open" ] && [ -n "$pg_port_blocked" ]; then
            log_status_pass "Firewall correctly allows pgbouncer port ${PGB_LISTEN_PORT} and blocks PostgreSQL port ${DB_PORT}"
            return 0
        else
            log_status_warn "Firewall may not be configured correctly for PostgreSQL and pgbouncer ports"
            return 1
        fi
    else
        log_status_skip "Firewall test (ENABLE_FIREWALL=false)"
        return 0
    fi
}

# Test connection with a temporary user
test_temp_user_connection() {
    local temp_user="temp_test_user"
    local temp_password="temp_password_123"
    
    log_info "Creating temporary test user: $temp_user"
    
    # Create a temporary user - redirect output to /dev/null
    if ! execute_silently "su - postgres -c \"psql -c \\\"CREATE USER $temp_user WITH PASSWORD '$temp_password';\\\"\" > /dev/null 2>&1" \
        "" \
        "Failed to create temporary test user"; then
        log_status_fail "Could not create temporary test user"
        return 1
    fi
    
    # Add user to pgbouncer auth file
    log_info "Adding temporary user to pgbouncer authentication file"
    
    # Get current authentication type
    local auth_type=$(grep -i "auth_type" /etc/pgbouncer/pgbouncer.ini | awk -F '=' '{print $2}' | tr -d ' ')
    
    if [[ "$auth_type" == "plain" ]]; then
        # For plain auth, just add the user with plain password
        if ! execute_silently "echo \"\\\"$temp_user\\\" \\\"$temp_password\\\"\" | sudo tee -a /etc/pgbouncer/userlist.txt > /dev/null" \
            "" \
            "Failed to add temporary user to pgbouncer authentication file"; then
            log_status_warn "Could not add temporary user to pgbouncer authentication file"
        fi
        
        # Fix file ownership and permissions after modification
        execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
        execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
    else
        # For scram-sha-256 or md5, first set a password that can be extracted
        execute_silently "su - postgres -c \"psql -c \\\"ALTER USER $temp_user WITH PASSWORD '$temp_password';\\\"\" > /dev/null 2>&1" \
            "" \
            "Failed to update temporary user password"
            
        # For temporary user testing, use a simpler direct extraction method
        log_info "Extracting password hash for user: $temp_user"
        log_info "Using authentication type: $auth_type"
        
        # Create a backup of the userlist file for safe modification
        log_info "Debug: Creating backup of userlist file"
        execute_silently "sudo cp /etc/pgbouncer/userlist.txt /etc/pgbouncer/userlist.txt.backup" \
            "" \
            "Failed to backup userlist file"
        
        # Debug: Show current userlist before modification
        log_info "Debug: Current userlist before modification:"
        if [ -f "/etc/pgbouncer/userlist.txt" ]; then
            sudo cat /etc/pgbouncer/userlist.txt | while IFS= read -r line; do
                log_info "  $line"
            done
        fi
        
        # Clean up any existing entries for this user first to prevent duplicates
        log_info "Debug: Cleaning up any existing entries for user: $temp_user"
        execute_silently "sudo sed -i '/\"'$temp_user'\"/d' /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to clean up existing entries"
        
        # Get the password hash using a direct query (simpler approach for test users)
        local password_hash
        log_info "Debug: Attempting to extract password hash with query: SELECT rolpassword FROM pg_authid WHERE rolname='$temp_user'"
        
        # First, let's verify the user exists
        local user_exists
        user_exists=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM pg_authid WHERE rolname='$temp_user';\"" 2>/dev/null | tr -d ' \n\r\t')
        log_info "Debug: User exists check returned: '$user_exists'"
        
        if [ "$user_exists" = "1" ]; then
            # User exists, now get the password hash - use a more careful extraction
            password_hash=$(su - postgres -c "psql -t -A -c \"SELECT rolpassword FROM pg_authid WHERE rolname='$temp_user';\"" 2>/dev/null | tr -d '\n\r')
            log_info "Debug: Raw password hash extracted: '$password_hash'"
            
            if [ -n "$password_hash" ] && [ "$password_hash" != "||rolpassword||" ] && [[ "$password_hash" == SCRAM-SHA-256* ]]; then
                # Add user to userlist with proper format - create a new file to avoid corruption
                log_info "Debug: Adding to userlist: \"$temp_user\" \"$password_hash\""
                
                # Create a temporary file with the new userlist content
                local temp_userlist=$(mktemp)
                
                # Copy existing content to temp file
                sudo cat /etc/pgbouncer/userlist.txt > "$temp_userlist" 2>/dev/null || true
                
                # Add the new user entry
                printf '"%s" "%s"\n' "$temp_user" "$password_hash" >> "$temp_userlist"
                
                # Replace the original file atomically
                if sudo cp "$temp_userlist" /etc/pgbouncer/userlist.txt; then
                    log_info "Successfully added temporary user to pgbouncer authentication file"
                    
                    # Fix file ownership and permissions after modification
                    execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
                    execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
                    
                    # Clean up temp file
                    rm -f "$temp_userlist"
                else
                    log_warn "Failed to add temporary user to pgbouncer authentication file"
                    rm -f "$temp_userlist"
                fi
            else
                log_warn "Password hash extraction returned invalid result for user: $temp_user (got: '$password_hash')"
                # For testing purposes, if SCRAM fails, try with plain text password
                log_info "Debug: Trying plain text password for testing..."
                
                # Create a temporary file with the new userlist content
                local temp_userlist=$(mktemp)
                
                # Copy existing content to temp file
                sudo cat /etc/pgbouncer/userlist.txt > "$temp_userlist" 2>/dev/null || true
                
                # Add the new user entry with plain text password
                printf '"%s" "%s"\n' "$temp_user" "$temp_password" >> "$temp_userlist"
                
                # Replace the original file atomically
                if sudo cp "$temp_userlist" /etc/pgbouncer/userlist.txt; then
                    log_info "Added temporary user with plain text password for testing"
                    
                    # Fix file ownership and permissions after modification
                    execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
                    execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
                    
                    # Clean up temp file
                    rm -f "$temp_userlist"
                else
                    log_warn "Failed to add temporary user with plain text password"
                    rm -f "$temp_userlist"
                fi
            fi
        else
            log_warn "Temporary user $temp_user does not exist in pg_authid table"
        fi
    fi
    
    # Reload pgbouncer to apply changes
    execute_silently "sudo systemctl reload pgbouncer || sudo systemctl restart pgbouncer" \
        "Reloaded pgbouncer with temporary user" \
        "Failed to reload pgbouncer"
    
    # Wait for pgbouncer to fully reload and process userlist changes
    log_info "Waiting for pgbouncer to process userlist changes..."
    sleep 10
    
    # Debug: Show what's in the userlist file after modification
    log_info "Debug: Current userlist contents after modification:"
    if [ -f "/etc/pgbouncer/userlist.txt" ]; then
        sudo cat /etc/pgbouncer/userlist.txt | while IFS= read -r line; do
            if [[ "$line" == *"$temp_user"* ]]; then
                log_info "Found temp user line: $line"
            elif [[ "$line" == *"postgres"* ]]; then
                log_info "Found postgres user line: $line"
            else
                log_info "Other line: $line"
            fi
        done
    fi
    
    # Debug: Check pgbouncer status
    log_info "Debug: Checking pgbouncer service status"
    if systemctl is-active --quiet pgbouncer; then
        log_info "Debug: pgbouncer service is active"
    else
        log_warn "Debug: pgbouncer service is NOT active"
    fi
    
    # Debug: Verify postgres user is still in userlist
    log_info "Debug: Verifying postgres user is still in userlist"
    if sudo grep -q '"postgres"' /etc/pgbouncer/userlist.txt; then
        log_info "Debug: postgres user found in userlist"
    else
        log_warn "Debug: postgres user NOT found in userlist - this is the problem!"
        # Try to restore from backup if postgres user is missing
        if [ -f "/etc/pgbouncer/userlist.txt.backup" ]; then
            log_warn "Debug: Restoring userlist from backup due to missing postgres user"
            sudo cp /etc/pgbouncer/userlist.txt.backup /etc/pgbouncer/userlist.txt
            sudo chown postgres:postgres /etc/pgbouncer/userlist.txt
            sudo chmod 600 /etc/pgbouncer/userlist.txt
            execute_silently "sudo systemctl reload pgbouncer" "" "Failed to reload pgbouncer after restore"
            sleep 5
        fi
    fi
    
    # Debug: Test basic pgbouncer connectivity with postgres user first to determine SSL requirements
    log_info "Debug: Testing basic pgbouncer connectivity with postgres user"
    local postgres_ssl_mode=""
    
    # Try multiple times with different approaches to handle timing issues
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        log_info "Debug: Attempt $((retry_count + 1)) of $max_retries"
        
        # Try without SSL first, using IPv4 explicitly
        if PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1;" -t >/dev/null 2>&1; then
            log_info "Debug: Basic pgbouncer connectivity works with postgres user (without SSL, IPv4)"
            postgres_ssl_mode="none"
            break
        else
            # Try with SSL, using IPv4 explicitly
            if PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1;" -t --set=sslmode=require >/dev/null 2>&1; then
                log_info "Debug: Basic pgbouncer connectivity works with postgres user (with SSL, IPv4)"
                postgres_ssl_mode="require"
                break
            else
                # Try with localhost (IPv6) as fallback
                if PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1;" -t >/dev/null 2>&1; then
                    log_info "Debug: Basic pgbouncer connectivity works with postgres user (without SSL, IPv6)"
                    postgres_ssl_mode="none"
                    break
                elif PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1;" -t --set=sslmode=require >/dev/null 2>&1; then
                    log_info "Debug: Basic pgbouncer connectivity works with postgres user (with SSL, IPv6)"
                    postgres_ssl_mode="require"
                    break
                fi
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            log_info "Debug: Retry $retry_count failed, waiting 5 seconds before next attempt..."
            sleep 5
        fi
    done
    
    if [ "$postgres_ssl_mode" = "" ]; then
        log_warn "Debug: Basic pgbouncer connectivity FAILED with postgres user after $max_retries attempts"
        # Show the actual error from the last attempt
        error_output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1;" -t 2>&1 || true)
        log_warn "Debug: Error details: $error_output"
        postgres_ssl_mode="failed"
    fi
    
    # Try connecting directly to PostgreSQL with the temporary user
    if output=$(PGPASSWORD="$temp_password" psql -h localhost -p "${DB_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
        if [[ "$output" == *"temp_user_connected"* ]]; then
            log_status_pass "Connected to PostgreSQL directly with temporary user"
            direct_success=true
        else
            log_status_warn "Unexpected output from temporary user direct connection"
            direct_success=false
        fi
    else
        log_status_warn "Failed to connect directly with temporary user (expected if firewall blocks direct access)"
        direct_success=false
    fi
    
    # Try connecting through pgbouncer with the temporary user using the same SSL mode that works for postgres
    log_info "Debug: Attempting pgbouncer connection with user: $temp_user on port: ${PGB_LISTEN_PORT}"
    log_info "Debug: Using SSL mode determined from postgres user test: $postgres_ssl_mode"
    
    local pgbouncer_success=false
    
    if [ "$postgres_ssl_mode" = "failed" ]; then
        log_status_fail "Cannot test temporary user - basic pgbouncer connectivity failed for postgres user"
        pgbouncer_success=false
    elif [ "$postgres_ssl_mode" = "none" ]; then
        # Try without SSL since postgres user works without SSL, prefer IPv4
        if output=$(PGPASSWORD="$temp_password" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>&1); then
            if [[ "$output" == *"temp_user_connected"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (without SSL, IPv4)"
                pgbouncer_success=true
            else
                log_status_fail "Unexpected output from temporary user pgbouncer connection (without SSL, IPv4): $output"
                pgbouncer_success=false
            fi
        else
            # Fallback to IPv6 if IPv4 fails
            if output=$(PGPASSWORD="$temp_password" psql -h localhost -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>&1); then
                if [[ "$output" == *"temp_user_connected"* ]]; then
                    log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (without SSL, IPv6)"
                    pgbouncer_success=true
                else
                    log_status_fail "Unexpected output from temporary user pgbouncer connection (without SSL, IPv6): $output"
                    pgbouncer_success=false
                fi
            else
                log_status_fail "Failed to connect through pgbouncer with temporary user (without SSL, both IPv4 and IPv6). Error: $output"
                pgbouncer_success=false
            fi
        fi
    elif [ "$postgres_ssl_mode" = "require" ]; then
        # Try with SSL since postgres user requires SSL, prefer IPv4
        if output=$(PGPASSWORD="$temp_password" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t --set=sslmode=require 2>&1); then
            if [[ "$output" == *"temp_user_connected"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (with SSL, IPv4)"
                pgbouncer_success=true
            else
                log_status_fail "Unexpected output from temporary user pgbouncer connection (with SSL, IPv4): $output"
                pgbouncer_success=false
            fi
        else
            # Fallback to IPv6 if IPv4 fails
            if output=$(PGPASSWORD="$temp_password" psql -h localhost -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t --set=sslmode=require 2>&1); then
                if [[ "$output" == *"temp_user_connected"* ]]; then
                    log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (with SSL, IPv6)"
                    pgbouncer_success=true
                else
                    log_status_fail "Unexpected output from temporary user pgbouncer connection (with SSL, IPv6): $output"
                    pgbouncer_success=false
                fi
            else
                log_status_fail "Failed to connect through pgbouncer with temporary user (with SSL, both IPv4 and IPv6). Error: $output"
                pgbouncer_success=false
            fi
        fi
    fi
    
    # Clean up pgbouncer userlist.txt - restore from backup for safety
    log_info "Cleaning up: Restoring userlist file from backup"
    if [ -f "/etc/pgbouncer/userlist.txt.backup" ]; then
        execute_silently "sudo mv /etc/pgbouncer/userlist.txt.backup /etc/pgbouncer/userlist.txt" \
            "Restored userlist file from backup" \
            "Failed to restore userlist file from backup"
    else
        # Fallback to manual removal if backup doesn't exist
        log_info "Backup not found, removing temporary user manually"
        execute_silently "sudo sed -i '/\"'$temp_user'\"/d' /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to remove temporary user from pgbouncer authentication file" || log_warn "Could not clean up pgbouncer authentication file"
    fi
    
    # Fix permissions and ownership on pgbouncer authentication file
    log_info "Fixing pgbouncer authentication file permissions and ownership"
    execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" \
        "" \
        "Failed to fix ownership on pgbouncer authentication file" || log_warn "Could not fix ownership on pgbouncer authentication file"
    
    execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" \
        "" \
        "Failed to fix permissions on pgbouncer authentication file" || log_warn "Could not fix permissions on pgbouncer authentication file"
    
    # Reload pgbouncer again after cleanup
    execute_silently "sudo systemctl reload pgbouncer || sudo systemctl restart pgbouncer" \
        "" \
        "Failed to reload pgbouncer after cleanup"
    
    # Drop the temporary user - redirect output to /dev/null
    log_info "Cleaning up: Removing temporary test user"
    execute_silently "su - postgres -c \"psql -c \\\"DROP USER IF EXISTS $temp_user;\\\"\" > /dev/null 2>&1" \
        "" \
        "Failed to remove temporary test user" || log_warn "Could not remove temporary test user, manual cleanup needed"
    
    # Return success or failure
    if [ "$pgbouncer_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Execute commands silently and handle errors
execute_silently() {
    local cmd="$1"
    local success_msg="$2"
    local error_msg="$3"
    
    # Create temporary files for capturing output
    local tmp_out=$(mktemp)
    local tmp_err=$(mktemp)
    
    # Execute the command, capturing stdout and stderr
    eval "$cmd" > "$tmp_out" 2> "$tmp_err"
    local status=$?
    
    # Check execution status
    if [ $status -eq 0 ]; then
        # Command succeeded
        if [ -n "$success_msg" ]; then
            log_info "$success_msg"
        fi
    else
        # Command failed
        if [ -n "$error_msg" ]; then
            log_warn "$error_msg"
        fi
        
        # If log level is DEBUG, show the error output
        if [ "${LOG_LEVEL:-INFO}" = "DEBUG" ]; then
            if [ -s "$tmp_err" ]; then
                log_debug "Error output from command '$cmd':"
                cat "$tmp_err" | while read -r line; do
                    log_debug "$line"
                done
            fi
        fi
    fi
    
    # Clean up temp files
    rm -f "$tmp_out" "$tmp_err" 2>/dev/null || true
    
    return $status
}

# Run all tests
run_tests() {
    local failed=0
    
    # Check services
    log_info "----- Service Status Tests -----"
    if ! test_service_status; then
        ((failed++))
        # If service status failed, skip the system check which will likely fail too
        log_warn "Service status check failed, additional details skipped"
    else
        check_postgresql_status || ((failed++))
        check_pgbouncer_status || ((failed++))
    fi
    
    # Test connections
    log_info "----- Connection Tests -----"
    test_direct_connection || true  # Don't increment failure counter for this one
    test_pgbouncer_connection || ((failed++))
    test_database_connection || ((failed++))
    
    # Test with temporary user
    log_info "----- Temporary User Test -----"
    test_temp_user_connection || ((failed++))
    
    # Check configuration
    log_info "----- Configuration Tests -----"
    test_pgbouncer_auth || ((failed++))
    test_firewall_configuration || true  # Optional test
    
    # Summary
    if [ $failed -eq 0 ]; then
        log_section "ALL TESTS PASSED! PostgreSQL and pgbouncer are configured correctly."
    else
        log_section "$failed TEST(S) FAILED! See above for details."
    fi
    
    return $failed
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
    exit $?
fi 