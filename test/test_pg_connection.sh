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

log_info "Starting PostgreSQL connection tests..."

# Test function to check if PostgreSQL is running
check_postgresql_status() {
    log_info "Checking if PostgreSQL service is running..."
    if systemctl is-active --quiet postgresql; then
        log_info "✅ PostgreSQL service is running"
        return 0
    else
        log_error "❌ PostgreSQL service is NOT running"
        return 1
    fi
}

# Test function to check if pgbouncer is running
check_pgbouncer_status() {
    log_info "Checking if pgbouncer service is running..."
    if systemctl is-active --quiet pgbouncer; then
        log_info "✅ pgbouncer service is running"
        return 0
    else
        log_error "❌ pgbouncer service is NOT running"
        return 1
    fi
}

# Test direct connection to PostgreSQL
test_direct_connection() {
    log_info "Testing direct connection to PostgreSQL on port ${DB_PORT}..."
    
    if PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${DB_PORT}" -U postgres -c "SELECT version();" 2>/dev/null; then
        log_info "✅ Successfully connected to PostgreSQL directly"
        return 0
    else
        log_warn "❌ Failed to connect to PostgreSQL directly"
        log_warn "This is expected if firewall rules are blocking direct access"
        return 1
    fi
}

# Test connection through pgbouncer
test_pgbouncer_connection() {
    log_info "Testing connection through pgbouncer on port ${PGB_LISTEN_PORT}..."
    
    if PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -c "SELECT version();" 2>/dev/null; then
        log_info "✅ Successfully connected to PostgreSQL through pgbouncer"
        return 0
    else
        log_error "❌ Failed to connect through pgbouncer"
        log_error "This indicates a potential configuration issue with pgbouncer"
        return 1
    fi
}

# Test connection to specific database if configured
test_database_connection() {
    if [ "$DB_NAME" != "postgres" ]; then
        log_info "Testing connection to database '${DB_NAME}'..."
        
        if PGPASSWORD="${PG_SUPERUSER_PASSWORD}" psql -h localhost -p "${PGB_LISTEN_PORT}" -U postgres -d "${DB_NAME}" -c "SELECT current_database();" 2>/dev/null; then
            log_info "✅ Successfully connected to database '${DB_NAME}'"
            return 0
        else
            log_error "❌ Failed to connect to database '${DB_NAME}'"
            return 1
        fi
    else
        log_info "No custom database configured, skipping database-specific test"
        return 0
    fi
}

# Test pgbouncer authentication file
test_pgbouncer_auth() {
    log_info "Checking pgbouncer authentication file..."
    
    if [ ! -f "/etc/pgbouncer/userlist.txt" ]; then
        log_error "❌ pgbouncer authentication file not found"
        return 1
    fi
    
    # Check permissions (should be 640 or 600)
    permissions=$(stat -c "%a" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%p" /etc/pgbouncer/userlist.txt 2>/dev/null)
    
    if [[ "$permissions" == "640" || "$permissions" == "600" ]]; then
        log_info "✅ pgbouncer authentication file has correct permissions: $permissions"
    else
        log_warn "⚠️ pgbouncer authentication file has unusual permissions: $permissions (expected 640 or 600)"
    fi
    
    # Check ownership
    owner=$(stat -c "%U:%G" /etc/pgbouncer/userlist.txt 2>/dev/null || stat -f "%Su:%Sg" /etc/pgbouncer/userlist.txt 2>/dev/null)
    
    if [[ "$owner" == "postgres:postgres" ]]; then
        log_info "✅ pgbouncer authentication file has correct ownership: $owner"
        return 0
    else
        log_warn "⚠️ pgbouncer authentication file has unusual ownership: $owner (expected postgres:postgres)"
        return 1
    fi
}

# Check if firewall is configured as expected
test_firewall_configuration() {
    if [ "$ENABLE_FIREWALL" = true ]; then
        log_info "Checking firewall configuration..."
        
        if command -v ufw >/dev/null 2>&1; then
            ufw_status=$(ufw status | grep -i active)
            
            if [ -n "$ufw_status" ]; then
                log_info "✅ Firewall is active"
                
                # Check pgbouncer port
                pgb_port_open=$(ufw status | grep "${PGB_LISTEN_PORT}")
                if [ -n "$pgb_port_open" ]; then
                    log_info "✅ Firewall allows connections to pgbouncer port ${PGB_LISTEN_PORT}"
                else
                    log_warn "⚠️ Firewall might be blocking pgbouncer port ${PGB_LISTEN_PORT}"
                fi
                
                # Check PostgreSQL direct port
                pg_port_blocked=$(ufw status | grep "${DB_PORT}" | grep -i deny)
                if [ -n "$pg_port_blocked" ]; then
                    log_info "✅ Firewall correctly blocks direct PostgreSQL port ${DB_PORT}"
                else
                    log_warn "⚠️ Firewall might not be blocking PostgreSQL port ${DB_PORT}"
                fi
                
                return 0
            else
                log_warn "⚠️ Firewall is installed but not active"
                return 1
            fi
        else
            log_error "❌ ufw firewall not installed"
            return 1
        fi
    else
        log_info "Firewall test skipped (ENABLE_FIREWALL=false)"
        return 0
    fi
}

# Run all tests
run_tests() {
    local failed=0
    
    # Check services
    check_postgresql_status || ((failed++))
    check_pgbouncer_status || ((failed++))
    
    # Test connections
    test_direct_connection || true  # Don't increment failure counter for this one
    test_pgbouncer_connection || ((failed++))
    test_database_connection || ((failed++))
    
    # Check configuration
    test_pgbouncer_auth || ((failed++))
    test_firewall_configuration || true  # Optional test
    
    # Summary
    if [ $failed -eq 0 ]; then
        log_info "=============================================="
        log_info "🎉 All critical tests passed! PostgreSQL and pgbouncer appear to be configured correctly."
        log_info "=============================================="
    else
        log_error "=============================================="
        log_error "❌ $failed test(s) failed. Please check the logs above for details."
        log_error "=============================================="
    fi
    
    return $failed
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
    exit $?
fi 