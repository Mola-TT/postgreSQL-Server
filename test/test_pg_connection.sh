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

# Add the log_warning function (missing in the code)
log_warning() {
    log "WARNING" "$1"
}

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
    # Try with connection string format
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql "host=localhost port=${DB_PORT} dbname=postgres user=postgres sslmode=prefer" -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            log_status_pass "Connected to PostgreSQL directly on port ${DB_PORT}"
            return 0
        else
            log_status_fail "Unexpected output from PostgreSQL direct connection"
            return 1
        fi
    else
        log_status_warn "Failed to connect to PostgreSQL directly on port ${DB_PORT}"
        return 1
    fi
}

# Test connection through pgbouncer
test_pgbouncer_connection() {
    local db_name="$1"
    local result_var="$2"
    local host="${3:-localhost}"
    
    # If no database name is provided, use postgres as default
    if [ -z "$db_name" ]; then
        db_name="postgres"
    fi
    
    # Log the connection details for debugging
    log_info "Attempting to connect to PostgreSQL through pgbouncer: host=$host port=$PGB_LISTEN_PORT dbname=$db_name user=postgres"
    
    # Check if pgbouncer is running first
    if ! systemctl is-active --quiet pgbouncer; then
        log_error "pgbouncer service is not running, attempting to start"
        systemctl start pgbouncer
        sleep 5  # Give pgbouncer time to start
        
        # Check again
        if ! systemctl is-active --quiet pgbouncer; then
            log_error "Failed to start pgbouncer service"
            eval "$result_var=false"
            return 1
        else
            log_info "Successfully started pgbouncer service"
        fi
    fi
    
    # Check userlist.txt file which is essential for pgbouncer authentication
    local userlist_path="/etc/pgbouncer/userlist.txt"
    if [ ! -f "$userlist_path" ]; then
        log_error "pgbouncer userlist file ($userlist_path) does not exist"
        log_info "Creating new userlist file with postgres user"
        
        # Create userlist.txt with postgres user
        create_pgbouncer_userlist
        
        # Check if file was created
        if [ ! -f "$userlist_path" ]; then
            log_error "Failed to create pgbouncer userlist file"
            eval "$result_var=false"
            return 1
        fi
    fi
    
    # Check if postgres user exists in userlist.txt
    if ! grep -q "\"postgres\"" "$userlist_path"; then
        log_error "postgres user not found in userlist.txt"
        log_info "Adding postgres user to userlist.txt"
        
        # Add postgres user to userlist.txt
        create_pgbouncer_userlist
        
        # Check if postgres user was added
        if ! grep -q "\"postgres\"" "$userlist_path"; then
            log_error "Failed to add postgres user to userlist.txt"
            eval "$result_var=false"
            return 1
        fi
    fi
    
    # Verify userlist file permissions (should be 600 for security)
    local permissions=$(stat -c "%a" "$userlist_path" 2>/dev/null || stat -f "%p" "$userlist_path" 2>/dev/null)
    local owner=$(stat -c "%U:%G" "$userlist_path" 2>/dev/null || stat -f "%Su:%Sg" "$userlist_path" 2>/dev/null)
    
    if [ "$permissions" != "600" ] || [ "$owner" != "postgres:postgres" ]; then
        log_warn "Incorrect userlist.txt permissions or ownership (permissions: $permissions, owner: $owner)"
        log_info "Fixing permissions and ownership"
        
        execute_silently "sudo chown postgres:postgres $userlist_path" \
            "Fixed userlist.txt ownership" \
            "Failed to fix userlist.txt ownership"
            
        execute_silently "sudo chmod 600 $userlist_path" \
            "Fixed userlist.txt permissions" \
            "Failed to fix userlist.txt permissions"
    fi
    
    # Try connecting multiple times, with retries
    local max_attempts=3
    local attempt=1
    local success=false
    
    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log_info "Connection attempt $attempt of $max_attempts"
        
        # Try with explicit SSL configuration to connect through pgbouncer
        local connection_string="host=$host port=$PGB_LISTEN_PORT dbname=$db_name user=postgres sslmode=require"
        local query="SELECT version();"
        local output
        
        if output=$(PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql "$connection_string" -c "$query" -t 2>&1); then
            log_info "✓ PASS: Connected to PostgreSQL through pgbouncer on port $PGB_LISTEN_PORT to database '$db_name'"
            log_info "PostgreSQL version: $(echo "$output" | head -1 | tr -d '\n\r')"
            success=true
        else
            local err_output="$output"
            log_warning "Failed to connect to PostgreSQL through pgbouncer: $err_output"
            
            # Check for specific error messages and take appropriate action
            if [[ "$err_output" == *"SASL authentication failed"* ]]; then
                log_error "SASL authentication failed - likely a userlist issue"
                
                # Force regenerate pgbouncer userlist
                log_info "Force regenerating pgbouncer userlist"
                create_pgbouncer_userlist
                
                # Restart pgbouncer to apply new userlist
                log_info "Restarting pgbouncer to apply new userlist"
                execute_silently "sudo systemctl restart pgbouncer" \
                    "Restarted pgbouncer service" \
                    "Failed to restart pgbouncer service"
                
                # Wait for pgbouncer to restart
                sleep 5
            elif [[ "$err_output" == *"could not connect to server"* ]]; then
                log_error "Could not connect to pgbouncer - service may be down"
                
                # Try to restart pgbouncer
                log_info "Attempting to restart pgbouncer service"
                execute_silently "sudo systemctl restart pgbouncer" \
                    "Restarted pgbouncer service" \
                    "Failed to restart pgbouncer service"
                
                # Wait for pgbouncer to restart
                sleep 5
            fi
            
            attempt=$((attempt+1))
            
            if [ $attempt -le $max_attempts ]; then
                log_info "Retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
    
    # Set the result value based on connection success
    if [ "$success" = true ]; then
        eval "$result_var=true"
        return 0
    else
        eval "$result_var=false"
        return 1
    fi
}

