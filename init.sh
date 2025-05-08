#!/bin/bash
# init.sh - PostgreSQL server initialization script
# Part of Milestone 1, 2, 3, 4 & 5
# This script updates the Ubuntu server silently and sets up initial environment

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logger
source "$SCRIPT_DIR/lib/logger.sh"

# Load default environment variables
source "$SCRIPT_DIR/conf/default.env"

# Source utilities
source "$SCRIPT_DIR/lib/utilities.sh"

# Source general configuration
source "$SCRIPT_DIR/setup/general_config.sh"

# Source PostgreSQL configuration
source "$SCRIPT_DIR/setup/postgresql_config.sh"

# Source Nginx configuration
source "$SCRIPT_DIR/setup/nginx_config.sh"

# Source Netdata configuration
source "$SCRIPT_DIR/setup/netdata_config.sh"

# Source SSL Renewal configuration
source "$SCRIPT_DIR/setup/ssl_renewal.sh"


# Display init banner
display_banner() {
    echo "-----------------------------------------------"
    echo "PostgreSQL Server Initialization"
    echo "-----------------------------------------------"
    log_info "Starting initialization process"
}

# Run tests after setup
run_tests() {
    log_info "Running test suite..."
    
    # Check multiple potential locations for the test runner
    local test_script=""
    local possible_locations=(
        "$SCRIPT_DIR/test/run_tests.sh"
        "/home/tom/postgreSQL-Server/test/run_tests.sh"
        "$(dirname "$SCRIPT_DIR")/test/run_tests.sh"
    )
    
    # Find the first existing test script
    for location in "${possible_locations[@]}"; do
        if [ -f "$location" ]; then
            test_script="$location"
            log_info "Found test script at: $test_script"
            break
        fi
    done
    
    if [ -z "$test_script" ]; then
        log_error "Could not find test script. Checked locations:"
        for location in "${possible_locations[@]}"; do
            log_error "  - $location"
        done
        return 1
    fi
    
    # Make sure the test runner is executable
    chmod +x "$test_script" 2>/dev/null || log_warn "Failed to set executable permission on test script"
    
    # Run the tests
    if "$test_script"; then
        : # Do not print 'All tests passed successfully!' here, let the test runner handle it
    else
        log_warn "Some tests failed. Please check the logs for details."
    fi
}

# Main function
main() {
    display_banner

    # Set timezone first
    set_timezone
    log_info "Set system timezone to ${SERVER_TIMEZONE:-UTC}"
    
    
    # Load user environment variables if they exist (overrides defaults)
    if [ -f "$SCRIPT_DIR/conf/user.env" ]; then
        log_info "Loading user environment variables from conf/user.env"
        source "$SCRIPT_DIR/conf/user.env"
    else
        log_info "No user.env file found. Use default settings"
        log_info "You can create user.env by copying conf/user.env.template and modifying it"
    fi

    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    log_debug "Log file: $LOG_FILE"
    
    # Update system packages
    update_system
    
    # Track installation status
    local pg_success=false
    local nginx_success=false
    local netdata_success=false
    local ssl_renewal_success=false
    
    # Setup PostgreSQL and pgbouncer
    log_info "Setting up PostgreSQL and pgbouncer..."
    if setup_postgresql; then
        log_info "PostgreSQL setup completed successfully"
        pg_success=true
    else
        log_error "PostgreSQL setup encountered issues, but continuing with other setup steps"
    fi
    
    # Setup Nginx for subdomain mapping
    log_info "Setting up Nginx for subdomain mapping..."
    if setup_nginx; then
        log_info "Nginx setup completed successfully"
        nginx_success=true
    else
        log_error "Nginx setup encountered issues, but continuing with other setup steps"
    fi
    
    # Setup Netdata monitoring
    log_info "Setting up Netdata monitoring..."
    if setup_netdata; then
        log_info "Netdata setup completed successfully"
        netdata_success=true
    else
        log_error "Netdata setup encountered issues, but continuing with other setup steps"
    fi
    
    # Setup SSL certificate auto-renewal
    log_info "Setting up SSL certificate auto-renewal..."
    if setup_ssl_renewal; then
        log_info "SSL certificate auto-renewal setup completed successfully"
        ssl_renewal_success=true
    else
        log_error "SSL certificate auto-renewal setup encountered issues, but continuing"
    fi
    
    # Print setup summary
    log_info "-----------------------------------------------"
    log_info "SETUP SUMMARY"
    log_info "-----------------------------------------------"
    
    if [ "$pg_success" = true ]; then
        log_info "✓ PostgreSQL setup: SUCCESS"
    else
        log_error "✗ PostgreSQL setup: FAILED"
    fi
    
    if [ "$nginx_success" = true ]; then
        log_info "✓ Nginx setup: SUCCESS"
    else
        log_error "✗ Nginx setup: FAILED"
    fi
    
    if [ "$netdata_success" = true ]; then
        log_info "✓ Netdata setup: SUCCESS"
    else
        log_error "✗ Netdata setup: FAILED"
    fi
    
    if [ "$ssl_renewal_success" = true ]; then
        log_info "✓ SSL renewal setup: SUCCESS"
    else
        log_error "✗ SSL renewal setup: FAILED"
    fi
    
    log_info "-----------------------------------------------"
    
    log_info "Initialization complete"
    
    # Run tests if enabled
    if [ "${RUN_TESTS:-false}" = true ]; then
        run_tests
    else
        log_info "Tests skipped (set RUN_TESTS=true to run tests)"
    fi
    
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        log_debug "For detailed logs, check: $LOG_FILE"
    fi
}

# Execute main function
main "$@" 