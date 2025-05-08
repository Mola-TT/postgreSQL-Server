#!/bin/bash
# utilities.sh - Utility functions for PostgreSQL server initialization
# Part of Milestone 1

# Create log file if it doesn't exist
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="/var/log/server_init.log"
    log_warn "LOG_FILE not defined in environment, using default: $LOG_FILE"
fi

touch "$LOG_FILE" 2>/dev/null || true

# Function to execute system commands silently
# Only debug logs and errors are displayed, all other output is redirected to log file
execute_silently() {
    local cmd="$1"
    local msg="$2"
    local err_msg="$3"
    
    log_debug "Executing: $cmd"
    
    # Execute command, redirect stdout to log file, redirect stderr to variable
    if ! output=$(eval "$cmd" >> "$LOG_FILE" 2>&1); then
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
    if [ -f "$LOG_FILE" ]; then
        > "$LOG_FILE"
        log_debug "Log file cleared: $LOG_FILE"
    fi
}

# Function to verify if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install packages with retry logic for apt lock issues
apt_install_with_retry() {
  local packages="$1"
  local max_retries=${2:-5}
  local retry_wait=${3:-30}
  local log_file="/tmp/apt_install_$$.log"
  local retry_count=0
  local success=false
  local silent=${4:-true}
  
  while [ $retry_count -lt $max_retries ] && [ "$success" = "false" ]; do
    if [ "$silent" = "true" ]; then
      export DEBIAN_FRONTEND=noninteractive
      if apt-get install -y -qq $packages > "$log_file" 2>&1; then
        success=true
      else
        # Check if failure was due to lock
        if grep -q "Could not get lock" "$log_file" || grep -q "Another process is using the Debian packaging system database" "$log_file"; then
          retry_count=$((retry_count + 1))
          if [ $retry_count -lt $max_retries ]; then
            log_warn "Another package manager process is running. Retry $retry_count/$max_retries in $retry_wait seconds..."
            sleep $retry_wait
          else
            log_error "Maximum retries reached while trying to install $packages"
            cat "$log_file" | head -10 | while read -r line; do
              log_error "  $line"
            done
          fi
        else
          # Some other error
          log_error "Failed to install $packages, unrelated to locks"
          cat "$log_file" | head -10 | while read -r line; do
            log_error "  $line"
          done
          break
        fi
      fi
    else
      # Non-silent mode
      if apt-get install -y $packages; then
        success=true
      else
        # Check if failure was due to lock
        last_exit=$?
        apt-get install -y $packages 2>&1 | grep -q "Could not get lock"
        if [ $? -eq 0 ] || [ $last_exit -eq 100 ]; then
          retry_count=$((retry_count + 1))
          if [ $retry_count -lt $max_retries ]; then
            log_warn "Another package manager process is running. Retry $retry_count/$max_retries in $retry_wait seconds..."
            sleep $retry_wait
          else
            log_error "Maximum retries reached while trying to install $packages"
          fi
        else
          # Some other error
          log_error "Failed to install $packages, unrelated to locks"
          break
        fi
      fi
    fi
  done
  
  [ -f "$log_file" ] && rm -f "$log_file"
  
  if [ "$success" = "true" ]; then
    return 0
  else
    return 1
  fi
}

# Function to update package lists with retry logic
apt_update_with_retry() {
  local max_retries=${1:-5}
  local retry_wait=${2:-30}
  local log_file="/tmp/apt_update_$$.log"
  local retry_count=0
  local success=false
  
  while [ $retry_count -lt $max_retries ] && [ "$success" = "false" ]; do
    if apt-get update -qq > "$log_file" 2>&1; then
      success=true
    else
      # Check if failure was due to lock
      if grep -q "Could not get lock" "$log_file" || grep -q "Another process is using the Debian packaging system database" "$log_file"; then
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
          log_warn "Another package manager process is running. Retry $retry_count/$max_retries in $retry_wait seconds..."
          sleep $retry_wait
        else
          log_error "Maximum retries reached while trying to update package lists"
          cat "$log_file" | head -10 | while read -r line; do
            log_error "  $line"
          done
        fi
      else
        # Some other error
        log_error "Failed to update package lists, unrelated to locks"
        cat "$log_file" | head -10 | while read -r line; do
          log_error "  $line"
        done
        break
      fi
    fi
  done
  
  [ -f "$log_file" ] && rm -f "$log_file"
  
  if [ "$success" = "true" ]; then
    return 0
  else
    return 1
  fi
}

# Export functions
export -f execute_silently
export -f clear_logs
export -f command_exists 