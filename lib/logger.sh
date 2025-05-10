#!/bin/bash
# logger.sh - Logging utility functions
# Part of Milestone 1

# Set default log level to INFO if not already set
LOG_LEVEL=${LOG_LEVEL:-INFO}

# Set default log file if not already set
LOG_FILE=${LOG_FILE:-/var/log/server_init.log}

# ANSI color codes
RESET='\033[0m'
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'

# Log level values for comparison
declare -A LOG_LEVELS
LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# Logging function with timestamp and level
log() {
  local level=$1
  local message=$2
  local level_color=""
  
  # Set color based on log level
  case $level in
    DEBUG)   level_color="${CYAN}" ;;
    INFO)    level_color="${GREEN}" ;;
    WARNING) level_color="${YELLOW}" ;;
    ERROR)   level_color="${RED}" ;;
    *)       level_color="${WHITE}" ;;
  esac
  
  # Only log if the level is greater than or equal to the configured log level
  if [[ ${LOG_LEVELS[$level]} -ge ${LOG_LEVELS[$LOG_LEVEL]} ]]; then
    # Format: [TIMESTAMP] [LEVEL] message
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Print to console with colors
    echo -e "[${BOLD}${timestamp}${RESET}] [${level_color}${level}${RESET}] ${WHITE}${message}${RESET}"
    
    # Write to log file without colors
    echo "[${timestamp}] [${level}] ${message}" >> ${LOG_FILE}
  fi
}

# Convenience functions for each log level
log_debug() {
  log "DEBUG" "$1"
}

log_info() {
  log "INFO" "$1"
}

log_warn() {
  log "WARNING" "$1"
}

log_error() {
  log "ERROR" "$1"
}

log_pass() {
  # Green color for PASS
  local GREEN="\033[1;32m"
  local NC="\033[0m"
  local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${timestamp} [${GREEN}PASS${NC}] $*"
}

# Ensure log file directory exists
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null

# Initialize log file if it doesn't exist
if [ ! -f "${LOG_FILE}" ]; then
  touch "${LOG_FILE}" 2>/dev/null || true
fi 