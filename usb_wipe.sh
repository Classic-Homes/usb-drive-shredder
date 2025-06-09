#!/bin/bash

# Simplified USB Drive Wiper - DoD 5220.22-M Standard
# Shows all drives immediately for VM environments

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

# Get all disk drives (simplified - no filtering)
get_all_drives() {
  local drives=()

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Get all disk drives
    while read -r device; do
      if [[ -n "$device" && "$device" =~ /dev/disk[0-9]+$ && -r "$device" ]]; then
        drives+=("$device")
      fi
    done < <(diskutil list 2>/dev/null | grep -E "^/dev/disk[0-9]+" | awk '{print $1}')
  else
    # Linux: Get all disk drives
    while read -r line; do
      if [[ -n "$line" ]]; then
        local name=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        if [[ "$type" == "disk" ]]; then
          drives+=("/dev/$name")
        fi
      fi
    done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null)
  fi

  printf '%s\n' "${drives[@]}"
}

# Get drive info with timeout protection
get_drive_info() {
  local device="$1"
  local vendor="Unknown"
  local model="Unknown"
  local size="Unknown"
  local mounted=""

  # Add timeout to prevent hanging
  if [[ "$(uname)" == "Darwin" ]]; then
    local info=$(timeout 5 diskutil info "$device" 2>/dev/null || echo "")
    vendor=$(echo "$info" | grep "Device / Media Name" | sed 's/.*: *//' | awk '{print $1}' 2>/dev/null || echo "Unknown")
    model=$(echo "$info" | grep "Device Model" | sed 's/.*: *//' 2>/dev/null || echo "Unknown")
    size=$(echo "$info" | grep "Disk Size" | sed 's/.*: *//' | awk '{print $1" "$2}' 2>/dev/null || echo "Unknown")

    # Check if mounted
    if echo "$info" | grep -q "Mounted.*Yes" 2>/dev/null; then
      mounted="MOUNTED"
    fi
  else
    # Use timeout for all lsblk commands
    vendor=$(timeout 3 lsblk -d -no vendor "$device" 2>/dev/null | xargs 2>/dev/null || echo "Unknown")
    model=$(timeout 3 lsblk -d -no model "$device" 2>/dev/null | xargs 2>/dev/null || echo "Unknown")
    size=$(timeout 3 lsblk -d -no size "$device" 2>/dev/null || echo "Unknown")

    # Check if any partition is mounted (with timeout)
    if timeout 3 lsblk -no mountpoint "$device" 2>/dev/null | grep -q "/" 2>/dev/null; then
      mounted="MOUNTED"
    fi
  fi

  echo "$vendor|$model|$size|$mounted"
}

# Determine safety level based on common patterns
get_safety_level() {
  local device="$1"
  local info="$2"
  local size=$(echo "$info" | cut -d'|' -f3)
  local mounted=$(echo "$info" | cut -d'|' -f4)

  # Check for obvious system drive patterns
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: disk0 is usually the system drive
    if [[ "$device" == "/dev/disk0" ]]; then
      echo "SYSTEM"
      return
    fi
    # Check if it's the boot drive
    if diskutil info "$device" 2>/dev/null | grep -q "Boot Drive.*Yes"; then
      echo "SYSTEM"
      return
    fi
  else
    # Linux: sda is usually the system drive
    if [[ "$device" == "/dev/sda" ]]; then
      echo "SYSTEM"
      return
    fi
    # Check if mounted to system locations
    if mount | grep "^$device" | grep -E "( /| /boot| /home)" >/dev/null 2>&1; then
      echo "SYSTEM"
      return
    fi
  fi

  # Check if mounted (could be important)
  if [[ "$mounted" == "MOUNTED" ]]; then
    echo "CAUTION"
    return
  fi

  # Large drives might be important
  if [[ "$size" =~ ([0-9]+).*TB ]] && [[ ${BASH_REMATCH[1]} -gt 1 ]]; then
    echo "CAUTION"
    return
  fi

  echo "SAFE"
}

