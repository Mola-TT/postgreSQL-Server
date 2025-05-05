#!/bin/bash
# collect_log.sh - Collects logs and diagnostic information for PostgreSQL server troubleshooting
# Part of Milestone 5
# This script gathers system, PostgreSQL, pgbouncer, Nginx, and Netdata logs for troubleshooting

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory - using unique variable name to avoid conflicts
TOOLS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TOOLS_SCRIPT_DIR/.." && pwd)"

# Source the logger functions (if available, optional)
if [ -f "$PROJECT_ROOT/lib/logger.sh" ]; then
  source "$PROJECT_ROOT/lib/logger.sh"
else
  # Define simple logging functions if logger.sh is not available
  log_info() { echo "[INFO] $1"; }
  log_warn() { echo "[WARN] $1"; }
  log_error() { echo "[ERROR] $1"; }
  log_debug() { echo "[DEBUG] $1"; }
fi

# Output directory for logs
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="/tmp/postgres_server_logs_${TIMESTAMP}"
LOG_ARCHIVE="/tmp/postgres_server_logs_${TIMESTAMP}.tar.gz"
CONSOLIDATED_LOG="/tmp/postgres_server_logs_${TIMESTAMP}.txt"

# Create the output directory
mkdir -p "$OUTPUT_DIR"

