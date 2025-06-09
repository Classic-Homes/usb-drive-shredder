#!/bin/bash

# Simple USB Drive Wiper - DoD 5220.22-M Standard
# Simplified version focusing on core functionality

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
  exit 1
fi

# Check required commands
check_requirements() {
  local missing=()

  if [[ "$(uname)" == "Darwin" ]]; then
    for cmd in diskutil dd; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    done
    # Check for shred (from coreutils)
    if ! command -v shred >/dev/null 2>&1; then
      echo -e "${YELLOW}Warning: 'shred' not found. Install with: brew install coreutils${NC}"
      echo "Will use dd for wiping instead"
    fi
  else
    for cmd in lsblk shred; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing required commands: ${missing[*]}${NC}"
    exit 1
  fi
}

# Get list of removable drives
get_drives() {
  local drives=()

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Find external/USB drives with timeout protection
    echo "  Checking macOS drives..." >&2

    # Get device list first
    local device_list
    if ! device_list=$(timeout 10 diskutil list 2>/dev/null | grep -E "^/dev/disk[0-9]+" | awk '{print $1}'); then
      echo "  Warning: diskutil list timed out or failed" >&2
      return 0
    fi

    echo "$device_list" | while read -r device; do
      if [[ -n "$device" && "$device" =~ /dev/disk[0-9]+$ ]]; then
        echo "    Checking $device..." >&2

        # Skip if not readable
        if [[ ! -r "$device" ]]; then
          echo "      Not readable, skipping" >&2
          continue
        fi

        # Get device info with timeout
        local info
        if info=$(timeout 5 diskutil info "$device" 2>/dev/null); then
          if echo "$info" | grep -E "(Removable Media: +Yes|Protocol: +USB)" >/dev/null; then
            echo "      Found removable/USB drive: $device" >&2
            drives+=("$device")
          fi
        else
          echo "      Info check timed out, skipping" >&2
        fi
      fi
    done
  else
    # Linux: Find removable drives with better error handling
    echo "  Checking Linux drives..." >&2

    local lsblk_output
    if ! lsblk_output=$(timeout 10 lsblk -d -n -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE 2>/dev/null); then
      echo "  Warning: lsblk timed out or failed" >&2
      return 0
    fi

    echo "$lsblk_output" | while read -r line; do
      if [[ -n "$line" ]]; then
        local name=$(echo "$line" | awk '{print $1}')
        local removable=$(echo "$line" | awk '{print $3}')
        local type=$(echo "$line" | awk '{print $6}')

        echo "    Checking /dev/$name (type=$type, removable=$removable)..." >&2

        if [[ "$type" == "disk" && "$removable" == "1" ]]; then
          if [[ -r "/dev/$name" ]]; then
            echo "      Found removable drive: /dev/$name" >&2
            drives+=("/dev/$name")
          else
            echo "      Not readable, skipping" >&2
          fi
        fi
      fi
    done
  fi

  printf '%s\n' "${drives[@]}"
}

# Get drive info
get_drive_info() {
  local device="$1"
  local vendor="Unknown"
  local model="Unknown"
  local size="Unknown"

  if [[ "$(uname)" == "Darwin" ]]; then
    local info=$(diskutil info "$device" 2>/dev/null || echo "")
    vendor=$(echo "$info" | grep "Device / Media Name" | sed 's/.*: *//' | awk '{print $1}' || echo "Unknown")
    model=$(echo "$info" | grep "Device Model" | sed 's/.*: *//' || echo "Unknown")
    size=$(echo "$info" | grep "Disk Size" | sed 's/.*: *//' | awk '{print $1" "$2}' || echo "Unknown")
  else
    vendor=$(lsblk -d -no vendor "$device" 2>/dev/null | xargs || echo "Unknown")
    model=$(lsblk -d -no model "$device" 2>/dev/null | xargs || echo "Unknown")
    size=$(lsblk -d -no size "$device" 2>/dev/null || echo "Unknown")
  fi

  echo "$vendor|$model|$size"
}

# Check if drive is safe to wipe
is_safe_drive() {
  local device="$1"

  if [[ "$(uname)" == "Darwin" ]]; then
    # Check if it's an internal drive
    if diskutil info "$device" 2>/dev/null | grep -q "Internal: *Yes"; then
      return 1
    fi
    # Check if mounted to system paths
    local mount_point=$(diskutil info "$device" | grep "Mount Point" | sed 's/.*: *//')
    if [[ "$mount_point" == "/" || "$mount_point" == "/System" ]]; then
      return 1
    fi
  else
    # Check if it's sda (usually system drive)
    if [[ "$device" == "/dev/sda" ]]; then
      return 1
    fi
    # Check if mounted to system paths
    if mount | grep "^$device" | grep -E "( /| /boot| /home)" >/dev/null; then
      return 1
    fi
  fi

  return 0
}

