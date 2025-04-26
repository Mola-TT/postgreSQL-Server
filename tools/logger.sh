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

# Text formatting
BOLD='\033[1m'
COLOR_WHITE='\033[0;37m'   # White text for messages
COLOR_RESET='\033[0m'

# Log level colors
COLOR_DEBUG='\033[0;36m'   # Cyan
COLOR_INFO='\033[0;32m'    # Green
COLOR_WARN='\033[0;33m'    # Yellow
COLOR_ERROR='\033[0;31m'   # Red

# Log level padding - ensures consistent spacing after level text
# "DEBUG" = 5 chars, "INFO" = 4 chars, "WARNING" = 7 chars, "ERROR" = 5 chars
DEBUG_PAD=""          # 0 padding needed (5 chars)
INFO_PAD=" "          # 1 padding needed (4 + 1 = 5)
WARN_PAD=""           # 0 padding needed ("WARNING" = 7 chars, which is longest)
ERROR_PAD="  "        # 2 padding needed (5 + 2 = 7)

# Get timestamp
get_timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

# Log a message with specific level
log() {
  local level=$1
  local level_color=$2
  local level_text=$3
  local level_pad=$4
  local message=$5
  local timestamp=$(get_timestamp)
  
  if [ $level -ge $CURRENT_LOG_LEVEL ]; then
    # Format: [BOLD timestamp] {COLORED level_text} WHITE message
    # The level_pad ensures all messages start at the same position
    echo -e "${COLOR_WHITE}${BOLD}[${timestamp}]${COLOR_RESET}${COLOR_WHITE} {${level_color}${level_text}${level_pad}${COLOR_WHITE}} ${message}${COLOR_RESET}"
  fi
  
  # Also write to log file if specified
  if [ ! -z "$LOG_FILE" ]; then
    # For log files, use consistent padding too
    echo "[${timestamp}] {${level_text}${level_pad}} ${message}" >> "$LOG_FILE"
  fi
}

# Helper functions for different log levels
log_debug() {
  log $LOG_LEVEL_DEBUG "$COLOR_DEBUG" "DEBUG" "$DEBUG_PAD" "$1"
}

log_info() {
  log $LOG_LEVEL_INFO "$COLOR_INFO" "INFO" "$INFO_PAD" "$1"
}

log_warn() {
  log $LOG_LEVEL_WARN "$COLOR_WARN" "WARNING" "$WARN_PAD" "$1"
}

log_error() {
  log $LOG_LEVEL_ERROR "$COLOR_ERROR" "ERROR" "$ERROR_PAD" "$1"
}

# Export functions
export -f log_debug
export -f log_info
export -f log_warn
export -f log_error 