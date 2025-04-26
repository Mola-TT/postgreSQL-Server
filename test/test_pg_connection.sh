#!/bin/bash
# test_pg_connection.sh - Test script for PostgreSQL and pgbouncer connections
# Part of Milestone 2

# Find the script directory and import essentials
SCRIPT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/tools/logger.sh"
source "$SCRIPT_DIR/tools/utilities.sh"

# Load default environment variables
source "$SCRIPT_DIR/default.env"

# Override with user environment if available
if [ -f "$SCRIPT_DIR/user.env" ]; then
    source "$SCRIPT_DIR/user.env"
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

log_section "POSTGRESQL CONNECTION TEST RESULTS"

# Test function to check if PostgreSQL is running
check_postgresql_status() {
    if systemctl is-active --quiet postgresql; then
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
        return 1
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
    
    # Create a temporary user
    if ! execute_silently "su - postgres -c \"psql -c \\\"CREATE USER $temp_user WITH PASSWORD '$temp_password';\\\"\"" \
        "" \
        "Failed to create temporary test user"; then
        log_status_fail "Could not create temporary test user"
        return 1
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
    if output=$(PGPASSWORD="$temp_password" psql -h localhost -p "${PGB_LISTEN_PORT}" -U "$temp_user" -d postgres -c "SELECT 'temp_user_connected' as result;" -t 2>/dev/null); then
        if [[ "$output" == *"temp_user_connected"* ]]; then
            log_status_pass "Connected to PostgreSQL through pgbouncer with temporary user"
            pgbouncer_success=true
        else
            log_status_fail "Unexpected output from temporary user pgbouncer connection"
            pgbouncer_success=false
        fi
    else
        log_status_fail "Failed to connect through pgbouncer with temporary user"
        pgbouncer_success=false
    fi
    
    # Drop the temporary user
    log_info "Cleaning up: Removing temporary test user"
    execute_silently "su - postgres -c \"psql -c \\\"DROP USER IF EXISTS $temp_user;\\\"\"" \
        "" \
        "Failed to remove temporary test user" || log_warn "Could not remove temporary test user, manual cleanup needed"
    
    # Return success or failure
    if [ "$pgbouncer_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Run all tests
run_tests() {
    local failed=0
    
    # Check services
    log_info "----- Service Status Tests -----"
    check_postgresql_status || ((failed++))
    check_pgbouncer_status || ((failed++))
    
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