# Helper function to create pgbouncer userlist
create_pgbouncer_userlist() {
    log_info "Creating pgbouncer userlist with postgres user"
    
    # Get postgres password hash
    local temp_file=$(mktemp)
    local pg_password_hash
    
    # Method 1: Try to get hash directly from pg_authid
    pg_password_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | tr -d ' \n\r\t')
    
    if [ -n "$pg_password_hash" ]; then
        echo "\"postgres\" \"$pg_password_hash\"" > "$temp_file"
        log_info "Successfully extracted postgres password hash"
    else
        # Method 2: If hash extraction fails, try using direct password if available
        if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
            # Force set password encryption to scram-sha-256
            su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
            su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
            
            # Reset postgres user password to force rehashing
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PG_SUPERUSER_PASSWORD';\"" > /dev/null 2>&1
            
            # Try to get hash again
            pg_password_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | tr -d ' \n\r\t')
            
            if [ -n "$pg_password_hash" ]; then
                echo "\"postgres\" \"$pg_password_hash\"" > "$temp_file"
                log_info "Successfully extracted postgres password hash after password reset"
            else
                log_error "Failed to extract password hash even after password reset"
                
                # Method 3: Last resort - create MD5 hash directly
                log_info "Creating emergency MD5 hash for pgbouncer authentication"
                local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
                echo "\"postgres\" \"$md5pass\"" > "$temp_file"
                log_warn "Created emergency MD5 hash for postgres user - may not work with scram-sha-256"
            fi
        else
            log_error "Cannot create pgbouncer userlist: No password hash and PG_SUPERUSER_PASSWORD not set"
            rm -f "$temp_file"
            return 1
        fi
    fi
    
    # Install the userlist file
    if [ -s "$temp_file" ]; then
        # Create directory if it doesn't exist
        sudo mkdir -p "/etc/pgbouncer" 2>/dev/null
        
        # Copy the userlist file
        if ! sudo cp "$temp_file" "/etc/pgbouncer/userlist.txt" 2>/dev/null; then
            log_error "Failed to copy userlist file"
            
            # Try alternate method
            cat "$temp_file" | sudo tee "/etc/pgbouncer/userlist.txt" > /dev/null
        fi
        
        # Set proper permissions
        sudo chown postgres:postgres "/etc/pgbouncer/userlist.txt" 2>/dev/null
        sudo chmod 600 "/etc/pgbouncer/userlist.txt" 2>/dev/null
        
        # Verify file was created with postgres user
        if grep -q "\"postgres\"" "/etc/pgbouncer/userlist.txt"; then
            log_info "Successfully created pgbouncer userlist with postgres user"
            
            # Restart pgbouncer to apply changes
            log_info "Restarting pgbouncer to apply new userlist"
            if ! sudo systemctl restart pgbouncer > /dev/null 2>&1; then
                log_warn "Failed to restart pgbouncer, trying to start if not running"
                sudo systemctl start pgbouncer > /dev/null 2>&1
            fi
            
            # Wait for pgbouncer to restart
            sleep 5
            
            rm -f "$temp_file"
            return 0
        else
            log_error "Created userlist.txt but postgres user not found in file"
        fi
    else
        log_error "Failed to create temporary userlist file"
    fi
    
    rm -f "$temp_file"
    return 1
}