# Display all drives with safety indicators
display_drives() {
  local drives=("$@")

  clear
  echo -e "${BOLD}${BLUE}USB Drive Wiper - All Available Drives${NC}"
  echo "========================================"
  echo
  echo -e "${BOLD}Legend:${NC}"
  echo -e "  ${GREEN}SAFE${NC}     - Likely removable/external drive"
  echo -e "  ${YELLOW}CAUTION${NC}  - Mounted or large drive - verify carefully"
  echo -e "  ${RED}SYSTEM${NC}   - Likely system drive - DO NOT WIPE"
  echo

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No drives found.${NC}"
    return 1
  fi

  echo "Getting drive information..."
  for i in "${!drives[@]}"; do
    local device="${drives[$i]}"
    local num=$((i + 1))

    echo -n "  [$num] $device - "

    # Get info with error handling
    local info
    if info=$(get_drive_info "$device" 2>/dev/null); then
      local vendor=$(echo "$info" | cut -d'|' -f1)
      local model=$(echo "$info" | cut -d'|' -f2)
      local size=$(echo "$info" | cut -d'|' -f3)
      local mounted=$(echo "$info" | cut -d'|' -f4)
      local safety=$(get_safety_level "$device" "$info")

      # Format the display line
      local mount_indicator=""
      if [[ "$mounted" == "MOUNTED" ]]; then
        mount_indicator=" ${YELLOW}(MOUNTED)${NC}"
      fi

      case "$safety" in
      "SAFE")
        echo -e "$vendor $model ($size) ${GREEN}[SAFE]${NC}$mount_indicator"
        ;;
      "CAUTION")
        echo -e "$vendor $model ($size) ${YELLOW}[CAUTION]${NC}$mount_indicator"
        ;;
      "SYSTEM")
        echo -e "$vendor $model ($size) ${RED}[SYSTEM - DO NOT WIPE]${NC}$mount_indicator"
        ;;
      esac
    else
      echo -e "${YELLOW}Info unavailable${NC}"
    fi
  done
  echo
  return 0
}

