#!/bin/bash
# init.sh - PostgreSQL server initialization script
# Part of Milestone 1, 2, 3, 4, 5 & 6
# This script updates the Ubuntu server silently and sets up initial environment

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Setup directory
SETUP_DIR="$SCRIPT_DIR/setup"

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

# Note: Dynamic optimization and hardware change detector scripts are executed directly 
# in the main function, not sourced at the top level to avoid function name conflicts
# These scripts have overlapping function names for hardware detection and should not be sourced together

# Display init banner
display_banner() {
    echo "-----------------------------------------------"
    echo "PostgreSQL Server Initialization"
    echo "-----------------------------------------------"
    log_info "Starting initialization process"
}

# Find script in common locations
find_script() {
    local script_name="$1"
    local script_path=""
    local search_paths=(
        "$SETUP_DIR/$script_name"
        "$SCRIPT_DIR/setup/$script_name"
        "/root/postgreSQL-Server/setup/$script_name"
        "$(dirname "$SCRIPT_DIR")/setup/$script_name"
        "/home/*/postgreSQL-Server/setup/$script_name"
    )
    
    log_debug "Searching for $script_name in common locations..."
    
    for path in "${search_paths[@]}"; do
        if [ -f "$path" ]; then
            script_path="$path"
            log_info "Found $script_name at: $script_path"
            break
        fi
    done
    
    if [ -z "$script_path" ]; then
        log_error "Could not find $script_name. Searched in:"
        for path in "${search_paths[@]}"; do
            log_error "  - $path"
        done
        return 1
    fi
    
    echo "$script_path"
    return 0
}

# Execute a script with proper error handling
execute_script() {
    local script_path="$1"
    local script_args="$2"
    local success_var="$3"
    local script_name=$(basename "$script_path")
    
    # Check if script exists
    if [ ! -f "$script_path" ]; then
        # Try to find the script using find_script function
        script_path=$(find_script "$script_name") || {
            log_error "Could not find script: $script_name"
            if [ -n "$success_var" ]; then
                eval "$success_var=false"
            fi
            return 1
        }
    fi
    
    # Ensure script has execute permission
    chmod +x "$script_path" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_warn "Failed to set executable permission on $script_name. Will try with bash explicitly."
        # Try to execute with bash explicitly if we can't set execute permission
        if bash "$script_path" $script_args; then
            if [ -n "$success_var" ]; then
                eval "$success_var=true"
            fi
            return 0
        else
            log_error "$script_name encountered issues, but continuing with other setup steps"
            if [ -n "$success_var" ]; then
                eval "$success_var=false"
            fi
            return 1
        fi
    fi
    
    # Execute the script
    log_info "Executing $script_name..."
    if "$script_path" $script_args; then
        # Only set the success variable if one was provided
        if [ -n "$success_var" ]; then
            eval "$success_var=true"
        fi
        return 0
    else
        local exit_code=$?
        log_error "$script_name encountered issues (exit code: $exit_code), but continuing with other setup steps"
        if [ -n "$success_var" ]; then
            eval "$success_var=false"
        fi
        return 1
    fi
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

# Setup hardware change detection service
setup_hardware_change_detection() {
  log_info "Setting up hardware change detection service..."
  
  # Find the hardware change detector script
  local script_path
  script_path=$(find_script "hardware_change_detector.sh")
  
  if [ $? -eq 0 ] && [ -n "$script_path" ]; then
    log_info "Executing hardware_change_detector.sh..."
    bash "$script_path"
    hw_detector_success=$?
    return $hw_detector_success
  else
    log_error "hardware_change_detector.sh not found"
    return 1
  fi
}

# Setup backup configuration
setup_backup_configuration() {
  log_info "Setting up PostgreSQL backup configuration..."
  
  # Find the backup configuration script
  local script_path
  script_path=$(find_script "backup_config.sh")
  
  if [ $? -eq 0 ] && [ -n "$script_path" ]; then
    log_info "Executing backup_config.sh..."
    bash "$script_path"
    return $?
  else
    log_error "backup_config.sh not found"
    return 1
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
    local dynamic_opt_success=false
    local hw_detector_success=false
    
    # Setup PostgreSQL and pgbouncer
    log_info "Setting up PostgreSQL and pgbouncer..."
    if setup_postgresql; then
        pg_success=true
    else
        log_error "PostgreSQL setup encountered issues, but continuing with other setup steps"
    fi
    
    # Setup Nginx for subdomain mapping
    log_info "Setting up Nginx for subdomain mapping..."
    if setup_nginx; then
        nginx_success=true
    else
        log_error "Nginx setup encountered issues, but continuing with other setup steps"
    fi
    
    # Setup Netdata monitoring
    log_info "Setting up Netdata monitoring..."
    if setup_netdata; then
        netdata_success=true
    else
        log_error "Netdata setup encountered issues, but continuing with other setup steps"
    fi
    
    # Setup SSL certificate auto-renewal
    log_info "Setting up SSL certificate auto-renewal..."
    if setup_ssl_renewal; then
        ssl_renewal_success=true
    else
        log_error "SSL certificate auto-renewal setup encountered issues, but continuing"
    fi
    
    # Setup dynamic optimization
    if [ "${ENABLE_DYNAMIC_OPTIMIZATION:-true}" = true ]; then
        if command -v psql >/dev/null 2>&1; then
            log_info "Setting up dynamic PostgreSQL optimization..."
            # Execute dynamic_optimization.sh
            execute_script "$SCRIPT_DIR/setup/dynamic_optimization.sh" "" "dynamic_opt_success"
        else
            log_warn "PostgreSQL not installed, skipping dynamic optimization"
        fi
    else
        log_info "Dynamic optimization disabled (set ENABLE_DYNAMIC_OPTIMIZATION=true to enable)"
    fi
    
    # Setup hardware change detection
    setup_hardware_change_detection
    
    # Setup backup configuration
    setup_backup_configuration
    
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
    
    if [ "$dynamic_opt_success" = true ]; then
        log_info "✓ Dynamic optimization setup: SUCCESS"
    else
        log_error "✗ Dynamic optimization setup: FAILED"
    fi
    
    if [ "$hw_detector_success" = true ]; then
        log_info "✓ Hardware change detector setup: SUCCESS"
    else
        log_error "✗ Hardware change detector setup: FAILED"
    fi
    
    log_info "-----------------------------------------------"
    
    log_info "Initialization COMPLETE"
    echo ""
    
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