# Test connection to specific database if configured
test_database_connection() {
    if [ -z "$DB_NAME" ] || [ "$DB_NAME" = "postgres" ]; then
        log_info "Database name is postgres or not set, skipping specific database connection test"
        return 0
    fi
    
    # Try with consistent connection string format
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql "host=localhost port=${PGB_LISTEN_PORT} dbname=${DB_NAME} user=postgres sslmode=require" -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            log_status_pass "Connected to database '${DB_NAME}'"
            return 0
        else
            log_status_fail "Unexpected output from database connection: $output"
            return 1
        fi
    else
        log_status_fail "Failed to connect to database '${DB_NAME}'"
        return 1
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
            
        # Use the extract_hash function if available
        if type extract_hash &>/dev/null; then
            # Create a temporary file for the hash
            temp_hash_file=$(mktemp)
            
            # Extract the hash for the temp user
            if extract_hash "$temp_user" "$temp_hash_file"; then
                # Append the hash to pgbouncer's userlist.txt
                execute_silently "cat $temp_hash_file | sudo tee -a /etc/pgbouncer/userlist.txt > /dev/null" \
                    "" \
                    "Failed to append hash to pgbouncer authentication file"
                rm -f "$temp_hash_file"
                
                # Fix file ownership and permissions after modification
                execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
                execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
            else
                log_warn "Failed to extract hash for temporary user, falling back to direct append"
                # Fall back to direct extraction and append
                execute_silently "su - postgres -c \"psql -t -c \\\"SELECT '\\\\\\\"$temp_user\\\\\\\" \\\\\\\"' || rolpassword || '\\\\\\\"' FROM pg_authid WHERE rolname='$temp_user'\\\" | sudo tee -a /etc/pgbouncer/userlist.txt > /dev/null\"" \
                    "" \
                    "Failed to add temporary user to pgbouncer authentication file"
                
                # Fix file ownership and permissions after modification
                execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
                execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
            fi
        else
            # Direct extraction and append if extract_hash function is not available
            execute_silently "su - postgres -c \"psql -t -c \\\"SELECT '\\\\\\\"$temp_user\\\\\\\" \\\\\\\"' || rolpassword || '\\\\\\\"' FROM pg_authid WHERE rolname='$temp_user'\\\" | sudo tee -a /etc/pgbouncer/userlist.txt > /dev/null\"" \
                "" \
                "Failed to add temporary user to pgbouncer authentication file"
            
            # Fix file ownership and permissions after modification
            execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
            execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
        fi
    fi
    
    # Reload pgbouncer to apply changes
    execute_silently "sudo systemctl reload pgbouncer || sudo systemctl restart pgbouncer" \
        "Reloaded pgbouncer with temporary user" \
        "Failed to reload pgbouncer"
    
    # Test direct connection with temp user
    if output=$(PGPASSWORD="$temp_password" psql "host=localhost port=${DB_PORT} dbname=postgres user=${temp_user} sslmode=prefer" -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
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
    
    # Test pgbouncer connection with temp user
    if output=$(PGPASSWORD="$temp_password" psql "host=localhost port=${PGB_LISTEN_PORT} dbname=postgres user=${temp_user} sslmode=require" -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
        if [[ "$output" == *"temp_user_connected"* ]]; then
            log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user"
            pgbouncer_success=true
        else
            log_status_warn "Unexpected output from temporary user pgbouncer connection"
            pgbouncer_success=false
        fi
    else
        log_status_fail "Failed to connect through pgbouncer with temporary user"
        pgbouncer_success=false
    fi
    
    # Clean up pgbouncer userlist.txt
    log_info "Cleaning up: Removing temporary user from pgbouncer authentication file"
    execute_silently "grep -v \"\\\"$temp_user\\\"\" /etc/pgbouncer/userlist.txt | sudo tee /etc/pgbouncer/userlist.txt.new > /dev/null && sudo mv /etc/pgbouncer/userlist.txt.new /etc/pgbouncer/userlist.txt" \
        "" \
        "Failed to remove temporary user from pgbouncer authentication file" || log_warn "Could not clean up pgbouncer authentication file"
    
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
    local db_connection_result=false
    
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
    
    # Use postgres as the database name if DB_NAME is not set
    local test_db_name="${DB_NAME:-postgres}"
    test_pgbouncer_connection "$test_db_name" db_connection_result || ((failed++))
    
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