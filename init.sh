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
    
    # Create a temporary file for logging
    local temp_log_file
    temp_log_file=$(mktemp 2>/dev/null || mktemp -t 'find_script_log')
    
    # Function to log to the temp file instead of stdout
    local_log() {
        local level="$1"
        local message="$2"
        echo "[$level] $message" >> "$temp_log_file"
    }
    
    local_log "DEBUG" "Searching for $script_name in common locations..."
    
    for path in "${search_paths[@]}"; do
        local_log "DEBUG" "Checking path: $path"
        if [ -f "$path" ] && [ -r "$path" ]; then
            script_path="$path"
            local_log "INFO" "Found $script_name at: $script_path"
            
            # Verify that the file is readable and not empty
            if [ ! -s "$script_path" ]; then
                local_log "WARN" "Found $script_name at $script_path but file is empty"
                continue
            fi
            
            # Quick check of file content - should be a bash script
            if ! head -n1 "$script_path" | grep -q "^#!" 2>/dev/null; then
                local_log "WARN" "Found $script_name at $script_path but it may not be a valid script (no shebang found)"
            fi
            
            break
        fi
    done
    
    if [ -z "$script_path" ]; then
        local_log "ERROR" "Could not find $script_name. Searched in:"
        for path in "${search_paths[@]}"; do
            local_log "ERROR" "  - $path"
            if [ -e "$path" ]; then
                if [ ! -f "$path" ]; then
                    local_log "ERROR" "     (exists but is not a regular file)"
                elif [ ! -r "$path" ]; then
                    local_log "ERROR" "     (exists but is not readable)"
                fi
            fi
        done
        
        # Output the logs to the main log
        cat "$temp_log_file" | while read line; do
            log_debug "$line"
        done
        
        # Clean up
        rm -f "$temp_log_file"
        return 1
    fi
    
    # Output the logs to the main log
    cat "$temp_log_file" | while read line; do
        log_debug "$line"
    done
    
    # Clean up
    rm -f "$temp_log_file"
    
    # Return the clean path without any log messages
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
        local found_path=""
        found_path=$(find_script "$script_name" 2>/dev/null)
        local find_result=$?
        
        if [ $find_result -ne 0 ] || [ -z "$found_path" ]; then
            log_error "Could not find script: $script_name"
            if [ -n "$success_var" ]; then
                eval "$success_var=false"
            fi
            return 1
        fi
        
        # Clean up any potential logging in the path (defensive measure)
        script_path=$(echo "$found_path" | grep -v '^\[' | tail -n 1)
        log_info "Using $script_name at: $script_path"
    fi
    
    # Double-check that the file actually exists and is readable
    if [ ! -f "$script_path" ]; then
        log_error "Script path $script_path does not exist or is not a regular file"
        if [ -n "$success_var" ]; then
            eval "$success_var=false"
        fi
        return 1
    fi
    
    if [ ! -r "$script_path" ]; then
        log_error "Script path $script_path is not readable"
        if [ -n "$success_var" ]; then
            eval "$success_var=false"
        fi
        return 1
    fi
    
    # Ensure script has execute permission
    chmod +x "$script_path" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_warn "Failed to set executable permission on $script_name. Will try with bash explicitly."
        # Try to execute with bash explicitly if we can't set execute permission
        log_info "Executing $script_name with bash explicitly..."
        if bash "$script_path" $script_args; then
            log_info "$script_name executed successfully"
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
    fi
    
    # Execute the script
    log_info "Executing $script_name..."
    if "$script_path" $script_args; then
        log_info "$script_name executed successfully"
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
    # Flush stdout to ensure immediate display
    sync
    
    # Set the explicit path to the test runner in the test directory
    local script_path="$SCRIPT_DIR/test/run_tests.sh"
    
    # Check if the file exists
    if [ ! -f "$script_path" ]; then
        log_error "Test runner not found at: $script_path"
        return 1
    fi
    
    log_info "Found test runner at: $script_path"
    
    # Make sure the test runner is executable
    chmod +x "$script_path" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_warn "Failed to set executable permission on test runner. Will try with bash explicitly."
    fi
    
    # Run the tests with proper terminal handling
    log_info "Executing test runner: $script_path"
    
    # Always use bash explicitly to avoid permission issues
    bash "$script_path"
    local exit_code=$?
    
    # Ensure final logs are displayed
    sync
    
    # Don't print "Tests executed successfully" here as it's already printed by run_tests.sh
    if [ $exit_code -ne 0 ]; then
        log_warn "Some tests failed with exit code $exit_code. Please check the logs for details."
    fi
    
    # Final flush of output
    sync
    return $exit_code
}

