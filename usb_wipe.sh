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

# Get list of all disk drives
get_drives() {
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Find all disk drives
    local device_list
    if device_list=$(diskutil list 2>/dev/null | grep -E "^/dev/disk[0-9]+" | awk '{print $1}'); then
      echo "$device_list" | while read -r device; do
        if [[ -n "$device" && "$device" =~ /dev/disk[0-9]+$ && -r "$device" ]]; then
          echo "$device"
        fi
      done
    fi
  else
    # Linux: Find all disk drives
    local lsblk_output
    if lsblk_output=$(lsblk -d -n -o NAME,TYPE 2>/dev/null); then
      echo "$lsblk_output" | while read -r line; do
        if [[ -n "$line" ]]; then
          local name=$(echo "$line" | awk '{print $1}')
          local type=$(echo "$line" | awk '{print $2}')

          if [[ "$type" == "disk" ]]; then
            echo "/dev/$name"
          fi
        fi
      done
    fi
  fi
}

# Get drive info with better USB detection
get_drive_info() {
  local device="$1"
  local vendor="Unknown"
  local model="Unknown"
  local size="Unknown"
  local connection="Unknown"

  if [[ "$(uname)" == "Darwin" ]]; then
    local info=$(diskutil info "$device" 2>/dev/null || echo "")
    vendor=$(echo "$info" | grep "Device / Media Name" | sed 's/.*: *//' | awk '{print $1}' || echo "Unknown")
    model=$(echo "$info" | grep "Device Model" | sed 's/.*: *//' || echo "Unknown")
    size=$(echo "$info" | grep "Disk Size" | sed 's/.*: *//' | awk '{print $1" "$2}' || echo "Unknown")
    connection=$(echo "$info" | grep "Protocol" | sed 's/.*: *//' || echo "Unknown")
  else
    vendor=$(lsblk -d -no vendor "$device" 2>/dev/null | xargs || echo "Unknown")
    model=$(lsblk -d -no model "$device" 2>/dev/null | xargs || echo "Unknown")
    size=$(lsblk -d -no size "$device" 2>/dev/null || echo "Unknown")

    # Check if it's USB connected
    local device_name=$(basename "$device")
    if udevadm info --query=property --name="$device" 2>/dev/null | grep -q "ID_BUS=usb"; then
      connection="USB"
    elif [[ -e "/sys/block/$device_name/removable" ]] && [[ "$(cat /sys/block/$device_name/removable 2>/dev/null)" == "1" ]]; then
      connection="Removable"
    else
      connection="Internal"
    fi
  fi

  echo "$vendor|$model|$size|$connection"
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

# Display drives with connection info
display_drives() {
  local drives=("$@")

  clear
  echo -e "${BOLD}${BLUE}USB Drive Wiper - Available Drives${NC}"
  echo "========================================"
  echo

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No drives found.${NC}"
    return 1
  fi

  for i in "${!drives[@]}"; do
    local device="${drives[$i]}"
    local info=$(get_drive_info "$device")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local connection=$(echo "$info" | cut -d'|' -f4)
    local num=$((i + 1))

    # Color code based on safety and connection type
    if is_safe_drive "$device"; then
      if [[ "$connection" == "USB" ]]; then
        echo -e "${GREEN}[$num]${NC} $device - $vendor $model ($size) ${GREEN}[USB - SAFE]${NC}"
      elif [[ "$connection" == "Removable" ]]; then
        echo -e "${GREEN}[$num]${NC} $device - $vendor $model ($size) ${GREEN}[REMOVABLE - SAFE]${NC}"
      else
        echo -e "${YELLOW}[$num]${NC} $device - $vendor $model ($size) ${YELLOW}[INTERNAL - CAUTION]${NC}"
      fi
    else
      echo -e "${RED}[$num]${NC} $device - $vendor $model ($size) ${RED}[SYSTEM - DANGEROUS]${NC}"
    fi
  done
  echo
  return 0
}

# Get user selection
get_selection() {
  local drives=("$@")

  while true; do
    display_drives "${drives[@]}"

    echo -e "${BOLD}Selection Instructions:${NC}"
    echo "• Enter drive numbers separated by spaces (example: 2 3 4 5)"
    echo "• Type 'q' to quit"
    echo "• Avoid DANGEROUS drives (likely system drives)"
    echo "• CAUTION drives need careful verification"
    echo
    echo -n "Your selection: "
    read -r selection

    if [[ "$selection" == "q" ]]; then
      exit 0
    fi

    local selected=()
    local valid=true

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
      if ! is_safe_drive "$device"; then
        echo -e "${RED}WARNING: $device appears to be a system drive!${NC}"
        echo -n "Are you sure you want to include this DANGEROUS drive? (type 'YES' to confirm): "
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
      echo "  $drive"
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
    local connection=$(echo "$info" | cut -d'|' -f4)
    echo -e "  ${YELLOW}$drive${NC} - $vendor $model ($size) [$connection]"
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

  echo "Scanning for removable drives..."
  mapfile -t drives < <(get_drives "auto")

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No removable drives found automatically.${NC}"
    echo
    echo "This could mean:"
    echo "- No USB drives are connected"
    echo "- USB drives appear as internal (common with adapters/VMs)"
    echo "- USB passthrough issues in VM"
    echo
    echo -n "Would you like to see ALL disk drives for manual selection? (y/N): "
    read -r manual_mode

    if [[ "$manual_mode" =~ ^[Yy]$ ]]; then
      echo "Scanning all disk drives..."
      mapfile -t drives < <(get_drives "manual")

      if [[ ${#drives[@]} -eq 0 ]]; then
        echo -e "${RED}No disk drives found at all!${NC}"
        echo "Check if running as root: sudo $0"
        exit 1
      fi

      echo -e "${BOLD}${RED}MANUAL MODE - BE VERY CAREFUL!${NC}"
      echo -e "${RED}You will see ALL disk drives including system drives.${NC}"
      echo -e "${RED}Double-check your selections!${NC}"
      echo
      echo "Press Enter to continue..."
      read -r
    else
      echo "Exiting. Make sure USB drives are properly connected."
      exit 0
    fi
  fi

  # Display drives and get user selection
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
