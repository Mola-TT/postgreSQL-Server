#!/bin/bash
# dynamic_optimization.sh - Dynamic optimization for PostgreSQL and pgbouncer
# Part of Milestone 6
# This script detects hardware specifications and dynamically calculates optimal configuration parameters

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory - using unique variable name to avoid conflicts
DYNAMIC_OPT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNAMIC_OPT_LIB_DIR="$DYNAMIC_OPT_SCRIPT_DIR/../lib"

# Source the logger functions
source "$DYNAMIC_OPT_LIB_DIR/logger.sh"

# Source utilities
source "$DYNAMIC_OPT_LIB_DIR/utilities.sh"

# Source PostgreSQL utilities for consistent SQL execution
source "$DYNAMIC_OPT_LIB_DIR/pg_extract_hash.sh"

# Flag variables
MINIMAL_MODE=false
FULL_MODE=false

# Hardware detection functions
detect_cpu_cores() {
  log_info "Detecting CPU cores..." >&2
  local cpu_cores
  
  # Try to get the number of CPU cores using nproc
  if command -v nproc >/dev/null 2>&1; then
    cpu_cores=$(nproc)
  else
    # Fallback to grep on /proc/cpuinfo
    cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null)
  fi
  
  # If both methods failed, default to 2 cores
  if [ -z "$cpu_cores" ] || [ "$cpu_cores" -lt 1 ]; then
    log_warn "Could not detect CPU cores, defaulting to 2" >&2
    cpu_cores=2
  fi
  
  log_info "Detected $cpu_cores CPU cores" >&2
  echo "$cpu_cores"
}

detect_total_memory() {
  log_info "Detecting total system memory..." >&2
  local total_memory_kb
  local total_memory_mb
  
  # Try to get total memory using free command
  if command -v free >/dev/null 2>&1; then
    total_memory_kb=$(free | grep -i 'Mem:' | awk '{print $2}')
    total_memory_mb=$((total_memory_kb / 1024))
  else
    # Fallback to grep on /proc/meminfo
    total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_memory_mb=$((total_memory_kb / 1024))
  fi
  
  # If both methods failed, default to 4GB
  if [ -z "$total_memory_mb" ] || [ "$total_memory_mb" -lt 1 ]; then
    log_warn "Could not detect total memory, defaulting to 4096 MB" >&2
    total_memory_mb=4096
  fi
  
  log_info "Detected $total_memory_mb MB of system memory" >&2
  echo "$total_memory_mb"
}

