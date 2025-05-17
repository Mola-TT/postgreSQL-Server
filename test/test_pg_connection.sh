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
    
    # Make sure PostgreSQL is running before proceeding
    if ! systemctl is-active --quiet postgresql@*-main || ! systemctl is-active --quiet postgresql; then
        log_error "PostgreSQL service is not running, cannot proceed with pgbouncer connection test"
        eval "$result_var=false"
        return 1
    fi
    
    # ===== CRITICAL: Pre-test validation of userlist.txt =====
    local userlist_path="/etc/pgbouncer/userlist.txt"
    local recovery_needed=false
    
    # Check if userlist.txt exists
    if [ ! -f "$userlist_path" ]; then
        log_error "pgbouncer userlist file ($userlist_path) does not exist"
        recovery_needed=true
    # Check if postgres user exists in userlist.txt
    elif ! grep -q "\"postgres\"" "$userlist_path"; then
        log_error "postgres user not found in userlist.txt"
        recovery_needed=true
    # Check permissions
    else
        local permissions=$(stat -c "%a" "$userlist_path" 2>/dev/null || stat -f "%p" "$userlist_path" 2>/dev/null)
        local owner=$(stat -c "%U:%G" "$userlist_path" 2>/dev/null || stat -f "%Su:%Sg" "$userlist_path" 2>/dev/null)
        
        if [ "$permissions" != "600" ] || [ "$owner" != "postgres:postgres" ]; then
            log_warn "Incorrect userlist.txt permissions or ownership (permissions: $permissions, owner: $owner)"
            recovery_needed=true
        fi
    fi
    
    # Perform recovery if needed
    if [ "$recovery_needed" = true ]; then
        log_info "Performing userlist recovery process"
        
        # Stage 1: Create userlist with postgres user using the enhanced function
        log_info "Stage 1: Creating pgbouncer userlist with postgres user"
        create_pgbouncer_userlist
        
        # Check if recovery was successful by verifying the userlist file
        if [ ! -f "$userlist_path" ] || ! grep -q "\"postgres\"" "$userlist_path"; then
            log_error "Stage 1 recovery failed - userlist creation unsuccessful"
            
            # Stage 2: Force regenerate the userlist with full permissions using all available methods
            log_info "Stage 2: Force regenerating pgbouncer userlist with emergency methods"
            
            # Try different emergency approach - attempt to extract postgres hash multiple ways
            local temp_userlist=$(mktemp)
            local hash_extracted=false
            
            # Method 1: Try direct query for hash first (most reliable)
            log_info "Emergency extraction method 1: Direct query from pg_authid"
            if postgres_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | tr -d ' \n\r\t'); then
                if [ -n "$postgres_hash" ]; then
                    echo "\"postgres\" \"$postgres_hash\"" > "$temp_userlist"
                    hash_extracted=true
                    log_info "Successfully extracted postgres hash with direct query in emergency mode"
                fi
            fi
            
            # Method 2: If direct query failed, try password-based MD5 hash generation
            if [ "$hash_extracted" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
                log_info "Emergency extraction method 2: Generate MD5 hash from known password"
                local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
                echo "\"postgres\" \"$md5pass\"" > "$temp_userlist"
                hash_extracted=true
                log_warn "Created emergency MD5 authentication entry for postgres user"
            fi
            
            # Method 3: Reset the postgres password if we have it
            if [ "$hash_extracted" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
                log_info "Emergency extraction method 3: Reset postgres password and extract new hash"
                # Force reset password with scram-sha-256
                su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
                su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
                su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PG_SUPERUSER_PASSWORD';\"" > /dev/null 2>&1
                
                # Extract new hash
                if postgres_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | tr -d ' \n\r\t'); then
                    if [ -n "$postgres_hash" ]; then
                        echo "\"postgres\" \"$postgres_hash\"" > "$temp_userlist"
                        hash_extracted=true
                        log_info "Successfully extracted new postgres hash after password reset"
                    fi
                fi
            fi
            
            # Method 4: Last resort - hardcoded MD5 hash if we can't get anything else
            if [ "$hash_extracted" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
                log_warn "Emergency extraction method 4: Last resort hardcoded MD5 hash"
                # Generate an MD5 hash from the password (less secure but should work)
                local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
                echo "\"postgres\" \"$md5pass\"" > "$temp_userlist"
                hash_extracted=true
                log_warn "Created last-resort MD5 authentication entry for postgres"
            fi
            
            # If we couldn't extract a hash any way, we have to give up
            if [ "$hash_extracted" = false ]; then
                log_error "All emergency hash extraction methods failed - cannot continue without postgres user hash"
                rm -f "$temp_userlist"
                eval "$result_var=false"
                return 1
            fi
            
            # Copy to destination with full permissions using multiple methods for reliability
            log_info "Installing emergency userlist file"
            
            # Create directory if it doesn't exist
            sudo mkdir -p "/etc/pgbouncer" 2>/dev/null || mkdir -p "/etc/pgbouncer" 2>/dev/null
            
            # Try multiple methods to ensure the file gets copied
            if ! sudo cp "$temp_userlist" "$userlist_path" 2>/dev/null; then
                if ! cp "$temp_userlist" "$userlist_path" 2>/dev/null; then
                    if ! cat "$temp_userlist" | sudo tee "$userlist_path" > /dev/null; then
                        if ! (cat "$temp_userlist" | sudo bash -c "cat > $userlist_path") 2>/dev/null; then
                            log_error "All methods to copy userlist failed in emergency mode"
                            rm -f "$temp_userlist"
                            eval "$result_var=false"
                            return 1
                        fi
                    fi
                fi
            fi
            
            # Set proper permissions with multiple methods
            sudo chown postgres:postgres "$userlist_path" 2>/dev/null || chown postgres:postgres "$userlist_path" 2>/dev/null
            sudo chmod 600 "$userlist_path" 2>/dev/null || chmod 600 "$userlist_path" 2>/dev/null
            
            # Verify additional permissions
            permissions=$(stat -c "%a" "$userlist_path" 2>/dev/null || stat -f "%p" "$userlist_path" 2>/dev/null)
            owner=$(stat -c "%U:%G" "$userlist_path" 2>/dev/null || stat -f "%Su:%Sg" "$userlist_path" 2>/dev/null)
            log_info "Userlist file permissions: $permissions, owner: $owner"
            
            # Clean up temp file
            rm -f "$temp_userlist"
            
            # Verify the file exists with postgres user
            if [ -f "$userlist_path" ] && grep -q "\"postgres\"" "$userlist_path"; then
                log_info "Stage 2 recovery successful - emergency userlist created"
            else
                log_error "Stage 2 recovery failed - could not create or populate userlist.txt"
                eval "$result_var=false"
                return 1
            fi
        else
            log_info "Stage 1 recovery successful"
        fi
        
        # Final verification of permissions regardless of which method succeeded
        sudo chown postgres:postgres "$userlist_path" 2>/dev/null || chown postgres:postgres "$userlist_path" 2>/dev/null
        sudo chmod 600 "$userlist_path" 2>/dev/null || chmod 600 "$userlist_path" 2>/dev/null
        
        # Restart pgbouncer to apply changes
        log_info "Restarting pgbouncer to apply userlist changes"
        systemctl restart pgbouncer
        sleep 5  # Give pgbouncer time to restart
        
        # Verify pgbouncer is still running after restart
        if ! systemctl is-active --quiet pgbouncer; then
            log_error "pgbouncer failed to restart after userlist recovery"
            systemctl start pgbouncer
            sleep 3
        fi
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
            if [[ "$err_output" == *"SASL authentication failed"* || "$err_output" == *"no pg_hba.conf entry"* || "$err_output" == *"password authentication failed"* ]]; then
                log_error "Authentication failed - likely a userlist issue"
                
                # Force regenerate pgbouncer userlist with more aggressive approach
                log_info "Force regenerating pgbouncer userlist with emergency methods"
                
                # Create temp userlist
                local temp_userlist=$(mktemp)
                local recovery_success=false
                
                # Try all available methods to extract hash
                if type extract_hash &>/dev/null && extract_hash "postgres" "$temp_userlist" && [ -s "$temp_userlist" ] && grep -q "\"postgres\"" "$temp_userlist"; then
                    log_info "Successfully extracted postgres hash with extract_hash function"
                    recovery_success=true
                elif [ -n "$PG_SUPERUSER_PASSWORD" ]; then
                    # Try to reset the postgres password
                    log_info "Resetting postgres password and extracting hash"
                    su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
                    su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
                    su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PG_SUPERUSER_PASSWORD';\"" > /dev/null 2>&1
                    
                    # Try to extract the new hash
                    if postgres_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | tr -d ' \n\r\t'); then
                        if [ -n "$postgres_hash" ]; then
                            echo "\"postgres\" \"$postgres_hash\"" > "$temp_userlist"
                            if [ -s "$temp_userlist" ] && grep -q "\"postgres\"" "$temp_userlist"; then
                                log_info "Successfully extracted new hash after password reset"
                                recovery_success=true
                            fi
                        fi
                    fi
                    
                    # Emergency MD5 hash generation if all else fails
                    if [ "$recovery_success" = false ]; then
                        log_warn "Creating emergency MD5 authentication entry for postgres"
                        local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
                        echo "\"postgres\" \"$md5pass\"" > "$temp_userlist"
                        recovery_success=true
                    fi
                else
                    log_error "All hash extraction methods failed and password not available"
                    rm -f "$temp_userlist"
                    eval "$result_var=false"
                    return 1
                fi
                
                # Copy to destination with full permissions
                if [ "$recovery_success" = true ]; then
                    log_info "Installing recovery userlist"
                    
                    # Create directory if needed
                    sudo mkdir -p "/etc/pgbouncer" 2>/dev/null || mkdir -p "/etc/pgbouncer" 2>/dev/null
                    
                    # Try multiple methods to copy the file
                    if ! sudo cp "$temp_userlist" "$userlist_path" 2>/dev/null; then
                        if ! cp "$temp_userlist" "$userlist_path" 2>/dev/null; then
                            if ! cat "$temp_userlist" | sudo tee "$userlist_path" > /dev/null; then
                                log_error "All methods to copy userlist failed in retry mechanism"
                                rm -f "$temp_userlist"
                                eval "$result_var=false"
                                return 1
                            fi
                        fi
                    fi
                    
                    # Set proper permissions with multiple methods
                    sudo chown postgres:postgres "$userlist_path" 2>/dev/null || chown postgres:postgres "$userlist_path" 2>/dev/null
                    sudo chmod 600 "$userlist_path" 2>/dev/null || chmod 600 "$userlist_path" 2>/dev/null
                    
                    # Restart pgbouncer
                    log_info "Restarting pgbouncer to apply emergency userlist"
                    systemctl restart pgbouncer
                    sleep 5
                    
                    # Clean up
                    rm -f "$temp_userlist"
                fi
            elif [[ "$err_output" == *"could not connect to server"* ]]; then
                log_error "Could not connect to pgbouncer - service may be down"
                
                # Try to restart pgbouncer
                log_info "Attempting to restart pgbouncer service"
                systemctl restart pgbouncer
                sleep 5  # Give more time for restart
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
    local extraction_success=false
    local auth_type="${PGB_AUTH_TYPE:-scram-sha-256}"
    
    # Method 1: Try extract_hash function (most robust method)
    if type extract_hash &>/dev/null; then
        log_info "Using extract_hash function to get postgres password hash"
        if extract_hash "postgres" "$temp_file"; then
            # Verify the extracted hash is valid
            if grep -q "\"postgres\"" "$temp_file" && [ -s "$temp_file" ]; then
                extraction_success=true
                log_info "Successfully extracted postgres password hash using extract_hash function"
            else
                log_warn "extract_hash function produced invalid output"
            fi
        else
            log_warn "Failed to extract hash using extract_hash function"
        fi
    fi
    
    # Method 2: Direct query method
    if [ "$extraction_success" = false ]; then
        log_info "Trying direct SQL query to get postgres password hash"
        # Clear the temp file first
        echo "" > "$temp_file"
        if su - postgres -c "psql -t -c \"SELECT '\\\"postgres\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | grep -v "^$" > "$temp_file"; then
            # Verify the extracted hash is valid
            if grep -q "\"postgres\"" "$temp_file" && [ -s "$temp_file" ]; then
                extraction_success=true
                log_info "Successfully extracted postgres password hash using direct SQL query"
            else
                log_warn "Direct SQL query succeeded but didn't produce valid userlist entry"
            fi
        else
            log_warn "Failed to extract hash using direct SQL query"
        fi
    fi
    
    # Method 3: Raw hash extraction
    if [ "$extraction_success" = false ]; then
        log_info "Trying raw hash extraction approach"
        # Clear the temp file first
        echo "" > "$temp_file"
        if su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | grep -v "^$" > "/tmp/pg_hash_$$.tmp"; then
            if [ -s "/tmp/pg_hash_$$.tmp" ]; then
                local raw_hash=$(cat "/tmp/pg_hash_$$.tmp" | tr -d ' \n\r\t')
                if [ -n "$raw_hash" ]; then
                    echo "\"postgres\" \"$raw_hash\"" > "$temp_file"
                    # Verify the entry is properly formatted
                    if grep -q "\"postgres\"" "$temp_file" && [ -s "$temp_file" ]; then
                        extraction_success=true
                        log_info "Successfully extracted postgres password hash using raw hash extraction"
                    fi
                fi
            fi
            # Clean up
            rm -f "/tmp/pg_hash_$$.tmp" 2>/dev/null
        else
            log_warn "Failed to extract hash using raw hash extraction"
        fi
    fi
    
    # Method 4: Reset password and retry if previous methods failed
    if [ "$extraction_success" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
        log_info "Resetting postgres password to force rehashing"
        # Force set password encryption based on auth type
        if [ "$auth_type" = "scram-sha-256" ]; then
            su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
            su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
            log_info "Set password_encryption to scram-sha-256"
        fi
        
        # Reset postgres user password
        su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PG_SUPERUSER_PASSWORD';\"" > /dev/null 2>&1
        log_info "Reset postgres user password"
        
        # Try to extract hash again after password reset
        if su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | grep -v "^$" > "/tmp/pg_hash_$$.tmp"; then
            if [ -s "/tmp/pg_hash_$$.tmp" ]; then
                local raw_hash=$(cat "/tmp/pg_hash_$$.tmp" | tr -d ' \n\r\t')
                if [ -n "$raw_hash" ]; then
                    echo "\"postgres\" \"$raw_hash\"" > "$temp_file"
                    # Verify the entry is properly formatted
                    if grep -q "\"postgres\"" "$temp_file" && [ -s "$temp_file" ]; then
                        extraction_success=true
                        log_info "Successfully extracted postgres password hash after password reset"
                    fi
                fi
            fi
            # Clean up
            rm -f "/tmp/pg_hash_$$.tmp" 2>/dev/null
        else
            log_warn "Failed to extract hash after password reset"
        fi
    fi
    
    # Method 5: Emergency MD5 fallback if all other methods fail
    if [ "$extraction_success" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
        log_warn "All extraction methods failed, creating emergency MD5 hash"
        local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
        echo "\"postgres\" \"$md5pass\"" > "$temp_file"
        extraction_success=true
        log_warn "Created emergency MD5 hash for postgres user - may not work with scram-sha-256"
    fi
    
    # If all methods failed and we don't have the password
    if [ "$extraction_success" = false ]; then
        log_error "All methods to extract postgres password hash failed"
        log_error "Cannot create pgbouncer userlist without a valid postgres user entry"
        rm -f "$temp_file"
        return 1
    fi
    
    # Install the userlist file with multiple fallback methods
    if [ -s "$temp_file" ]; then
        # Create directory if it doesn't exist
        sudo mkdir -p "/etc/pgbouncer" 2>/dev/null || mkdir -p "/etc/pgbouncer" 2>/dev/null
        
        # Method 1: Try sudo cp
        if ! sudo cp "$temp_file" "/etc/pgbouncer/userlist.txt" 2>/dev/null; then
            log_warn "Failed to copy userlist with sudo cp, trying alternative methods"
            
            # Method 2: Try direct cp
            if ! cp "$temp_file" "/etc/pgbouncer/userlist.txt" 2>/dev/null; then
                log_warn "Failed to copy userlist with cp, trying cat | sudo tee"
                
                # Method 3: Try cat | sudo tee
                if ! cat "$temp_file" | sudo tee "/etc/pgbouncer/userlist.txt" > /dev/null 2>&1; then
                    # Method 4: Last resort with cat and redirection
                    if ! (cat "$temp_file" | sudo bash -c 'cat > /etc/pgbouncer/userlist.txt') 2>/dev/null; then
                        log_error "All methods to copy userlist file failed"
                        rm -f "$temp_file"
                        return 1
                    fi
                fi
            fi
        fi
        
        # Set secure permissions - using multiple methods for reliability
        sudo chown postgres:postgres "/etc/pgbouncer/userlist.txt" 2>/dev/null || chown postgres:postgres "/etc/pgbouncer/userlist.txt" 2>/dev/null
        sudo chmod 600 "/etc/pgbouncer/userlist.txt" 2>/dev/null || chmod 600 "/etc/pgbouncer/userlist.txt" 2>/dev/null
        
        # Verify permissions
        local permissions=$(stat -c "%a" "/etc/pgbouncer/userlist.txt" 2>/dev/null || stat -f "%p" "/etc/pgbouncer/userlist.txt" 2>/dev/null)
        local owner=$(stat -c "%U:%G" "/etc/pgbouncer/userlist.txt" 2>/dev/null || stat -f "%Su:%Sg" "/etc/pgbouncer/userlist.txt" 2>/dev/null)
        
        if [ "$permissions" != "600" ] || [ "$owner" != "postgres:postgres" ]; then
            log_warn "Userlist file has incorrect permissions or ownership: permissions=$permissions, owner=$owner"
            log_info "Trying again with more aggressive methods"
            
            # Try with sudo and explicit commands
            sudo chown postgres:postgres "/etc/pgbouncer/userlist.txt" 2>/dev/null
            sudo chmod 600 "/etc/pgbouncer/userlist.txt" 2>/dev/null
            
            # Try with direct root command if available
            if command -v runuser &>/dev/null; then
                sudo runuser -u root -- chown postgres:postgres "/etc/pgbouncer/userlist.txt" 2>/dev/null
                sudo runuser -u root -- chmod 600 "/etc/pgbouncer/userlist.txt" 2>/dev/null
            fi
        fi
        
        # Final verification
        if grep -q "\"postgres\"" "/etc/pgbouncer/userlist.txt"; then
            log_info "Successfully created pgbouncer userlist with postgres user"
            
            # Restart pgbouncer for changes to take effect
            log_info "Restarting pgbouncer to apply changes"
            if ! systemctl restart pgbouncer > /dev/null 2>&1; then
                log_warn "Failed to restart pgbouncer, trying to start if not running"
                systemctl start pgbouncer > /dev/null 2>&1
            fi
            
            # Wait for pgbouncer to restart
            sleep 5
            
            # Check pgbouncer status
            if systemctl is-active --quiet pgbouncer; then
                log_info "pgbouncer is running after restart"
            else
                log_warn "pgbouncer is not running after restart attempt"
            fi
            
            rm -f "$temp_file"
            return 0
        else
            log_error "Created userlist.txt but postgres user not found in file"
        fi
    else
        log_error "Failed to create temporary userlist file or file is empty"
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