#!/bin/bash
# collect_log.sh - Comprehensive log collection for PostgreSQL server troubleshooting
# Part of Milestones 1-10
# This script gathers system, PostgreSQL, pgbouncer, Nginx, Netdata, disaster recovery,
# user monitoring, optimization, backup, and SSL certificate logs for troubleshooting

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

# Function to remove comments from a file
remove_comments() {
  local input_file="$1"
  local output_file="$2"
  
  # Different comment patterns for different file types
  case "$(basename "$input_file")" in
    *.conf|*.ini|postgresql.conf|pg_hba.conf|pg_ident.conf|*.cnf|userlist.txt|*.yaml|*.yml)
      # Remove comments and empty lines for config files
      grep -v "^[[:space:]]*#" "$input_file" | grep -v "^[[:space:]]*;" | grep -v "^[[:space:]]*--" | grep -v "^[[:space:]]*$" > "$output_file"
      ;;
    *.sh|*.bash)
      # Remove bash-style comments from shell scripts
      grep -v "^[[:space:]]*#" "$input_file" | grep -v "^[[:space:]]*$" > "$output_file"
      ;;
    *)
      # For other files, just copy as is
      cat "$input_file" > "$output_file"
      ;;
  esac
}

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
      grep -v "^#" /etc/os-release | grep -v "^$"
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
  
  # Collect new milestone-specific logs
  log_info "Collecting milestone-specific logs..."
  mkdir -p "$OUTPUT_DIR/system/logs/milestones"
  
  # Milestone 8: PostgreSQL User Monitor logs
  if [ -f "/var/log/pg-user-monitor.log" ]; then
    cp "/var/log/pg-user-monitor.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect pg-user-monitor.log"
  fi
  
  # Milestone 9: Disaster Recovery logs
  if [ -f "/var/log/disaster-recovery.log" ]; then
    cp "/var/log/disaster-recovery.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect disaster-recovery.log"
  fi
  
  # Milestone 5: SSL Renewal logs
  if [ -f "/var/log/letsencrypt-renewal.log" ]; then
    cp "/var/log/letsencrypt-renewal.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect letsencrypt-renewal.log"
  fi
  
  # Milestone 10: Database Creation logs
  if [ -f "/var/log/create_database.log" ]; then
    cp "/var/log/create_database.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect create_database.log"
  fi
  
  if [ -f "/var/log/database_creation_audit.log" ]; then
    cp "/var/log/database_creation_audit.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect database_creation_audit.log"
  fi
  
  # Email system logs
  if [ -f "/var/log/msmtp.log" ]; then
    cp "/var/log/msmtp.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect msmtp.log"
  fi
  
  # Test logs
  if [ -f "/var/log/reboot-test.log" ]; then
    cp "/var/log/reboot-test.log" "$OUTPUT_DIR/system/logs/milestones/" || \
      log_warn "Failed to collect reboot-test.log"
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
  
  # PostgreSQL configuration - without comments
  PG_CONF_DIR="/etc/postgresql"
  if [ -d "$PG_CONF_DIR" ]; then
    # Find all .conf files
    find "$PG_CONF_DIR" -name "*.conf" -type f | while read -r conf_file; do
      conf_basename=$(basename "$conf_file")
      # Save config without comments
      remove_comments "$conf_file" "$OUTPUT_DIR/postgresql/config/$conf_basename"
    done
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
  
  # pgbouncer configuration - without comments
  if [ -f "/etc/pgbouncer/pgbouncer.ini" ]; then
    # Save config without comments
    remove_comments "/etc/pgbouncer/pgbouncer.ini" "$OUTPUT_DIR/pgbouncer/config/pgbouncer.ini"
  else
    log_warn "pgbouncer.ini not found"
  fi
  
  if [ -f "/etc/pgbouncer/userlist.txt" ]; then
    # Copy redacted version to avoid leaking passwords
    if [ -s "/etc/pgbouncer/userlist.txt" ]; then
      # File exists and is not empty
      {
        echo "# pgbouncer userlist - passwords redacted for security"
        echo "# Format: \"username\" \"password_hash\""
        echo "# Number of users configured:"
        grep -c "^\"" "/etc/pgbouncer/userlist.txt" 2>/dev/null || echo "0"
        echo "# Users (passwords hidden):"
        grep "^\"" "/etc/pgbouncer/userlist.txt" 2>/dev/null | sed 's/"[^"]*"$/"[REDACTED]"/' || echo "# No users found"
      } > "$OUTPUT_DIR/pgbouncer/config/userlist.txt.redacted" 2>/dev/null
    else
      # File exists but is empty
      echo "# pgbouncer userlist is empty" > "$OUTPUT_DIR/pgbouncer/config/userlist.txt.redacted"
    fi
  else
    log_warn "pgbouncer userlist.txt not found"
  fi
  
  # Nginx logs and config
  log_info "Collecting Nginx information..."
  mkdir -p "$OUTPUT_DIR/nginx/logs"
  mkdir -p "$OUTPUT_DIR/nginx/config"
  
  # Nginx status
  systemctl status nginx > "$OUTPUT_DIR/nginx/nginx_status.txt" 2>&1 || \
    log_warn "Failed to collect Nginx service status"
  
  # Nginx configuration - without comments
  if [ -d "/etc/nginx" ]; then
    # Main config without comments
    if [ -f "/etc/nginx/nginx.conf" ]; then
      remove_comments "/etc/nginx/nginx.conf" "$OUTPUT_DIR/nginx/config/nginx.conf"
    else
      log_warn "nginx.conf not found"
    fi
    
    # Sites available/enabled without comments
    mkdir -p "$OUTPUT_DIR/nginx/config/sites-available"
    mkdir -p "$OUTPUT_DIR/nginx/config/sites-enabled"
    
    # Process sites-available configs
    if [ -d "/etc/nginx/sites-available" ]; then
      find /etc/nginx/sites-available -type f | while read -r site_conf; do
        site_basename=$(basename "$site_conf")
        remove_comments "$site_conf" "$OUTPUT_DIR/nginx/config/sites-available/$site_basename"
      done
    fi
    
    # Process sites-enabled configs
    if [ -d "/etc/nginx/sites-enabled" ]; then
      find /etc/nginx/sites-enabled -type f | while read -r site_conf; do
        site_basename=$(basename "$site_conf")
        remove_comments "$site_conf" "$OUTPUT_DIR/nginx/config/sites-enabled/$site_basename"
      done
    fi
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
  
  # Netdata configuration - without comments
  if [ -d "/etc/netdata" ]; then
    if [ -f "/etc/netdata/netdata.conf" ]; then
      remove_comments "/etc/netdata/netdata.conf" "$OUTPUT_DIR/netdata/config/netdata.conf"
    else
      log_warn "netdata.conf not found"
    fi
    
    # Health configuration - without comments
    if [ -d "/etc/netdata/health.d" ]; then
      mkdir -p "$OUTPUT_DIR/netdata/config/health.d"
      find /etc/netdata/health.d -name "*.conf" -type f | while read -r health_conf; do
        health_basename=$(basename "$health_conf")
        remove_comments "$health_conf" "$OUTPUT_DIR/netdata/config/health.d/$health_basename"
      done
    fi
  else
    log_warn "Netdata config directory not found at /etc/netdata"
  fi
  
  # Hardware and optimization data
  log_info "Collecting hardware and optimization information..."
  mkdir -p "$OUTPUT_DIR/hardware"
  mkdir -p "$OUTPUT_DIR/optimization"
  
  # Hardware specifications and state files
  if [ -f "/var/lib/postgresql/hardware_specs.json" ]; then
    cp "/var/lib/postgresql/hardware_specs.json" "$OUTPUT_DIR/hardware/" || \
      log_warn "Failed to collect hardware_specs.json"
  fi
  
  if [ -f "/var/lib/postgresql/previous_hardware_specs.json" ]; then
    cp "/var/lib/postgresql/previous_hardware_specs.json" "$OUTPUT_DIR/hardware/" || \
      log_warn "Failed to collect previous_hardware_specs.json"
  fi
  
  if [ -f "/var/lib/postgresql/hardware_changes.txt" ]; then
    cp "/var/lib/postgresql/hardware_changes.txt" "$OUTPUT_DIR/hardware/" || \
      log_warn "Failed to collect hardware_changes.txt"
  fi
  
  # State files
  log_info "Collecting state files..."
  mkdir -p "$OUTPUT_DIR/state"
  
  if [ -f "/var/lib/postgresql/user_monitor_state.json" ]; then
    cp "/var/lib/postgresql/user_monitor_state.json" "$OUTPUT_DIR/state/" || \
      log_warn "Failed to collect user_monitor_state.json"
  fi
  
  if [ -f "/var/lib/postgresql/disaster_recovery_state.json" ]; then
    cp "/var/lib/postgresql/disaster_recovery_state.json" "$OUTPUT_DIR/state/" || \
      log_warn "Failed to collect disaster_recovery_state.json"
  fi
  
  # Optimization reports
  if [ -d "/var/lib/postgresql/optimization_reports" ]; then
    cp -r "/var/lib/postgresql/optimization_reports" "$OUTPUT_DIR/optimization/" 2>/dev/null || \
      log_warn "Failed to collect optimization reports directory"
  fi
  
  # Configuration backups
  if [ -d "/var/lib/postgresql/config_backups" ]; then
    # Copy only the most recent 5 backup directories to avoid huge archive
    mkdir -p "$OUTPUT_DIR/optimization/config_backups"
    find "/var/lib/postgresql/config_backups" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n 5 | while read -r backup_dir; do
      backup_name=$(basename "$backup_dir")
      cp -r "$backup_dir" "$OUTPUT_DIR/optimization/config_backups/" 2>/dev/null || \
        log_warn "Failed to collect config backup: $backup_name"
    done
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
    
    # Renewal hooks - without comments
    if [ -d "/etc/letsencrypt/renewal-hooks" ]; then
      mkdir -p "$OUTPUT_DIR/ssl/renewal-hooks"
      for hook_dir in pre deploy post; do
        if [ -d "/etc/letsencrypt/renewal-hooks/$hook_dir" ]; then
          mkdir -p "$OUTPUT_DIR/ssl/renewal-hooks/$hook_dir"
          find "/etc/letsencrypt/renewal-hooks/$hook_dir" -type f | while read -r hook_file; do
            hook_basename=$(basename "$hook_file")
            # For shell scripts, remove comment lines
            if [[ "$hook_basename" == *.sh ]]; then
              grep -v "^[[:space:]]*#" "$hook_file" | grep -v "^$" > "$OUTPUT_DIR/ssl/renewal-hooks/$hook_dir/$hook_basename"
            else
              cp "$hook_file" "$OUTPUT_DIR/ssl/renewal-hooks/$hook_dir/"
            fi
          done
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
  
  # Service status for all new services
  log_info "Collecting service status information..."
  mkdir -p "$OUTPUT_DIR/services"
  
  # Collect systemd service status for all milestone services
  local services=(
    "postgresql"
    "pgbouncer" 
    "nginx"
    "netdata"
    "pg-user-monitor"
    "disaster-recovery"
    "certbot.timer"
    "pg-full-optimization.timer"
  )
  
  for service in "${services[@]}"; do
    {
      echo "=== Service Status: $service ==="
      systemctl status "$service" 2>/dev/null || echo "Service $service not found or not active"
      echo ""
      echo "=== Service Logs (last 50 lines): $service ==="
      journalctl -u "$service" -n 50 --no-pager 2>/dev/null || echo "No journal logs found for $service"
      echo ""
    } > "$OUTPUT_DIR/services/${service}_status.txt" 2>&1
  done
  
  # Collect timer status
  {
    echo "=== Active Timers ==="
    systemctl list-timers --no-pager 2>/dev/null || echo "Failed to list timers"
    echo ""
    echo "=== Failed Units ==="
    systemctl --failed --no-pager 2>/dev/null || echo "Failed to list failed units"
  } > "$OUTPUT_DIR/services/timers_and_failed.txt" 2>&1
  
  # Backup system information
  log_info "Collecting backup system information..."
  mkdir -p "$OUTPUT_DIR/backup"
  
  # Backup configuration and schedules
  if [ -f "/etc/cron.d/postgresql-backup" ]; then
    cp "/etc/cron.d/postgresql-backup" "$OUTPUT_DIR/backup/" || \
      log_warn "Failed to collect postgresql-backup cron"
  fi
  
  # List recent backup files (without copying actual backups to avoid size issues)
  if [ -d "/var/lib/postgresql/backups" ]; then
    {
      echo "=== Backup Directory Structure ==="
      find "/var/lib/postgresql/backups" -type f -name "*.sql*" -o -name "*.gz" -o -name "*.tar*" | head -20 | while read -r backup_file; do
        ls -lh "$backup_file" 2>/dev/null || echo "Cannot access: $backup_file"
      done
      echo ""
      echo "=== Backup Directory Summary ==="
      du -sh "/var/lib/postgresql/backups"/* 2>/dev/null || echo "No backup directories found"
    } > "$OUTPUT_DIR/backup/backup_inventory.txt" 2>&1
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
    echo "  - Large backup files (only inventory included)"
    echo ""
    echo "New in this collection (Milestones 1-10):"
    echo "  - PostgreSQL user monitor logs and state"
    echo "  - Disaster recovery system logs and state"
    echo "  - SSL certificate renewal logs"
    echo "  - Database creation and audit logs"
    echo "  - Hardware optimization reports and specifications"
    echo "  - Email system logs (msmtp)"
    echo "  - Service status for all milestone services"
    echo "  - Backup system configuration and inventory"
    echo "  - Configuration backups from optimization changes"
    echo ""
    echo "All comments have been removed from configuration files."
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