# Setup hardware change detection service
setup_hardware_change_detection() {
  log_info "Setting up hardware change detection service..."
  
  # Get the success variable name if provided
  local success_var="$1"
  
  # Find the hardware change detector script
  local script_path=""
  # Redirect find_script output to a variable to avoid log contamination
  script_path=$(find_script "hardware_change_detector.sh" 2>/dev/null)
  local find_result=$?
  
  # Verify the result
  if [ $find_result -ne 0 ] || [ -z "$script_path" ]; then
    log_error "Could not find hardware_change_detector.sh"
    # Update success variable if provided
    if [ -n "$success_var" ]; then
      eval "$success_var=false"
    fi
    return 1
  fi
  
  # Clean up any potential logging in the path (defensive measure)
  script_path=$(echo "$script_path" | grep -v '^\[' | tail -n 1)
  
  log_info "Using hardware_change_detector.sh at: $script_path"
  
  # Double-check that the file actually exists
  if [ ! -f "$script_path" ]; then
    log_error "Script path $script_path does not exist or is not a regular file"
    # Update success variable if provided
    if [ -n "$success_var" ]; then
      eval "$success_var=false"
    fi
    return 1
  fi
  
  if [ ! -r "$script_path" ]; then
    log_error "Script path $script_path is not readable"
    # Update success variable if provided
    if [ -n "$success_var" ]; then
      eval "$success_var=false"
    fi
    return 1
  fi
  
  # Ensure the script is executable
  chmod +x "$script_path" 2>/dev/null || log_warn "Failed to set executable permission, will use bash explicitly"
  
  log_info "Executing hardware_change_detector.sh..."
  # Use bash explicitly to execute the script with proper quoting to handle spaces in path
  bash "$script_path"
  local hw_detector_result=$?
  
  # Set the success variable based on result if provided
  if [ -n "$success_var" ]; then
    if [ $hw_detector_result -eq 0 ]; then
      eval "$success_var=true"
    else
      eval "$success_var=false"
    fi
  fi
  
  if [ $hw_detector_result -eq 0 ]; then
    log_info "Hardware change detector setup completed successfully"
  else
    log_error "Hardware change detector setup failed with exit code $hw_detector_result"
  fi
  
  return $hw_detector_result
}

# Setup backup configuration
setup_backup_configuration() {
  log_info "Setting up PostgreSQL backup configuration..."
  
  # Find the backup configuration script
  local script_path=""
  # Redirect find_script output to a variable to avoid log contamination
  script_path=$(find_script "backup_config.sh" 2>/dev/null)
  local find_result=$?
  
  # Verify the result
  if [ $find_result -ne 0 ] || [ -z "$script_path" ]; then
    log_error "Could not find backup_config.sh"
    return 1
  fi
  
  # Clean up any potential logging in the path (defensive measure)
  script_path=$(echo "$script_path" | grep -v '^\[' | tail -n 1)
  
  log_info "Using backup_config.sh at: $script_path"
  
  # Double-check that the file actually exists
  if [ ! -f "$script_path" ]; then
    log_error "Script path $script_path does not exist or is not a regular file"
    return 1
  fi
  
  if [ ! -r "$script_path" ]; then
    log_error "Script path $script_path is not readable"
    return 1
  fi
  
  # Ensure the script is executable
  chmod +x "$script_path" 2>/dev/null || log_warn "Failed to set executable permission, will use bash explicitly"
  
  log_info "Executing backup_config.sh..."
  # Use bash explicitly to execute the script with proper quoting to handle spaces in path
  bash "$script_path"
  local result=$?
  
  if [ $result -eq 0 ]; then
    log_info "Backup configuration completed successfully"
  else
    log_error "Backup configuration failed with exit code $result"
  fi
  
  return $result
}

