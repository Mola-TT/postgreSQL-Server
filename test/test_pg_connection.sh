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
    # Test first with postgres database explicitly, using SSL mode that works with pgbouncer
    # Use IPv4 (127.0.0.1) to ensure consistent behavior and environment variables for SSL
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" PGSSLMODE=require PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} (SSL required)"
            return 0
        else
            log_status_fail "Unexpected output from pgbouncer connection"
            return 1
        fi
    else
        log_warn "Failed to connect through pgbouncer with SSL required. Trying other SSL modes..."
        
        # Try with SSL prefer mode
        if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" PGSSLMODE=prefer PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
            if [[ "$output" == *"1"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} (SSL prefer)"
                return 0
            fi
        fi
        
        # Try with SSL allow mode
        if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" PGSSLMODE=allow PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
            if [[ "$output" == *"1"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} (SSL allow)"
                return 0
            fi
        fi
        
        # Try without SSL as last resort
        if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" PGSSLMODE=disable psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
            if [[ "$output" == *"1"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} (SSL disabled)"
                return 0
            fi
        fi
        
        # Try one more attempt with the user-specified database using SSL
        if [ "$DB_NAME" != "postgres" ]; then
            log_warn "Trying to connect with user-specified database: ${DB_NAME}"
            if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" PGSSLMODE=require PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U postgres -d "${DB_NAME}" -c "SELECT 1 as connected;" -t 2>/dev/null); then
                if [[ "$output" == *"1"* ]]; then
                    log_status_pass "Connected to PostgreSQL through pgbouncer on port ${PGB_LISTEN_PORT} using ${DB_NAME} database (SSL required)"
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

    # Temporarily stop pg_user_monitor to prevent interference during the test
    local monitor_was_running=false
    if systemctl is-active --quiet pg-user-monitor 2>/dev/null; then
        monitor_was_running=true
        log_info "Temporarily stopping pg_user_monitor service to prevent interference during test"
        execute_silently "sudo systemctl stop pg-user-monitor" \
            "Stopped pg_user_monitor service" \
            "Failed to stop pg_user_monitor service"
    fi
    
    # Extract password hash and add to userlist manually for testing
    log_info "Adding temporary user to pgbouncer userlist for testing..."
    local password_hash
    password_hash=$(su - postgres -c "psql -t -A -c \"SELECT rolpassword FROM pg_authid WHERE rolname='$temp_user';\"" 2>/dev/null | tr -d '\n\r')
    
    if [ -n "$password_hash" ] && [[ "$password_hash" == SCRAM-SHA-256* ]]; then
        # Remove any existing entries for this user first
        execute_silently "sudo sed -i '/\"'$temp_user'\"/d' /etc/pgbouncer/userlist.txt" \
            "" \
            "Failed to clean existing userlist entries"
        
        # Add user to userlist
        printf '"%s" "%s"\n' "$temp_user" "$password_hash" | sudo tee -a /etc/pgbouncer/userlist.txt > /dev/null
        execute_silently "sudo chown postgres:postgres /etc/pgbouncer/userlist.txt" "" "Failed to fix ownership"
        execute_silently "sudo chmod 600 /etc/pgbouncer/userlist.txt" "" "Failed to fix permissions"
        
        # Reload pgbouncer to apply the userlist changes
        execute_silently "sudo systemctl reload pgbouncer" \
            "Reloaded pgbouncer with temporary user" \
            "Failed to reload pgbouncer"
        
        # Wait for pgbouncer to process the userlist changes
        log_info "Waiting for pgbouncer to process userlist changes..."
        sleep 3
        
        # Debug: Show what's actually in the userlist for the temporary user
        log_info "Debug: Checking userlist entry for temporary user..."
        if sudo grep -q "\"$temp_user\"" /etc/pgbouncer/userlist.txt 2>/dev/null; then
            temp_user_line=$(sudo grep "\"$temp_user\"" /etc/pgbouncer/userlist.txt 2>/dev/null || echo "Not found")
            log_info "Debug: Temporary user userlist entry: $temp_user_line"
            
            # Also check what PostgreSQL has for this user
            pg_hash=$(su - postgres -c "psql -t -A -c \"SELECT rolpassword FROM pg_authid WHERE rolname='$temp_user';\"" 2>/dev/null | tr -d '\n\r' || echo "Not found")
            log_info "Debug: PostgreSQL password hash for temp user: $pg_hash"
            
            # Compare with postgres user entry for reference
            postgres_user_line=$(sudo grep "\"postgres\"" /etc/pgbouncer/userlist.txt 2>/dev/null || echo "Not found")
            log_info "Debug: postgres user userlist entry: $postgres_user_line"
        else
            log_warn "Debug: Temporary user not found in userlist file"
        fi
    else
        log_warn "Could not extract valid password hash for temporary user: $password_hash"
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
    
    # Try connecting through pgbouncer with the temporary user
    # Use the same approach that works for the postgres user
    log_info "Testing pgbouncer connection with temporary user: $temp_user"
    
    local pgbouncer_success=false
    
    # First determine which SSL mode works by trying the same sequence as the postgres user test
    # Try SSL required first with IPv4 (127.0.0.1) - this is what works for postgres user
    # Use PGSSLMODE environment variable instead of --set parameters for better compatibility
    if output=$(PGPASSWORD="$temp_password" PGSSLMODE=require PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
        if [[ "$output" == *"temp_user_connected"* ]]; then
            log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (SSL required)"
            pgbouncer_success=true
        else
            log_status_fail "Unexpected output from temporary user pgbouncer connection: $output"
            pgbouncer_success=false
        fi
    else
        # If SSL required fails, show the error and try other SSL modes
        error_output=$(PGPASSWORD="$temp_password" PGSSLMODE=require PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>&1 || true)
        log_warn "SSL required connection failed: $error_output"
        
        # Try with SSL prefer mode (use 127.0.0.1 for consistency)
        if output=$(PGPASSWORD="$temp_password" PGSSLMODE=prefer PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
            if [[ "$output" == *"temp_user_connected"* ]]; then
                log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (SSL prefer)"
                pgbouncer_success=true
            else
                log_status_fail "Unexpected output from temporary user pgbouncer connection (SSL prefer): $output"
                pgbouncer_success=false
            fi
        else
            # Show the error for SSL prefer mode
            prefer_error=$(PGPASSWORD="$temp_password" PGSSLMODE=prefer PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>&1 || true)
            log_warn "SSL prefer connection failed: $prefer_error"
            
            # Try with SSL allow mode (use 127.0.0.1 for consistency)
            if output=$(PGPASSWORD="$temp_password" PGSSLMODE=allow PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
                if [[ "$output" == *"temp_user_connected"* ]]; then
                    log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (SSL allow)"
                    pgbouncer_success=true
                else
                    log_status_fail "Unexpected output from temporary user pgbouncer connection (SSL allow): $output"
                    pgbouncer_success=false
                fi
            else
                # Show the error for SSL allow mode
                allow_error=$(PGPASSWORD="$temp_password" PGSSLMODE=allow PGSSLCERT="" PGSSLKEY="" PGSSLROOTCERT="" psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>&1 || true)
                log_warn "SSL allow connection failed: $allow_error"
                
                # Try without SSL as last resort (use 127.0.0.1 for consistency)
                if output=$(PGPASSWORD="$temp_password" PGSSLMODE=disable psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
                    if [[ "$output" == *"temp_user_connected"* ]]; then
                        log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user (SSL disabled)"
                        pgbouncer_success=true
                    else
                        log_status_fail "Unexpected output from temporary user pgbouncer connection (SSL disabled): $output"
                        pgbouncer_success=false
                    fi
                else
                    # Show the error for SSL disabled mode
                    disable_error=$(PGPASSWORD="$temp_password" PGSSLMODE=disable psql -h 127.0.0.1 -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>&1 || true)
                    log_warn "SSL disabled connection failed: $disable_error"
                    log_status_fail "Failed to connect through pgbouncer with temporary user with all SSL modes"
                    pgbouncer_success=false
                fi
            fi
        fi
    fi
    
    # Clean up: Remove temporary user from userlist and PostgreSQL
    log_info "Cleaning up: Removing temporary test user"
    
    # Remove from userlist
    execute_silently "sudo sed -i '/\"'$temp_user'\"/d' /etc/pgbouncer/userlist.txt" \
        "" \
        "Failed to remove temporary user from userlist"
    
    # Reload pgbouncer to apply userlist changes
    execute_silently "sudo systemctl reload pgbouncer" \
        "" \
        "Failed to reload pgbouncer after cleanup"
    
    # Drop the temporary user from PostgreSQL
    execute_silently "su - postgres -c \"psql -c \\\"DROP USER IF EXISTS $temp_user;\\\"\" > /dev/null 2>&1" \
        "" \
        "Failed to remove temporary test user" || log_warn "Could not remove temporary test user, manual cleanup needed"
    
    # Restart pg_user_monitor service if it was running before
    if [ "$monitor_was_running" = true ]; then
        log_info "Restarting pg_user_monitor service"
        execute_silently "sudo systemctl start pg-user-monitor" \
            "Restarted pg_user_monitor service" \
            "Failed to restart pg_user_monitor service"
    fi
    
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