# Log collection function
collect_logs() {
  log_info "Starting log collection process..."
  log_info "Collecting logs to: $OUTPUT_DIR"

  # System information
  log_info "Collecting system information..."
  mkdir -p "$OUTPUT_DIR/system"
  
  # OS info
  log_info "Collecting OS information..."
  {
    echo "=== OS Information ==="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -a)"
    if [ -f /etc/os-release ]; then
      cat /etc/os-release
    fi
    echo -e "\n=== Disk Usage ==="
    df -h
    echo -e "\n=== Memory Usage ==="
    free -h
    echo -e "\n=== CPU Info ==="
    lscpu | grep -E "Architecture|CPU\(s\)|Thread|Core|Model name|MHz"
  } > "$OUTPUT_DIR/system/os_info.txt" 2>&1 || log_warn "Failed to collect some OS information"

  # Process list
  log_info "Collecting process information..."
  ps auxf > "$OUTPUT_DIR/system/process_list.txt" 2>&1 || log_warn "Failed to collect process list"
  
  # Network information
  log_info "Collecting network information..."
  {
    echo "=== Network Interfaces ==="
    ip a
    echo -e "\n=== Network Routes ==="
    ip route
    echo -e "\n=== Listening Ports ==="
    netstat -tulpn || ss -tulpn
    echo -e "\n=== Firewall Rules ==="
    iptables -L -n || true
    ufw status verbose || true
  } > "$OUTPUT_DIR/system/network_info.txt" 2>&1 || log_warn "Failed to collect some network information"
  
  # System logs
  log_info "Collecting system logs..."
  mkdir -p "$OUTPUT_DIR/system/logs"
  
  # Copy key system logs - excluding dmesg and kern.log as requested
  for log in /var/log/syslog /var/log/messages; do
    if [ -f "$log" ]; then
      tail -n 1000 "$log" > "$OUTPUT_DIR/system/logs/$(basename $log)" 2>/dev/null || \
        log_warn "Failed to collect $log"
    fi
  done
  
  # Collect server init logs
  log_info "Collecting server initialization logs..."
  SERVER_INIT_LOG="/var/log/server_init.log"
  if [ -f "$SERVER_INIT_LOG" ]; then
    cp "$SERVER_INIT_LOG" "$OUTPUT_DIR/system/logs/" || \
      log_warn "Failed to collect server init log"
  else
    log_warn "Server init log not found at $SERVER_INIT_LOG"
  fi
  
  # PostgreSQL logs and config
  log_info "Collecting PostgreSQL information..."
  mkdir -p "$OUTPUT_DIR/postgresql/logs"
  mkdir -p "$OUTPUT_DIR/postgresql/config"
  
  # PostgreSQL status
  systemctl status postgresql* > "$OUTPUT_DIR/postgresql/postgres_status.txt" 2>&1 || \
    log_warn "Failed to collect PostgreSQL service status"
  
  # PostgreSQL version
  if command -v psql >/dev/null 2>&1; then
    psql --version > "$OUTPUT_DIR/postgresql/version.txt" 2>&1 || \
      log_warn "Failed to get PostgreSQL version"
  else
    log_warn "psql command not found"
  fi
  
  # PostgreSQL configuration
  PG_CONF_DIR="/etc/postgresql"
  if [ -d "$PG_CONF_DIR" ]; then
    find "$PG_CONF_DIR" -name "*.conf" -type f -exec cp {} "$OUTPUT_DIR/postgresql/config/" \; 2>/dev/null || \
      log_warn "Failed to collect some PostgreSQL config files"
  else
    log_warn "PostgreSQL config directory not found at $PG_CONF_DIR"
  fi
  
  # PostgreSQL logs
  PG_LOG_DIR="/var/log/postgresql"
  if [ -d "$PG_LOG_DIR" ]; then
    for log in $(find "$PG_LOG_DIR" -type f -name "*.log" | sort | tail -n 5); do
      cp "$log" "$OUTPUT_DIR/postgresql/logs/" 2>/dev/null || \
        log_warn "Failed to collect PostgreSQL log: $log"
    done
  else
    log_warn "PostgreSQL log directory not found at $PG_LOG_DIR"
  fi
  
  # pgbouncer logs and config
  log_info "Collecting pgbouncer information..."
  mkdir -p "$OUTPUT_DIR/pgbouncer/config"
  
  # pgbouncer status
  systemctl status pgbouncer > "$OUTPUT_DIR/pgbouncer/pgbouncer_status.txt" 2>&1 || \
    log_warn "Failed to collect pgbouncer service status"
  
  # pgbouncer configuration
  if [ -f "/etc/pgbouncer/pgbouncer.ini" ]; then
    cp "/etc/pgbouncer/pgbouncer.ini" "$OUTPUT_DIR/pgbouncer/config/" 2>/dev/null || \
      log_warn "Failed to collect pgbouncer.ini"
  else
    log_warn "pgbouncer.ini not found"
  fi
  
  if [ -f "/etc/pgbouncer/userlist.txt" ]; then
    # Copy redacted version to avoid leaking passwords
    grep -v "^\"" "/etc/pgbouncer/userlist.txt" > "$OUTPUT_DIR/pgbouncer/config/userlist.txt.redacted" 2>/dev/null || \
      log_warn "Failed to collect redacted userlist.txt"
  fi
  
  # Nginx logs and config
  log_info "Collecting Nginx information..."
  mkdir -p "$OUTPUT_DIR/nginx/logs"
  mkdir -p "$OUTPUT_DIR/nginx/config"
  
  # Nginx status
  systemctl status nginx > "$OUTPUT_DIR/nginx/nginx_status.txt" 2>&1 || \
    log_warn "Failed to collect Nginx service status"
  
  # Nginx configuration
  if [ -d "/etc/nginx" ]; then
    cp "/etc/nginx/nginx.conf" "$OUTPUT_DIR/nginx/config/" 2>/dev/null || \
      log_warn "Failed to collect nginx.conf"
    
    # Sites available/enabled
    mkdir -p "$OUTPUT_DIR/nginx/config/sites-available"
    mkdir -p "$OUTPUT_DIR/nginx/config/sites-enabled"
    
    cp /etc/nginx/sites-available/* "$OUTPUT_DIR/nginx/config/sites-available/" 2>/dev/null || \
      log_warn "Failed to collect Nginx sites-available"
    
    cp /etc/nginx/sites-enabled/* "$OUTPUT_DIR/nginx/config/sites-enabled/" 2>/dev/null || \
      log_warn "Failed to collect Nginx sites-enabled"
  else
    log_warn "Nginx config directory not found at /etc/nginx"
  fi
  
  # Nginx logs
  if [ -d "/var/log/nginx" ]; then
    cp /var/log/nginx/error.log* "$OUTPUT_DIR/nginx/logs/" 2>/dev/null || \
      log_warn "Failed to collect Nginx error logs"
    
    cp /var/log/nginx/access.log* "$OUTPUT_DIR/nginx/logs/" 2>/dev/null || \
      log_warn "Failed to collect Nginx access logs"
  else
    log_warn "Nginx log directory not found at /var/log/nginx"
  fi
  
  # Netdata logs and config
  log_info "Collecting Netdata information..."
  mkdir -p "$OUTPUT_DIR/netdata/config"
  
  # Netdata status
  systemctl status netdata > "$OUTPUT_DIR/netdata/netdata_status.txt" 2>&1 || \
    log_warn "Failed to collect Netdata service status"
  
  # Netdata configuration
  if [ -d "/etc/netdata" ]; then
    cp /etc/netdata/netdata.conf "$OUTPUT_DIR/netdata/config/" 2>/dev/null || \
      log_warn "Failed to collect netdata.conf"
    
    # Health configuration
    if [ -d "/etc/netdata/health.d" ]; then
      mkdir -p "$OUTPUT_DIR/netdata/config/health.d"
      cp /etc/netdata/health.d/*.conf "$OUTPUT_DIR/netdata/config/health.d/" 2>/dev/null || \
        log_warn "Failed to collect Netdata health configs"
    fi
  else
    log_warn "Netdata config directory not found at /etc/netdata"
  fi
  
  # SSL certificates
  log_info "Collecting SSL certificate information..."
  mkdir -p "$OUTPUT_DIR/ssl"
  
  # Let's Encrypt information
  if [ -d "/etc/letsencrypt" ]; then
    # Log certificate domains and expiry dates, but not private data
    {
      echo "=== Let's Encrypt Certificates ==="
      for domain in $(find /etc/letsencrypt/live -maxdepth 1 -type d -not -path "/etc/letsencrypt/live"); do
        domain_name=$(basename "$domain")
        echo "Domain: $domain_name"
        
        if [ -f "$domain/cert.pem" ]; then
          echo "Certificate Info:"
          openssl x509 -in "$domain/cert.pem" -noout -subject -issuer -dates 2>/dev/null || \
            echo "Failed to read certificate info"
        fi
        
        echo "---"
      done
    } > "$OUTPUT_DIR/ssl/letsencrypt_certs.txt" 2>&1 || \
      log_warn "Failed to collect Let's Encrypt certificate info"
    
    # Check renewal status
    {
      echo "=== Let's Encrypt Renewal Status ==="
      certbot certificates 2>/dev/null || echo "certbot command failed"
    } > "$OUTPUT_DIR/ssl/certbot_status.txt" 2>&1 || \
      log_warn "Failed to collect certbot status"
    
    # Renewal hooks
    if [ -d "/etc/letsencrypt/renewal-hooks" ]; then
      mkdir -p "$OUTPUT_DIR/ssl/renewal-hooks"
      for hook_dir in pre deploy post; do
        if [ -d "/etc/letsencrypt/renewal-hooks/$hook_dir" ]; then
          mkdir -p "$OUTPUT_DIR/ssl/renewal-hooks/$hook_dir"
          cp /etc/letsencrypt/renewal-hooks/$hook_dir/* "$OUTPUT_DIR/ssl/renewal-hooks/$hook_dir/" 2>/dev/null || \
            log_warn "Failed to collect $hook_dir renewal hooks"
        fi
      done
    fi
    
    # Renewal logs
    if [ -f "/var/log/letsencrypt-renewal.log" ]; then
      cp "/var/log/letsencrypt-renewal.log" "$OUTPUT_DIR/ssl/" 2>/dev/null || \
        log_warn "Failed to collect letsencrypt-renewal.log"
    fi
  else
    log_warn "Let's Encrypt directory not found at /etc/letsencrypt"
    
    # Check for self-signed certificates
    if [ -d "/etc/nginx/ssl" ]; then
      {
        echo "=== Self-signed Certificates ==="
        for cert in $(find /etc/nginx/ssl -name "*.crt"); do
          echo "Certificate: $(basename "$cert")"
          openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null || \
            echo "Failed to read certificate info"
          echo "---"
        done
      } > "$OUTPUT_DIR/ssl/self_signed_certs.txt" 2>&1 || \
        log_warn "Failed to collect self-signed certificate info"
    fi
  fi
  
  # Create consolidated log file
  create_consolidated_log
  
  # Create archive of all collected logs
  log_info "Creating log archive..."
  tar -czf "$LOG_ARCHIVE" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" || {
    log_error "Failed to create log archive"
    log_info "Logs are available in: $OUTPUT_DIR"
    return 1
  }
  
  log_info "Log collection completed successfully"
  log_info "Log archive created: $LOG_ARCHIVE"
  log_info "Consolidated log created: $CONSOLIDATED_LOG"
  log_info "Raw logs directory: $OUTPUT_DIR"
  
  return 0
}

# Function to create a consolidated log file from all collected logs
create_consolidated_log() {
  log_info "Creating consolidated log file..."
  
  # Initialize the consolidated log file with header
  {
    echo "======================================================"
    echo "  POSTGRESQL SERVER CONSOLIDATED LOG - $(date)"
    echo "======================================================"
    echo ""
  } > "$CONSOLIDATED_LOG"
  
  # Find all text files in the output directory and concatenate them
  find "$OUTPUT_DIR" -type f -name "*.txt" -o -name "*.log" | sort | while read -r file; do
    relative_path="${file#$OUTPUT_DIR/}"
    
    {
      echo "======================================================"
      echo "FILE: $relative_path"
      echo "======================================================"
      echo ""
      cat "$file"
      echo ""
      echo ""
    } >> "$CONSOLIDATED_LOG"
  done
  
  # Add configuration files
  find "$OUTPUT_DIR" -type f -name "*.conf" -o -name "*.ini" | sort | while read -r file; do
    relative_path="${file#$OUTPUT_DIR/}"
    
    {
      echo "======================================================"
      echo "CONFIG: $relative_path"
      echo "======================================================"
      echo ""
      cat "$file"
      echo ""
      echo ""
    } >> "$CONSOLIDATED_LOG"
  done
  
  # Add summary at the end
  {
    echo "======================================================"
    echo "  LOG COLLECTION SUMMARY"
    echo "======================================================"
    echo ""
    echo "Timestamp: $(date)"
    echo "Log Collection Path: $OUTPUT_DIR"
    echo "Archive Path: $LOG_ARCHIVE"
    echo "Consolidated Log Path: $CONSOLIDATED_LOG"
    echo ""
    echo "Files collected:"
    find "$OUTPUT_DIR" -type f | sort | sed "s|$OUTPUT_DIR/||" | sed 's/^/  - /'
    echo ""
    echo "Files specifically excluded:"
    echo "  - system/logs/dmesg (excluded as requested)"
    echo "  - system/logs/kern.log (excluded as requested)"
    echo ""
    echo "======================================================"
  } >> "$CONSOLIDATED_LOG"
  
  log_info "Consolidated log file created: $CONSOLIDATED_LOG"
}

# Main function
main() {
  log_info "==============================================="
  log_info "PostgreSQL Server Setup Log Collection Utility"
  log_info "==============================================="
  
  # Check if running as root (required for accessing some logs)
  if [ "$(id -u)" -ne 0 ]; then
    log_warn "This script should be run as root to collect all logs"
    log_warn "Some logs may not be collected due to permission restrictions"
  fi
  
  # Collect logs
  if collect_logs; then
    log_info "Log collection completed successfully"
    log_info "Please provide the following files to assist with troubleshooting:"
    log_info "1. Archive: $LOG_ARCHIVE"
    log_info "2. Consolidated log: $CONSOLIDATED_LOG"
    
    # If script is running in a terminal, offer to view logs
    if [ -t 1 ]; then  # Check if stdout is a terminal
      read -p "Would you like to view the consolidated log? (y/n): " answer
      if [[ "$answer" == "y" ]]; then
        # Use less to view the consolidated log if available, otherwise cat
        if command -v less >/dev/null 2>&1; then
          less "$CONSOLIDATED_LOG"
        else
          cat "$CONSOLIDATED_LOG"
        fi
      fi
    fi
  else
    log_error "Log collection failed"
    exit 1
  fi
}

# Execute main function
main "$@" 