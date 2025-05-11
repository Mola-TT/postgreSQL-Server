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

# Function to install packages with robust retry logic across different package managers
install_package_with_retry() {
  local packages="$1"
  local max_retries=${2:-5}
  local retry_wait=${3:-30}
  local retry_count=0
  local success=false
  local log_file="/tmp/pkg_install_$$.log"
  
  log_info "Installing package(s): $packages (with retry mechanism)"
  
  # Detect package manager
  if command_exists apt-get; then
    local pkg_manager="apt"
  elif command_exists yum; then
    local pkg_manager="yum"
  elif command_exists dnf; then
    local pkg_manager="dnf"
  elif command_exists zypper; then
    local pkg_manager="zypper"
  elif command_exists apk; then
    local pkg_manager="apk"
  else
    log_error "No supported package manager found"
    return 1
  fi
  
  log_debug "Using package manager: $pkg_manager"
  
  while [ $retry_count -lt $max_retries ] && [ "$success" = "false" ]; do
    # Clear log file
    > "$log_file"
    
    case $pkg_manager in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq $packages > "$log_file" 2>&1
        ;;
      yum)
        yum install -y $packages > "$log_file" 2>&1
        ;;
      dnf)
        dnf install -y $packages > "$log_file" 2>&1
        ;;
      zypper)
        zypper -n install $packages > "$log_file" 2>&1
        ;;
      apk)
        apk add $packages > "$log_file" 2>&1
        ;;
    esac
    
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
      success=true
      log_debug "Successfully installed package(s): $packages"
    else
      retry_count=$((retry_count + 1))
      
      # Check for common error patterns
      if grep -q -E "(Could not get lock|Another process is using|cannot acquire lock|is locked by another process)" "$log_file"; then
        log_warn "Package manager is locked. Retry $retry_count/$max_retries in $retry_wait seconds..."
      elif grep -q -E "(Failed to fetch|Connection failed|Could not connect|Connection timed out)" "$log_file"; then
        log_warn "Network issue detected. Retry $retry_count/$max_retries in $retry_wait seconds..."
      elif grep -q -E "(Hash Sum mismatch|GPG error|Signature verification failed)" "$log_file"; then
        log_warn "Repository issue detected. Retry $retry_count/$max_retries in $retry_wait seconds..."
      else
        log_warn "Package installation failed. Retry $retry_count/$max_retries in $retry_wait seconds..."
        # Log the first few lines of the error
        log_debug "Installation error details:"
        head -5 "$log_file" | while read -r line; do
          log_debug "  $line"
        done
      fi
      
      if [ $retry_count -lt $max_retries ]; then
        sleep $retry_wait
        
        # Try to fix common issues before retrying
        case $pkg_manager in
          apt)
            # Try to fix package manager locks
            pkill -9 apt-get 2>/dev/null || true
            pkill -9 dpkg 2>/dev/null || true
            rm -f /var/lib/dpkg/lock* 2>/dev/null || true
            rm -f /var/lib/apt/lists/lock* 2>/dev/null || true
            rm -f /var/cache/apt/archives/lock* 2>/dev/null || true
            dpkg --configure -a 2>/dev/null || true
            apt-get update -qq 2>/dev/null || true
            ;;
          yum|dnf)
            # Try to fix package manager locks
            pkill -9 yum 2>/dev/null || true
            pkill -9 dnf 2>/dev/null || true
            rm -f /var/run/yum.pid 2>/dev/null || true
            ;;
          zypper)
            # Try to fix package manager locks
            pkill -9 zypper 2>/dev/null || true
            rm -f /var/run/zypp.pid 2>/dev/null || true
            ;;
        esac
      else
        log_error "Maximum retries reached while trying to install $packages"
        log_error "Last few lines of error log:"
        tail -10 "$log_file" | while read -r line; do
          log_error "  $line"
        done
      fi
    fi
  done
  
  # Clean up log file
  [ -f "$log_file" ] && rm -f "$log_file"
  
  if [ "$success" = "true" ]; then
    log_info "Successfully installed package(s): $packages"
    return 0
  else
    return 1
  fi
}

# Export functions
export -f execute_silently
export -f clear_logs
export -f command_exists
export -f apt_install_with_retry
export -f apt_update_with_retry
export -f install_package_with_retry 