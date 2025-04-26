#!/bin/bash
# pg_extract_hash.sh - Extract password hash from PostgreSQL
# Part of Milestone 2

# Function to extract password hash for a user
extract_hash() {
  local username="$1"
  local output_file="$2"
  
  # Check if parameters are provided
  if [ -z "$username" ] || [ -z "$output_file" ]; then
    log_error "Missing parameters. Usage: extract_hash <username> <output_file>"
    return 1
  fi
  
  log_info "Extracting password hash for user: $username"
  
  # Method 1: Have postgres create a temp file with the password hash directly
  # This avoids permission issues with writing to files created by root
  if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
    # Check if we got a valid result
    if [ -s "$output_file" ]; then
      log_info "Successfully extracted password hash to $output_file"
      return 0
    else
      log_warn "Method 1 succeeded but produced an empty file, trying alternate method"
    fi
  else
    log_warn "Method 1 failed, trying alternate method"
  fi
  
  # Method 2: Create a temp SQL file as postgres user
  # First create a random filename in a secure manner
  local timestamp=$(date +%s)
  local random_str=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8)
  local temp_sql="/tmp/pg_extract_${timestamp}_${random_str}.sql"
  local temp_out="/tmp/pg_extract_${timestamp}_${random_str}.out"
  
  # Have postgres create and use the temp SQL file
  if su - postgres -c "echo \"SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}';\" > \"$temp_sql\" && psql -t -f \"$temp_sql\" > \"$temp_out\" 2>/dev/null"; then
    # Check if we got a valid result
    if [ -s "$temp_out" ]; then
      # Copy result to the output file
      cat "$temp_out" > "$output_file"
      # Clean up temp files as postgres user
      su - postgres -c "rm -f \"$temp_sql\" \"$temp_out\"" 2>/dev/null
      log_info "Successfully extracted password hash to $output_file"
      return 0
    else
      log_warn "Method 2 succeeded but produced an empty file, trying simpler approach"
    fi
  else
    log_warn "Method 2 failed, trying simpler approach"
  fi
  
  # Method 3: Use simpler output format and post-process
  local temp_raw="/tmp/pg_extract_${timestamp}_${random_str}.raw"
  
  if su - postgres -c "psql -t -c \"SELECT passwd FROM pg_shadow WHERE usename='${username}'\" > \"$temp_raw\" 2>/dev/null"; then
    # Check if we got a valid result
    if [ -s "$temp_raw" ]; then
      # Trim whitespace and add quotes - do this from the root account since we can read the file
      passwd=$(cat "$temp_raw" | tr -d ' \n\r\t')
      # Format specifically for pgbouncer scram-sha-256 authentication
      echo "\"${username}\" \"${passwd}\"" > "$output_file"
      log_info "Checking hash format in $output_file"
      if grep -q "SCRAM-SHA-256" "$output_file"; then
        log_info "Successfully extracted SCRAM-SHA-256 hash to $output_file"
      else
        log_warn "Hash may not be in SCRAM-SHA-256 format, check pgbouncer compatibility"
      fi
      # Clean up temp files as postgres user
      su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
      return 0
    else
      log_error "Method 3 succeeded but password hash extraction returned empty result"
      su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
      return 1
    fi
  else
    log_error "All methods failed to extract password hash"
    return 1
  fi
}

# If script is run directly, use command line parameters
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If run directly, we need to source the logger first
  SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
  source "$SCRIPT_DIR/logger.sh"
  
  extract_hash "$1" "$2"
  exit $?
fi 