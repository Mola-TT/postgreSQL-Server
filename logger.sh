#!/bin/bash

# logger.sh - Logging utility for PostgreSQL server initialization
# Part of Milestone 1

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# Default log level (can be overridden in environment files)
CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# Log colors
COLOR_RESET='\033[0m'
COLOR_DEBUG='\033[0;36m'   # Cyan
COLOR_INFO='\033[0;32m'    # Green
COLOR_WARN='\033[0;33m'    # Yellow
COLOR_ERROR='\033[0;31m'   # Red

# Get timestamp
get_timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

# Log a message with specific level
log() {
  local level=$1
  local color=$2
  local message=$3
  local timestamp=$(get_timestamp)
  
  if [ $level -ge $CURRENT_LOG_LEVEL ]; then
    echo -e "${color}[$(get_timestamp)] [${level}] ${message}${COLOR_RESET}"
  fi
  
  # Also write to log file if specified
  if [ ! -z "$LOG_FILE" ]; then
    echo "[$(get_timestamp)] [${level}] ${message}" >> "$LOG_FILE"
  fi
}

# Helper functions for different log levels
log_debug() {
  log $LOG_LEVEL_DEBUG "$COLOR_DEBUG" "DEBUG: $1"
}

log_info() {
  log $LOG_LEVEL_INFO "$COLOR_INFO" "INFO: $1"
}

log_warn() {
  log $LOG_LEVEL_WARN "$COLOR_WARN" "WARNING: $1"
}

log_error() {
  log $LOG_LEVEL_ERROR "$COLOR_ERROR" "ERROR: $1"
}

# Export functions
export -f log_debug
export -f log_info
export -f log_warn
export -f log_error 