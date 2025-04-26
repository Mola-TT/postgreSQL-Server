#!/bin/bash
# pg_extract_hash.sh - Extract password hash from PostgreSQL
# Part of Milestone 2

# Log to stderr for capture by the parent script
log_extraction() {
  echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >&2
}

# Function to extract password hash for a user
extract_hash() {
  local username="$1"
  local output_file="$2"
  
  # Check if parameters are provided
  if [ -z "$username" ] || [ -z "$output_file" ]; then
    log_extraction "ERROR: Missing parameters. Usage: extract_hash <username> <output_file>"
    return 1
  fi
  
  log_extraction "INFO: Extracting password hash for user: $username"
  
  # Try to get the hash directly from PostgreSQL - Method 1
  if ! su - postgres -c "psql -t -c \"SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}'\" > ${output_file} 2>/dev/null"; then
    log_extraction "WARN: Method 1 failed, trying alternate method"
    
    # Method 2: Create a temp SQL file and use that to avoid complex quoting
    local temp_sql=$(mktemp)
    echo "SELECT '\"${username}\" \"' || passwd || '\"' FROM pg_shadow WHERE usename='${username}';" > "$temp_sql"
    
    if ! su - postgres -c "psql -t -f ${temp_sql} > ${output_file} 2>/dev/null"; then
      log_extraction "WARN: Method 2 failed, trying simpler approach"
      
      # Method 3: Use simpler output format and post-process
      if ! su - postgres -c "psql -t -c \"SELECT passwd FROM pg_shadow WHERE usename='${username}'\" > ${output_file}.raw 2>/dev/null"; then
        log_extraction "ERROR: All methods failed to extract password hash"
        rm -f "$temp_sql" "${output_file}.raw"
        return 1
      fi
      
      # Post-process the raw output
      if [ -s "${output_file}.raw" ]; then
        # Trim whitespace and add quotes
        passwd=$(cat "${output_file}.raw" | tr -d ' \n\r\t')
        echo "\"${username}\" \"${passwd}\"" > "$output_file"
        rm -f "${output_file}.raw"
      else
        log_extraction "ERROR: Password hash extraction returned empty result"
        rm -f "$temp_sql" "${output_file}.raw"
        return 1
      fi
    fi
    
    # Clean up temp SQL file
    rm -f "$temp_sql"
  fi
  
  # Verify we got something
  if [ ! -s "$output_file" ]; then
    log_extraction "ERROR: Password hash file is empty"
    return 1
  fi
  
  log_extraction "INFO: Successfully extracted password hash to $output_file"
  return 0
}

# If script is run directly, use command line parameters
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  extract_hash "$1" "$2"
  exit $?
fi 