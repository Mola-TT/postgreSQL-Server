#!/bin/bash
# utilities.sh - Utility functions for PostgreSQL server initialization
# Part of Milestone 1

# Create system log file if it doesn't exist
SYSTEM_LOG_FILE="${SYSTEM_LOG_FILE:-/var/log/pg_system_init.log}"
touch "$SYSTEM_LOG_FILE" 2>/dev/null || true

# Function to execute system commands silently
# Only debug logs and errors are displayed, all other output is redirected to log file
execute_silently() {
    local cmd="$1"
    local msg="$2"
    local err_msg="$3"
    
    log_debug "Executing: $cmd"
    
    # Execute command, redirect stdout to log file, redirect stderr to variable
    if ! output=$(eval "$cmd" >> "$SYSTEM_LOG_FILE" 2>&1); then
        log_error "$err_msg"
        log_debug "Command failed with output: $output"
        return 1
    fi
    
    if [ -n "$msg" ]; then
        log_info "$msg"
    fi
    
    return 0
}

# Function to clear log files
clear_logs() {
    if [ -f "$SYSTEM_LOG_FILE" ]; then
        > "$SYSTEM_LOG_FILE"
        log_debug "System log file cleared: $SYSTEM_LOG_FILE"
    fi

    if [ -f "$LOG_FILE" ]; then
        > "$LOG_FILE"
        log_debug "Log file cleared: $LOG_FILE"
    fi
}

# Function to verify if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Export functions
export -f execute_silently
export -f clear_logs
export -f command_exists 