# Setup PostgreSQL user monitor
setup_pg_user_monitor() {
  log_info "Setting up PostgreSQL user monitor..."
  
  # Check if monitoring is enabled
  if [ "${PG_USER_MONITOR_ENABLED:-true}" != "true" ]; then
    log_info "PostgreSQL user monitor is disabled (PG_USER_MONITOR_ENABLED != true)"
    return 0
  fi
  
  # Find the PostgreSQL user monitor script
  local script_path=""
  # Redirect find_script output to a variable to avoid log contamination
  script_path=$(find_script "pg_user_monitor.sh" 2>/dev/null)
  local find_result=$?
  
  # Verify the result
  if [ $find_result -ne 0 ] || [ -z "$script_path" ]; then
    log_error "Could not find pg_user_monitor.sh"
    return 1
  fi
  
  # Clean up any potential logging in the path (defensive measure)
  script_path=$(echo "$script_path" | grep -v '^\[' | tail -n 1)
  
  log_info "Using pg_user_monitor.sh at: $script_path"
  
  # Double-check that the file actually exists
  if [ ! -f "$script_path" ]; then
    log_error "Script path $script_path does not exist or is not a regular file"
    return 1
  fi
  
  if [ ! -r "$script_path" ]; then
    log_error "Script path $script_path is not readable"
    return 1
  fi
  
  # Ensure the script is executable
  chmod +x "$script_path" 2>/dev/null || log_warn "Failed to set executable permission, will use bash explicitly"
  
  log_info "Executing pg_user_monitor.sh..."
  # Use bash explicitly to execute the script with proper quoting to handle spaces in path
  bash "$script_path" setup
  local result=$?
  
  if [ $result -eq 0 ]; then
    log_info "PostgreSQL user monitor setup completed successfully"
  else
    log_error "PostgreSQL user monitor setup failed with exit code $result"
  fi
  
  return $result
}

# Setup disaster recovery system
setup_disaster_recovery() {
  log_info "Setting up disaster recovery system..."
  
  # Find the disaster recovery script
  local script_path=""
  script_path=$(find_script "disaster_recovery.sh" 2>/dev/null)
  local find_result=$?
  
  if [ $find_result -ne 0 ] || [ -z "$script_path" ]; then
    log_error "Could not find disaster_recovery.sh"
    return 1
  fi
  
  # Clean up any potential logging in the path
  script_path=$(echo "$script_path" | grep -v '^\[' | tail -n 1)
  log_info "Using disaster_recovery.sh at: $script_path"
  
  if [ ! -f "$script_path" ]; then
    log_error "Script path $script_path does not exist"
    return 1
  fi
  
  if [ ! -r "$script_path" ]; then
    log_error "Script path $script_path is not readable"
    return 1
  fi
  
  # Ensure the script is executable
  chmod +x "$script_path" 2>/dev/null || log_warn "Failed to set executable permission, will use bash explicitly"
  
  log_info "Executing disaster_recovery.sh setup..."
  # Use bash explicitly to execute the script
  bash "$script_path" setup
  local result=$?
  
  if [ $result -eq 0 ]; then
    log_info "Disaster recovery system setup completed successfully"
  else
    log_error "Disaster recovery system setup failed with exit code $result"
  fi
  
  return $result
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
    local backup_success=false
    local pg_user_monitor_success=false
    
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
    setup_hardware_change_detection "hw_detector_success"
    
    # Setup backup configuration
    if setup_backup_configuration; then
        backup_success=true
    else
        log_error "Backup configuration setup encountered issues, but continuing"
    fi
    
    # Setup PostgreSQL user monitor (only if PostgreSQL is running)
    if [ "$pg_success" = true ] && command -v psql >/dev/null 2>&1; then
        if setup_pg_user_monitor; then
            pg_user_monitor_success=true
        else
            log_error "PostgreSQL user monitor setup encountered issues, but continuing"
        fi
    else
        log_info "Skipping PostgreSQL user monitor setup (PostgreSQL not available)"
    fi
    
    # Setup disaster recovery system
    local disaster_recovery_success=false
    if [ "${DISASTER_RECOVERY_ENABLED:-true}" = true ]; then
        log_info "Setting up disaster recovery system..."
        if setup_disaster_recovery; then
            disaster_recovery_success=true
        else
            log_error "Disaster recovery setup encountered issues, but continuing"
        fi
    else
        log_info "Disaster recovery disabled (set DISASTER_RECOVERY_ENABLED=true to enable)"
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
    
    if [ "$backup_success" = true ]; then
        log_info "✓ Backup configuration setup: SUCCESS"
    else
        log_error "✗ Backup configuration setup: FAILED"
    fi
    
    if [ "$pg_user_monitor_success" = true ]; then
        log_info "✓ PostgreSQL user monitor setup: SUCCESS"
    else
        log_error "✗ PostgreSQL user monitor setup: FAILED"
    fi
    
    if [ "$disaster_recovery_success" = true ]; then
        log_info "✓ Disaster recovery setup: SUCCESS"
    else
        log_error "✗ Disaster recovery setup: FAILED"
    fi
    
    log_info "-----------------------------------------------"
    
    log_info "Initialization COMPLETE"
    echo ""
    
    # Run tests if enabled
    if [ "${RUN_TESTS:-true}" = true ]; then
        run_tests
    else
        log_info "Tests skipped (RUN_TESTS is set to false)"
    fi
    
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        log_debug "For detailed logs, check: $LOG_FILE"
    fi
}

# Execute main function
main "$@" 