# Display drives
display_drives() {
  local drives=("$@")

  clear
  echo -e "${BOLD}${BLUE}USB Drive Wiper - Available Drives${NC}"
  echo "========================================"
  echo

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No removable drives found.${NC}"
    echo
    echo "Make sure:"
    echo "- USB drives are connected"
    echo "- USB passthrough is enabled (if in VM)"
    exit 0
  fi

  for i in "${!drives[@]}"; do
    local device="${drives[$i]}"
    local info=$(get_drive_info "$device")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local num=$((i + 1))

    if is_safe_drive "$device"; then
      echo -e "${GREEN}[$num]${NC} $device - $vendor $model ($size) ${GREEN}[SAFE]${NC}"
    else
      echo -e "${RED}[$num]${NC} $device - $vendor $model ($size) ${RED}[SYSTEM - SKIP]${NC}"
    fi
  done
  echo
}

# Get user selection
get_selection() {
  local drives=("$@")

  while true; do
    display_drives "${drives[@]}"

    echo "Enter drive numbers (space-separated) or 'q' to quit:"
    echo "Example: 1 3 4"
    echo -n "Selection: "
    read -r selection

    if [[ "$selection" == "q" ]]; then
      exit 0
    fi

    local selected=()
    local valid=true

    for num in $selection; do
      if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input: '$num'${NC}"
        valid=false
        break
      fi

      local index=$((num - 1))
      if [[ $index -lt 0 || $index -ge ${#drives[@]} ]]; then
        echo -e "${RED}Invalid number: $num${NC}"
        valid=false
        break
      fi

      local device="${drives[$index]}"
      if ! is_safe_drive "$device"; then
        echo -e "${RED}Skipping unsafe drive: $device${NC}"
        continue
      fi

      selected+=("$device")
    done

    if [[ "$valid" == "false" ]]; then
      echo "Press Enter to try again..."
      read -r
      continue
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No valid drives selected.${NC}"
      echo "Press Enter to try again..."
      read -r
      continue
    fi

    printf '%s\n' "${selected[@]}"
    return 0
  done
}

# Confirm selection
confirm_wipe() {
  local drives=("$@")

  clear
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo "=================="
  echo
  echo -e "${RED}The following drives will be PERMANENTLY WIPED:${NC}"
  echo

  for drive in "${drives[@]}"; do
    local info=$(get_drive_info "$drive")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    echo -e "  ${YELLOW}$drive${NC} - $vendor $model ($size)"
  done

  echo
  echo -e "${RED}${BOLD}This will permanently destroy all data!${NC}"
  echo -e "${RED}${BOLD}This cannot be undone!${NC}"
  echo
  echo "Type 'WIPE' to confirm:"
  read -r confirmation

  [[ "$confirmation" == "WIPE" ]]
}

# Unmount drive
unmount_drive() {
  local device="$1"

  if [[ "$(uname)" == "Darwin" ]]; then
    diskutil unmountDisk force "$device" 2>/dev/null || true
  else
    # Unmount all partitions
    for part in $(lsblk -ln -o NAME "$device" | tail -n +2); do
      umount "/dev/$part" 2>/dev/null || true
    done
    umount "$device" 2>/dev/null || true
  fi

  sleep 1
}

# Wipe drive using DoD 5220.22-M standard
wipe_drive() {
  local device="$1"
  local report_file="/tmp/wipe_report_$(basename "$device")_$(date +%Y%m%d_%H%M%S).txt"

  # Create report header
  cat >"$report_file" <<EOF
===================================
Drive Wipe Report
===================================
Date: $(date)
Device: $device
Standard: DoD 5220.22-M (3 passes + zero)
Status: IN PROGRESS

Drive Information:
$(get_drive_info "$device" | tr '|' '\n' | nl -w2 -s': ')

Wipe Process:
EOF

  echo -e "${BLUE}Wiping $device...${NC}"

  # Unmount first
  echo "  Unmounting..." | tee -a "$report_file"
  unmount_drive "$device"

  local start_time=$(date +%s)

  if command -v shred >/dev/null 2>&1; then
    echo "  Using shred (DoD 5220.22-M: 3 passes + zero)..." | tee -a "$report_file"
    if shred -vfz -n 3 "$device" >>"$report_file" 2>&1; then
      local status="SUCCESS"
    else
      local status="FAILED"
    fi
  else
    # Fallback to dd (mainly for macOS without shred)
    echo "  Using dd (3 random passes + zero)..." | tee -a "$report_file"
    local size_bytes=$(diskutil info "$device" | grep "Disk Size" | awk '{print $4}' | tr -d '(),')

    for pass in 1 2 3; do
      echo "    Pass $pass/4: Random data" | tee -a "$report_file"
      if ! dd if=/dev/urandom of="$device" bs=1m 2>>"$report_file"; then
        status="FAILED"
        break
      fi
    done

    if [[ "$status" != "FAILED" ]]; then
      echo "    Pass 4/4: Zero fill" | tee -a "$report_file"
      if dd if=/dev/zero of="$device" bs=1m 2>>"$report_file"; then
        status="SUCCESS"
      else
        status="FAILED"
      fi
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Update report
  cat >>"$report_file" <<EOF

Wipe Completed: $(date)
Duration: ${duration} seconds
Final Status: $status
EOF

  if [[ "$status" == "SUCCESS" ]]; then
    echo -e "  ${GREEN}✓ Completed successfully${NC}"
  else
    echo -e "  ${RED}✗ Failed${NC}"
  fi

  echo "  Report: $report_file"
}

# Main function
main() {
  echo -e "${BOLD}USB Drive Wiper Starting...${NC}"

  check_requirements

  echo "Scanning for drives..."
  echo "(This may take a few seconds on some systems)"

  # Get drives with timeout protection
  local drives_output
  if drives_output=$(timeout 30 bash -c 'get_drives() {
        local drives=()
        
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS: Find external/USB drives with timeout protection
            echo "  Checking macOS drives..." >&2
            
            # Get device list first
            local device_list
            if ! device_list=$(timeout 10 diskutil list 2>/dev/null | grep -E "^/dev/disk[0-9]+" | awk "{print \$1}"); then
                echo "  Warning: diskutil list timed out or failed" >&2
                return 0
            fi
            
            echo "$device_list" | while read -r device; do
                if [[ -n "$device" && "$device" =~ /dev/disk[0-9]+$ ]]; then
                    echo "    Checking $device..." >&2
                    
                    # Skip if not readable
                    if [[ ! -r "$device" ]]; then
                        echo "      Not readable, skipping" >&2
                        continue
                    fi
                    
                    # Get device info with timeout
                    local info
                    if info=$(timeout 5 diskutil info "$device" 2>/dev/null); then
                        if echo "$info" | grep -E "(Removable Media: +Yes|Protocol: +USB)" >/dev/null; then
                            echo "      Found removable/USB drive: $device" >&2
                            echo "$device"
                        fi
                    else
                        echo "      Info check timed out, skipping" >&2
                    fi
                fi
            done
        else
            # Linux: Find removable drives with better error handling
            echo "  Checking Linux drives..." >&2
            
            local lsblk_output
            if ! lsblk_output=$(timeout 10 lsblk -d -n -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE 2>/dev/null); then
                echo "  Warning: lsblk timed out or failed" >&2
                return 0
            fi
            
            echo "$lsblk_output" | while read -r line; do
                if [[ -n "$line" ]]; then
                    local name=$(echo "$line" | awk "{print \$1}")
                    local removable=$(echo "$line" | awk "{print \$3}")
                    local type=$(echo "$line" | awk "{print \$6}")
                    
                    echo "    Checking /dev/$name (type=$type, removable=$removable)..." >&2
                    
                    if [[ "$type" == "disk" && "$removable" == "1" ]]; then
                        if [[ -r "/dev/$name" ]]; then
                            echo "      Found removable drive: /dev/$name" >&2
                            echo "/dev/$name"
                        else
                            echo "      Not readable, skipping" >&2
                        fi
                    fi
                fi
            done
        fi
    }; get_drives' 2>&1); then
    # Extract just the device paths from the output
    mapfile -t drives < <(echo "$drives_output" | grep "^/dev/" || true)
  else
    echo -e "${RED}Error: Drive scanning timed out after 30 seconds${NC}"
    echo "This might indicate:"
    echo "- Slow disk access (VM or hardware issue)"
    echo "- Permission problems"
    echo "- System overload"
    echo
    echo "Try running the debug script: sudo bash drive_debug.sh"
    exit 1
  fi

  # Get user selection
  mapfile -t selected < <(get_selection "${drives[@]}")

  # Confirm
  if ! confirm_wipe "${selected[@]}"; then
    echo "Operation cancelled."
    exit 0
  fi

  echo
  echo -e "${BOLD}Starting wipe operations...${NC}"
  echo

  # Wipe each drive
  for drive in "${selected[@]}"; do
    wipe_drive "$drive"
    echo
  done

  echo -e "${GREEN}${BOLD}All operations completed!${NC}"
  echo
  echo "Reports are saved in /tmp/wipe_report_*"
}

# Run main function
main "$@"