detect_disk_size() {
  log_info "Detecting disk size..." >&2
  local data_directory
  local disk_size_kb
  local disk_size_gb
  
  # Try multiple methods to get PostgreSQL data directory
  # Method 1: Direct psql query (most accurate)
  if command -v psql >/dev/null 2>&1; then
    data_directory=$(su - postgres -c "psql -t -c \"SHOW data_directory;\"" 2>/dev/null | grep -v '^$' | tr -d ' ' || echo "")
  fi
  
  # Method 2: Check common locations if Method 1 failed
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    log_info "PostgreSQL data directory not found via psql, trying common locations..." >&2
    
    # Try common PostgreSQL data directory locations
    for possible_dir in "/var/lib/postgresql/14/main" "/var/lib/postgresql/15/main" "/var/lib/postgresql/16/main" "/var/lib/postgresql/13/main" "/var/lib/postgresql/12/main" "/var/lib/postgresql/11/main" "/var/lib/postgresql/10/main" "/var/lib/postgresql/9.6/main"; do
      if [ -d "$possible_dir" ]; then
        data_directory="$possible_dir"
        log_info "Found PostgreSQL data directory at: $data_directory" >&2
        break
      fi
    done
  fi
  
  # Method 3: Try to find the postgresql.conf file and extract its directory
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    log_info "Trying to find postgresql.conf file..." >&2
    local conf_file
    
    for possible_conf in /etc/postgresql/*/main/postgresql.conf; do
      if [ -f "$possible_conf" ]; then
        conf_file="$possible_conf"
        break
      fi
    done
    
    if [ -n "$conf_file" ]; then
      # Try to extract data_directory from config file
      data_directory=$(grep "^data_directory" "$conf_file" 2>/dev/null | sed "s/.*[=][']\(.*\)['].*$/\1/" || echo "")
      if [ -n "$data_directory" ] && [ -d "$data_directory" ]; then
        log_info "Found PostgreSQL data directory from config: $data_directory" >&2
      fi
    fi
  fi
  
  # Method 4: Use PostgreSQL directory if data directory wasn't found
  if [ -z "$data_directory" ] || [ ! -d "$data_directory" ]; then
    # If no specific data directory found, use the general PostgreSQL directory
    if [ -d "/var/lib/postgresql" ]; then
      data_directory="/var/lib/postgresql"
      log_warn "Could not detect specific PostgreSQL data directory, using: $data_directory" >&2
    else
      # Fallback to root filesystem as last resort
      data_directory="/"
      log_warn "Could not detect PostgreSQL data directory, using root filesystem" >&2
    fi
  fi
  
  # Get disk size using df
  # Try multiple formats to ensure compatibility with different df implementations
  if ! disk_size_kb=$(df -P -k "$data_directory" 2>/dev/null | awk 'NR==2 {print $2}'); then
    if ! disk_size_kb=$(df -k "$data_directory" 2>/dev/null | awk 'NR==2 {print $2}'); then
      # If all attempts with the data directory failed, try parent directory
      parent_dir=$(dirname "$data_directory")
      log_warn "Failed to get disk size for $data_directory, trying parent directory: $parent_dir" >&2
      
      if ! disk_size_kb=$(df -P -k "$parent_dir" 2>/dev/null | awk 'NR==2 {print $2}'); then
        disk_size_kb=$(df -k "$parent_dir" 2>/dev/null | awk 'NR==2 {print $2}' || echo "0")
      fi
    fi
  fi
  
  # Calculate GB from KB
  if [ -n "$disk_size_kb" ] && [ "$disk_size_kb" -gt 0 ]; then
    disk_size_gb=$((disk_size_kb / 1024 / 1024))
  fi
  
  # If detection failed, default to 50GB
  if [ -z "$disk_size_gb" ] || [ "$disk_size_gb" -lt 1 ]; then
    log_warn "Could not detect disk size, defaulting to 50 GB" >&2
    disk_size_gb=50
  fi
  
  log_info "Detected $disk_size_gb GB disk size for PostgreSQL data" >&2
  echo "$disk_size_gb"
}

# PostgreSQL configuration calculation functions
calculate_shared_buffers() {
  local total_memory_mb=$1
  local shared_buffers_mb
  
  log_info "Calculating optimal shared_buffers..." >&2
  
  # Calculate shared_buffers based on total memory
  # Use 25% of RAM, but not more than 8GB
  shared_buffers_mb=$((total_memory_mb / 4))
  
  # Cap at 8GB for systems with more RAM
  if [ "$shared_buffers_mb" -gt 8192 ]; then
    shared_buffers_mb=8192
  fi
  
  # Minimum of 128MB
  if [ "$shared_buffers_mb" -lt 128 ]; then
    shared_buffers_mb=128
  fi
  
  log_info "Calculated shared_buffers: $shared_buffers_mb MB" >&2
  echo "$shared_buffers_mb"
}

calculate_work_mem() {
  local total_memory_mb=$1
  local max_connections=$2
  local cpu_cores=$3
  local work_mem_mb
  
  log_info "Calculating optimal work_mem..." >&2
  
  # Calculate work_mem based on available memory and max connections
  # Use 5% of RAM divided by max_connections * cpu_cores
  # This assumes each core can run a separate query for each connection
  work_mem_mb=$((total_memory_mb * 5 / 100 / (max_connections * cpu_cores / 4)))
  
  # Minimum of 4MB
  if [ "$work_mem_mb" -lt 4 ]; then
    work_mem_mb=4
  fi
  
  # Maximum of 64MB for OLTP workloads
  if [ "$work_mem_mb" -gt 64 ]; then
    work_mem_mb=64
  fi
  
  log_info "Calculated work_mem: $work_mem_mb MB" >&2
  echo "$work_mem_mb"
}

calculate_effective_cache_size() {
  local total_memory_mb=$1
  local effective_cache_size_mb
  
  log_info "Calculating optimal effective_cache_size..." >&2
  
  # Calculate effective_cache_size based on total memory
  # Use 75% of RAM
  effective_cache_size_mb=$((total_memory_mb * 75 / 100))
  
  log_info "Calculated effective_cache_size: $effective_cache_size_mb MB" >&2
  echo "$effective_cache_size_mb"
}

calculate_max_connections() {
  local total_memory_mb=$1
  local cpu_cores=$2
  local max_connections
  
  log_info "Calculating optimal max_connections..." >&2
  
  # Calculate max_connections based on available memory and CPU cores
  # Use 50 connections per GB of RAM, plus 50 per CPU core
  max_connections=$((total_memory_mb / 1024 * 50 + cpu_cores * 50))
  
  # Minimum of 100 connections
  if [ "$max_connections" -lt 100 ]; then
    max_connections=100
  fi
  
  # Maximum of 1000 connections for typical systems
  if [ "$max_connections" -gt 1000 ]; then
    max_connections=1000
  fi
  
  log_info "Calculated max_connections: $max_connections" >&2
  echo "$max_connections"
}

# pgbouncer configuration calculation functions
calculate_pgb_default_pool_size() {
  local cpu_cores=$1
  local pool_size
  
  log_info "Calculating optimal pgbouncer default_pool_size..." >&2
  
  # Calculate default_pool_size based on CPU cores
  # Use 2x CPU cores as a starting point
  pool_size=$((cpu_cores * 2))
  
  # Minimum of 5 connections per pool
  if [ "$pool_size" -lt 5 ]; then
    pool_size=5
  fi
  
  # Maximum of 50 connections per pool for typical workloads
  if [ "$pool_size" -gt 50 ]; then
    pool_size=50
  fi
  
  log_info "Calculated pgbouncer default_pool_size: $pool_size" >&2
  echo "$pool_size"
}

calculate_pgb_max_client_conn() {
  local max_connections=$1
  local cpu_cores=$2
  local total_memory_mb=$3
  local max_client_conn
  
  log_info "Calculating optimal pgbouncer max_client_conn..." >&2
  
  # Calculate max_client_conn based on PostgreSQL max_connections, CPU cores and memory
  # For systems with ample resources, allow more connections through pgbouncer
  # For resource-constrained systems, keep it closer to PostgreSQL max_connections
  
  # Start with max_connections value
  max_client_conn=$max_connections
  
  # For systems with many cores and lots of memory, we can allow more connections
  if [ "$cpu_cores" -gt 4 ] && [ "$total_memory_mb" -gt 8192 ]; then
    # Add extra connections based on resources
    max_client_conn=$((max_client_conn + cpu_cores * 25 + total_memory_mb / 1024 * 25))
  fi
  
  # Cap at 2000 connections to avoid overwhelming the system
  if [ "$max_client_conn" -gt 2000 ]; then
    max_client_conn=2000
  fi
  
  log_info "Calculated pgbouncer max_client_conn: $max_client_conn" >&2
  echo "$max_client_conn"
}

calculate_pgb_reserve_pool_size() {
  local default_pool_size=$1
  local reserve_pool_size
  
  log_info "Calculating optimal pgbouncer reserve_pool_size..." >&2
  
  # Calculate reserve_pool_size as a percentage of default_pool_size
  # Typically 10-20% of default_pool_size is a good starting point
  reserve_pool_size=$((default_pool_size * 15 / 100))
  
  # Minimum of 2 connections in reserve pool
  if [ "$reserve_pool_size" -lt 2 ]; then
    reserve_pool_size=2
  fi
  
  log_info "Calculated pgbouncer reserve_pool_size: $reserve_pool_size" >&2
  echo "$reserve_pool_size"
}

determine_pool_mode() {
  local cpu_cores=$1
  local total_memory_mb=$2
  local pool_mode
  
  log_info "Determining optimal pgbouncer pool_mode..." >&2
  
  # For systems with limited resources, session pooling might be more efficient
  # For systems with ample resources, transaction pooling is usually better
  
  # Default to transaction mode for most systems
  pool_mode="transaction"
  
  # For very resource-constrained systems, use session mode
  if [ "$cpu_cores" -lt 2 ] && [ "$total_memory_mb" -lt 2048 ]; then
    pool_mode="session"
    log_info "Resource-constrained system detected, using session pool mode" >&2
  fi
  
  log_info "Determined pgbouncer pool_mode: $pool_mode" >&2
  echo "$pool_mode"
}

# Main PostgreSQL optimization function
optimize_postgresql() {
  log_info "Optimizing PostgreSQL configuration based on hardware..." >&2
  
  # Detect hardware specifications
  local cpu_cores=$(detect_cpu_cores)
  local total_memory_mb=$(detect_total_memory)
  local disk_size_gb=$(detect_disk_size)
  
  # Calculate optimal PostgreSQL parameters
  local max_connections=$(calculate_max_connections "$total_memory_mb" "$cpu_cores")
  local shared_buffers_mb=$(calculate_shared_buffers "$total_memory_mb")
  local work_mem_mb=$(calculate_work_mem "$total_memory_mb" "$max_connections" "$cpu_cores")
  local effective_cache_size_mb=$(calculate_effective_cache_size "$total_memory_mb")
  
  # Create configuration file
  local config_file="/etc/postgresql/$(pg_lsclusters | grep -v Cluster | awk '{print $1}')/main/conf.d/90-dynamic-optimization.conf"
  
  log_info "Writing optimized PostgreSQL configuration to $config_file..." >&2
  
  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$config_file")" 2>/dev/null || true
  
  # Backup existing configuration if it exists
  if [ -f "$config_file" ]; then
    cp "$config_file" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    log_info "Backed up existing configuration" >&2
  fi
  
  # Write configuration
  {
    echo "# Dynamic PostgreSQL Optimization"
    echo "# Generated by dynamic_optimization.sh on $(date)"
    echo "# Hardware: $cpu_cores CPU cores, $total_memory_mb MB RAM, $disk_size_gb GB disk"
    echo ""
    echo "# Memory Configuration"
    echo "shared_buffers = '${shared_buffers_mb}MB'"
    echo "work_mem = '${work_mem_mb}MB'"
    echo "effective_cache_size = '${effective_cache_size_mb}MB'"
    echo ""
    echo "# Connection Configuration"
    echo "max_connections = $max_connections"
    echo ""
    echo "# WAL Configuration"
    if [ "$disk_size_gb" -gt 100 ]; then
      echo "wal_buffers = '16MB'"
    else
      echo "wal_buffers = '8MB'"
    fi
    echo ""
    echo "# Checkpoint Configuration"
    echo "checkpoint_timeout = '5min'"
    echo "checkpoint_completion_target = 0.9"
    echo ""
    echo "# VACUUM Configuration"
    echo "maintenance_work_mem = '$(( shared_buffers_mb / 4 ))MB'"
    echo "autovacuum_vacuum_scale_factor = 0.1"
    echo "autovacuum_analyze_scale_factor = 0.05"
  } > "$config_file"
  
  log_info "PostgreSQL configuration optimized successfully" >&2
  
  # Reload PostgreSQL to apply changes if not in minimal mode
  if [ "$MINIMAL_MODE" = "false" ]; then
    if systemctl is-active --quiet postgresql; then
      log_info "Reloading PostgreSQL configuration..." >&2
      systemctl reload postgresql > /dev/null 2>&1
      log_info "PostgreSQL configuration reloaded successfully" >&2
    else
      log_warn "PostgreSQL service is not running, skipping reload" >&2
    fi
  else
    log_info "Running in minimal mode, skipping PostgreSQL reload" >&2
  fi
}

# Main pgbouncer optimization function
optimize_pgbouncer() {
  log_info "Optimizing pgbouncer configuration based on hardware..." >&2
  
  # Detect hardware specifications
  local cpu_cores=$(detect_cpu_cores)
  local total_memory_mb=$(detect_total_memory)
  
  # Get PostgreSQL max_connections for reference
  local pg_max_connections
  pg_max_connections=$(su - postgres -c "psql -t -c \"SHOW max_connections;\"" 2>/dev/null | grep -v '^$' | tr -d ' ')
  
  # If we couldn't get max_connections from PostgreSQL, calculate it
  if [ -z "$pg_max_connections" ] || ! [[ "$pg_max_connections" =~ ^[0-9]+$ ]]; then
    log_warn "Could not get max_connections from PostgreSQL, calculating based on hardware..." >&2
    pg_max_connections=$(calculate_max_connections "$total_memory_mb" "$cpu_cores")
  fi
  
  # Calculate optimal pgbouncer parameters
  local default_pool_size=$(calculate_pgb_default_pool_size "$cpu_cores")
  local max_client_conn=$(calculate_pgb_max_client_conn "$pg_max_connections" "$cpu_cores" "$total_memory_mb")
  local reserve_pool_size=$(calculate_pgb_reserve_pool_size "$default_pool_size")
  local pool_mode=$(determine_pool_mode "$cpu_cores" "$total_memory_mb")
  
  # pgbouncer configuration file
  local pgb_conf="/etc/pgbouncer/pgbouncer.ini"
  
  if [ ! -f "$pgb_conf" ]; then
    log_error "pgbouncer configuration file not found: $pgb_conf" >&2
    return 1
  fi
  
  # Backup existing configuration
  cp "$pgb_conf" "${pgb_conf}.bak.$(date +%Y%m%d%H%M%S)"
  log_info "Backed up existing pgbouncer configuration" >&2
  
  # Create temporary file for the new configuration
  local temp_conf=$(mktemp)
  
  # Read current configuration and update parameters
  {
    # Keep the [databases] section as is
    awk '/^\[databases\]/ {p=1} /^\[/ && !/^\[databases\]/ {p=0} p' "$pgb_conf"
    
    # Add optimized pgbouncer configuration
    echo ""
    echo "[pgbouncer]"
    echo "# Dynamic optimization settings"
    echo "# Generated by dynamic_optimization.sh on $(date)"
    echo "# Hardware: $cpu_cores CPU cores, $total_memory_mb MB RAM"
    echo ""
    
    # Extract existing settings from current configuration that we want to preserve
    echo "# Preserved settings from existing configuration"
    awk '/^\[pgbouncer\]/ {p=1} /^\[/ && !/^\[pgbouncer\]/ {p=0} p && /^(logfile|pidfile|listen_addr|listen_port|unix_socket_dir|auth_type|auth_file|auth_query|admin_users|stats_users|ignore_startup_parameters|client_tls_sslmode|client_tls_key_file|client_tls_cert_file|server_tls_sslmode)/' "$pgb_conf" | grep -v "^\[pgbouncer\]"
    
    echo ""
    echo "# Dynamically optimized settings"
    echo "pool_mode = $pool_mode"
    echo "max_client_conn = $max_client_conn"
    echo "default_pool_size = $default_pool_size"
    echo "reserve_pool_size = $reserve_pool_size"
    
    # Calculate more parameters based on hardware
    echo "min_pool_size = $(( default_pool_size / 4 ))"
    echo "reserve_pool_timeout = 5"
    echo "server_round_robin = 1"
    
    # For systems with ample memory, increase server_lifetime for better performance
    if [ "$total_memory_mb" -gt 8192 ]; then
      echo "server_lifetime = 3600"
    else
      echo "server_lifetime = 1800"
    fi
    
    # Add the remaining sections from current configuration
    awk 'BEGIN {p=0} /^\[/ && !/^\[databases\]/ && !/^\[pgbouncer\]/ {p=1} p' "$pgb_conf"
  } > "$temp_conf"
  
  # Replace the original file with the new one
  mv "$temp_conf" "$pgb_conf"
  
  # Set proper permissions
  chown postgres:postgres "$pgb_conf"
  chmod 640 "$pgb_conf"
  
  log_info "pgbouncer configuration optimized successfully" >&2
  
  # Restart pgbouncer to apply changes if not in minimal mode
  if [ "$MINIMAL_MODE" = "false" ]; then
    if systemctl is-active --quiet pgbouncer; then
      log_info "Restarting pgbouncer to apply configuration..." >&2
      systemctl restart pgbouncer > /dev/null 2>&1
      log_info "pgbouncer restarted successfully" >&2
    else
      log_warn "pgbouncer service is not running, skipping restart" >&2
    fi
  else
    log_info "Running in minimal mode, skipping pgbouncer restart" >&2
  fi
}

# Generate optimization report
generate_optimization_report() {
  log_info "Generating optimization report..." >&2
  
  # Detect hardware specifications
  local cpu_cores=$(detect_cpu_cores)
  local total_memory_mb=$(detect_total_memory)
  local disk_size_gb=$(detect_disk_size)
  
  # Calculate parameters for reference
  local pg_max_connections=$(calculate_max_connections "$total_memory_mb" "$cpu_cores")
  local shared_buffers_mb=$(calculate_shared_buffers "$total_memory_mb")
  local work_mem_mb=$(calculate_work_mem "$total_memory_mb" "$pg_max_connections" "$cpu_cores")
  local effective_cache_size_mb=$(calculate_effective_cache_size "$total_memory_mb")
  local pgb_default_pool_size=$(calculate_pgb_default_pool_size "$cpu_cores")
  local pgb_max_client_conn=$(calculate_pgb_max_client_conn "$pg_max_connections" "$cpu_cores" "$total_memory_mb")
  
  # Create report directory
  local report_dir="/var/lib/postgresql/optimization_reports"
  mkdir -p "$report_dir" 2>/dev/null || true
  
  # Report file
  local report_file="$report_dir/optimization_report_$(date +%Y%m%d%H%M%S).txt"
  
  # Generate report
  {
    echo "PostgreSQL Dynamic Optimization Report"
    echo "====================================="
    echo "Generated on: $(date)"
    echo ""
    echo "Hardware Specifications"
    echo "---------------------"
    echo "CPU Cores: $cpu_cores"
    echo "Total Memory: $total_memory_mb MB"
    echo "Disk Size: $disk_size_gb GB"
    echo ""
    echo "PostgreSQL Configuration"
    echo "----------------------"
    echo "max_connections: $pg_max_connections"
    echo "shared_buffers: ${shared_buffers_mb}MB"
    echo "work_mem: ${work_mem_mb}MB"
    echo "effective_cache_size: ${effective_cache_size_mb}MB"
    echo "maintenance_work_mem: $(( shared_buffers_mb / 4 ))MB"
    echo ""
    echo "pgbouncer Configuration"
    echo "---------------------"
    echo "max_client_conn: $pgb_max_client_conn"
    echo "default_pool_size: $pgb_default_pool_size"
    echo "reserve_pool_size: $(calculate_pgb_reserve_pool_size "$pgb_default_pool_size")"
    echo "pool_mode: $(determine_pool_mode "$cpu_cores" "$total_memory_mb")"
    echo ""
    echo "Performance Recommendations"
    echo "------------------------"
    
    # Add performance recommendations based on hardware
    if [ "$total_memory_mb" -lt 4096 ]; then
      echo "- Low memory system detected. Consider adding more RAM for better performance."
    fi
    
    if [ "$cpu_cores" -lt 4 ]; then
      echo "- Low CPU core count. Consider using a system with more cores for better concurrency."
    fi
    
    if [ "$disk_size_gb" -lt 50 ]; then
      echo "- Limited disk space. Monitor disk usage regularly and consider adding more storage."
    fi
    
    # Additional application-specific recommendations
    echo "- For write-heavy workloads, consider increasing checkpoint_timeout."
    echo "- For read-heavy workloads, consider increasing effective_cache_size."
    echo "- For mixed workloads, the current configuration should be balanced."
    echo ""
    echo "Next Steps"
    echo "----------"
    echo "1. Monitor performance with Netdata dashboards"
    echo "2. Check PostgreSQL logs for potential bottlenecks"
    echo "3. Run EXPLAIN ANALYZE on slow queries and optimize them"
    echo "4. Revisit this optimization after significant hardware changes"
    echo ""
  } > "$report_file"
  
  # Set proper permissions
  chown postgres:postgres "$report_dir" "$report_file" 2>/dev/null || true
  
  log_info "Optimization report generated: $report_file" >&2
  
  # Return the report file path
  echo "$report_file"
}

# Main function to run optimization
main() {
  log_info "Starting dynamic optimization of PostgreSQL and pgbouncer..." >&2
  
  # Process command line arguments
  for arg in "$@"; do
    case $arg in
      --minimal)
        MINIMAL_MODE=true
        log_info "Running in minimal mode: will only apply changes that don't require a restart" >&2
        ;;
      --full)
        FULL_MODE=true
        log_info "Running in full mode: will apply all optimizations and restart services if needed" >&2
        ;;
    esac
  done
  
  # Check if PostgreSQL is installed
  if ! command -v psql >/dev/null 2>&1; then
    log_error "PostgreSQL is not installed, aborting optimization" >&2
    exit 1
  fi
  
  # Optimize PostgreSQL
  optimize_postgresql
  
  # Check if pgbouncer is installed
  if command -v pgbouncer >/dev/null 2>&1; then
    # Optimize pgbouncer
    optimize_pgbouncer
  else
    log_warn "pgbouncer is not installed, skipping pgbouncer optimization" >&2
  fi
  
  # Generate optimization report
  local report_file=$(generate_optimization_report)
  
  log_info "Dynamic optimization completed successfully" >&2
  log_info "Optimization report available at: $report_file" >&2
}

# If script is run directly, execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 