#!/bin/bash
# test_pg_connection.sh - Test script for PostgreSQL and pgbouncer connections
# Part of Milestone 2

# Find the script directory and import essentials
SCRIPT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/tools/logger.sh"

# Load default environment variables
source "$SCRIPT_DIR/default.env"

# Override with user environment if available
if [ -f "$SCRIPT_DIR/user.env" ]; then
    source "$SCRIPT_DIR/user.env"
fi

# Set color codes for output
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

# Status indicators
PASS="${COLOR_GREEN}✓ PASS${COLOR_RESET}"
FAIL="${COLOR_RED}✗ FAIL${COLOR_RESET}"
WARN="${COLOR_YELLOW}! WARN${COLOR_RESET}"

log_info "Starting PostgreSQL connection tests..."
echo "=============================================="
echo "POSTGRESQL CONNECTION TEST RESULTS"
echo "=============================================="

# Test function to check if PostgreSQL is running
check_postgresql_status() {
    echo -n "PostgreSQL Service Status: "
    if systemctl is-active --quiet postgresql; then
        echo -e "$PASS"
        return 0
    else
        echo -e "$FAIL"
        log_error "PostgreSQL service is NOT running"
        return 1
    fi
}

# Test function to check if pgbouncer is running
check_pgbouncer_status() {
    echo -n "pgbouncer Service Status: "
    if systemctl is-active --quiet pgbouncer; then
        echo -e "$PASS"
        return 0
    else
        echo -e "$FAIL"
        log_error "pgbouncer service is NOT running"
        return 1
    fi
}

# Test direct connection to PostgreSQL
test_direct_connection() {
    echo -n "Direct PostgreSQL Connection (port ${DB_PORT}): "
    
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${DB_PORT}" -U postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            echo -e "$PASS"
            return 0
        else
            echo -e "$FAIL"
            log_error "Unexpected output from PostgreSQL"
            return 1
        fi
    else
        echo -e "$WARN (expected if firewall blocks direct access)"
        return 1
    fi
}

# Test connection through pgbouncer
test_pgbouncer_connection() {
    echo -n "pgbouncer Connection (port ${PGB_LISTEN_PORT}): "
    
    if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -c "SELECT 1 as connected;" -t 2>/dev/null); then
        if [[ "$output" == *"1"* ]]; then
            echo -e "$PASS"
            return 0
        else
            echo -e "$FAIL"
            log_error "Unexpected output from pgbouncer connection"
            return 1
        fi
    else
        echo -e "$FAIL"
        log_error "Failed to connect through pgbouncer"
        return 1
    fi
}

# Test connection to specific database if configured
test_database_connection() {
    if [ "$DB_NAME" != "postgres" ]; then
        echo -n "Database '${DB_NAME}' Connection: "
        
        if output=$(PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d "${DB_NAME}" -c "SELECT 1 as connected;" -t 2>/dev/null); then
            if [[ "$output" == *"1"* ]]; then
                echo -e "$PASS"
                return 0
            else
                echo -e "$FAIL"
                log_error "Unexpected output from database connection"
                return 1
            fi
        else
            echo -e "$FAIL"
            log_error "Failed to connect to database '${DB_NAME}'"
            return 1
        fi
    else
        echo "Database Test: SKIPPED (using default postgres database)"
        return 0
    fi
}

# Test pgbouncer authentication file
test_pgbouncer_auth() {
    echo -n "pgbouncer Authentication File: "
    
    if [ ! -f "/etc/pgbouncer/userlist.txt" ]; then
        echo -e "$FAIL"
        log_error "Authentication file not found"
        return 1
    fi
    
    # Check permissions (should be 640 or 600)
    permissions=$(stat -c "%a" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%p" /etc/pgbouncer/userlist.txt 2>/dev/null)
    
    # Check ownership
    owner=$(stat -c "%U:%G" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%Su:%Sg" /etc/pgbouncer/userlist.txt 2>/dev/null)
    
    if [[ ("$permissions" == "640" || "$permissions" == "600") && "$owner" == "postgres:postgres" ]]; then
        echo -e "$PASS"
        return 0
    else
        echo -e "$WARN (permissions: $permissions, owner: $owner)"
        log_warn "Expected permissions 640/600 and owner postgres:postgres"
        return 1
    fi
}

# Check if firewall is configured as expected
test_firewall_configuration() {
    if [ "$ENABLE_FIREWALL" = true ]; then
        echo -n "Firewall Configuration: "
        
        if ! command -v ufw >/dev/null 2>&1; then
            echo -e "$FAIL (ufw not installed)"
            return 1
        fi
        
        ufw_status=$(ufw status | grep -i active)
        if [ -z "$ufw_status" ]; then
            echo -e "$WARN (not active)"
            return 1
        fi
        
        # Check pgbouncer port
        pgb_port_open=$(ufw status | grep "${PGB_LISTEN_PORT}")
        # Check PostgreSQL direct port
        pg_port_blocked=$(ufw status | grep "${DB_PORT}" | grep -i deny)
        
        if [ -n "$pgb_port_open" ] && [ -n "$pg_port_blocked" ]; then
            echo -e "$PASS"
            return 0
        else
            echo -e "$WARN (ports may not be configured correctly)"
            return 1
        fi
    else
        echo "Firewall Test: SKIPPED (ENABLE_FIREWALL=false)"
        return 0
    fi
}

# Run all tests
run_tests() {
    local failed=0
    
    # Check services
    check_postgresql_status || ((failed++))
    check_pgbouncer_status || ((failed++))
    
    echo "----------------------------------------------"
    
    # Test connections
    test_direct_connection || true  # Don't increment failure counter for this one
    test_pgbouncer_connection || ((failed++))
    test_database_connection || ((failed++))
    
    echo "----------------------------------------------"
    
    # Check configuration
    test_pgbouncer_auth || ((failed++))
    test_firewall_configuration || true  # Optional test
    
    echo "=============================================="
    # Summary
    if [ $failed -eq 0 ]; then
        echo -e "${COLOR_GREEN}ALL TESTS PASSED!${COLOR_RESET}"
        echo "PostgreSQL and pgbouncer are configured correctly."
    else
        echo -e "${COLOR_RED}${failed} TEST(S) FAILED!${COLOR_RESET}"
        echo "See above for specific test results."
    fi
    echo "=============================================="
    
    return $failed
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
    exit $?
fi 