# Get user selection with safety checks
get_selection() {
  local drives=("$@")

  while true; do
    display_drives "${drives[@]}"

    echo -e "${BOLD}Selection Instructions:${NC}"
    echo "• Enter drive numbers separated by spaces (example: 2 3 4)"
    echo "• Type 'q' to quit"
    echo "• ${RED}AVOID drives marked as SYSTEM${NC}"
    echo "• ${YELLOW}Double-check CAUTION drives${NC}"
    echo
    echo -n "Your selection: "
    read -r selection

    if [[ "$selection" == "q" ]]; then
      exit 0
    fi

    local selected=()
    local valid=true
    local has_system=false

    for num in $selection; do
      if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input: '$num' is not a number${NC}"
        valid=false
        break
      fi

      local index=$((num - 1))
      if [[ $index -lt 0 || $index -ge ${#drives[@]} ]]; then
        echo -e "${RED}Invalid number: $num (valid range: 1-${#drives[@]})${NC}"
        valid=false
        break
      fi

      local device="${drives[$index]}"
      local info=$(get_drive_info "$device")
      local safety=$(get_safety_level "$device" "$info")

      # Check safety level
      if [[ "$safety" == "SYSTEM" ]]; then
        echo -e "${RED}ERROR: $device is marked as SYSTEM drive - refusing to select${NC}"
        has_system=true
        valid=false
        continue
      fi

      if [[ "$safety" == "CAUTION" ]]; then
        echo -e "${YELLOW}WARNING: $device is marked as CAUTION${NC}"
        echo -e "  Device: $device"
        echo -e "  Info: $(echo "$info" | tr '|' ' - ')"
        echo -n "Are you sure? Type 'YES' to confirm: "
        read -r confirm
        if [[ "$confirm" != "YES" ]]; then
          echo "Skipping $device"
          continue
        fi
      fi

      # Check for duplicates
      if [[ " ${selected[*]} " =~ " $device " ]]; then
        echo -e "${YELLOW}Drive $device already selected${NC}"
        continue
      fi

      selected+=("$device")
    done

    if [[ "$valid" == "false" ]]; then
      if [[ "$has_system" == "true" ]]; then
        echo -e "${RED}Please remove SYSTEM drives from your selection.${NC}"
      fi
      echo "Press Enter to try again..."
      read -r
      continue
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No drives selected.${NC}"
      echo "Press Enter to try again..."
      read -r
      continue
    fi

    echo
    echo -e "${GREEN}Selected ${#selected[@]} drive(s):${NC}"
    for drive in "${selected[@]}"; do
      local info=$(get_drive_info "$drive")
      echo "  $drive - $(echo "$info" | tr '|' ' - ')"
    done
    echo
    echo -n "Proceed with these drives? (y/N): "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      printf '%s\n' "${selected[@]}"
      return 0
    fi
  done
}

# Final confirmation
confirm_wipe() {
  local drives=("$@")

  clear
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo "=================="
  echo
  echo -e "${RED}The following drives will be PERMANENTLY WIPED using DoD 5220.22-M standard:${NC}"
  echo

  for drive in "${drives[@]}"; do
    local info=$(get_drive_info "$drive")
    echo -e "  ${YELLOW}$drive${NC} - $(echo "$info" | tr '|' ' - ')"
  done

  echo
  echo -e "${RED}${BOLD}THIS WILL PERMANENTLY DESTROY ALL DATA!${NC}"
  echo -e "${RED}${BOLD}THIS CANNOT BE UNDONE!${NC}"
  echo
  echo "Type 'WIPE' exactly to confirm:"
  read -r confirmation

  [[ "$confirmation" == "WIPE" ]]
}

# Unmount drive
unmount_drive() {
  local device="$1"

  echo "    Unmounting $device..."
  if [[ "$(uname)" == "Darwin" ]]; then
    diskutil unmountDisk force "$device" 2>/dev/null || true
  else
    # Unmount all partitions
    for part in $(lsblk -ln -o NAME "$device" 2>/dev/null | tail -n +2); do
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

  echo -e "${BLUE}Wiping $device...${NC}"

  # Create report
  {
    echo "====================================="
    echo "Drive Wipe Report"
    echo "====================================="
    echo "Date: $(date)"
    echo "Device: $device"
    echo "Standard: DoD 5220.22-M (3 passes + zero)"
    echo
    echo "Drive Information:"
    get_drive_info "$device" | tr '|' '\n' | nl -w2 -s': '
    echo
    echo "Wipe Process:"
  } >"$report_file"

  # Unmount
  unmount_drive "$device"

  local start_time=$(date +%s)
  local status="SUCCESS"

  if command -v shred >/dev/null 2>&1; then
    echo "    Using shred (DoD 5220.22-M: 3 passes + zero)..."
    echo "$(date): Starting shred operation" >>"$report_file"
    if ! shred -vfz -n 3 "$device" >>"$report_file" 2>&1; then
      status="FAILED"
    fi
  else
    echo "    Using dd (3 random passes + zero)..."
    echo "$(date): Starting dd operation (fallback)" >>"$report_file"

    for pass in 1 2 3; do
      echo "      Pass $pass/4: Random data"
      echo "$(date): Pass $pass - random data" >>"$report_file"
      if ! dd if=/dev/urandom of="$device" bs=1M 2>>"$report_file"; then
        status="FAILED"
        break
      fi
    done

    if [[ "$status" != "FAILED" ]]; then
      echo "      Pass 4/4: Zero fill"
      echo "$(date): Pass 4 - zero fill" >>"$report_file"
      if ! dd if=/dev/zero of="$device" bs=1M 2>>"$report_file"; then
        status="FAILED"
      fi
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Update report
  {
    echo
    echo "Wipe Completed: $(date)"
    echo "Duration: ${duration} seconds"
    echo "Final Status: $status"
  } >>"$report_file"

  if [[ "$status" == "SUCCESS" ]]; then
    echo -e "    ${GREEN}✓ Completed successfully${NC}"
  else
    echo -e "    ${RED}✗ Failed${NC}"
  fi

  echo "    Report saved: $report_file"
}

# Main function
main() {
  echo -e "${BOLD}${BLUE}USB Drive Wiper${NC}"
  echo "==============="
  echo

  check_requirements

  echo "Scanning for all disk drives..."
  mapfile -t drives < <(get_all_drives)

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${RED}No disk drives found!${NC}"
    echo "Check if running as root: sudo $0"
    exit 1
  fi

  echo "Found ${#drives[@]} drive(s)"
  echo

  # Get user selection
  mapfile -t selected < <(get_selection "${drives[@]}")

  # Final confirmation
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
  echo "Reports saved in /tmp/wipe_report_*"
}

# Run main function
main "$@"
