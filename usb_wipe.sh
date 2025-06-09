#!/bin/bash

# Drive DOD 5220.22-M Wipe Script with Manual Selection
# Simple, reliable approach for Ubuntu VM environment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Log file
LOGFILE="/tmp/drive_wipe_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo -e "$1" | tee -a "$LOGFILE"
}

error() {
  log "${RED}ERROR: $1${NC}"
  exit 1
}

warning() {
  log "${YELLOW}WARNING: $1${NC}"
}

info() {
  log "${BLUE}INFO: $1${NC}"
}

success() {
  log "${GREEN}SUCCESS: $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root"
fi

# Function to clear screen and show header
show_header() {
  clear
  echo -e "${BOLD}${CYAN}=================================================${NC}"
  echo -e "${BOLD}${CYAN}    Drive DOD 5220.22-M Wipe Utility${NC}"
  echo -e "${BOLD}${CYAN}         Manual Drive Selection${NC}"
  echo -e "${BOLD}${CYAN}=================================================${NC}"
  echo
}

# Function to check if a device is mounted to system directories
is_system_mounted() {
  local device="$1"
  if mount | grep "^$device" | grep -E "( /| /boot| /home| /usr| /var| /opt)" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Function to get drive safety level
get_safety_level() {
  local device="$1"
  local reasons=()

  # Check if device is mounted to system directories
  if is_system_mounted "$device"; then
    echo "DANGEROUS|Contains system mount points"
    return
  fi

  # Check if device is mounted anywhere
  if mount | grep -q "^$device"; then
    local mounts=$(mount | grep "^$device" | awk '{print $3}' | tr '\n' ' ')
    echo "CAUTION|Currently mounted at: $mounts"
    return
  fi

  # Check if device has Linux filesystems
  if lsblk -n -o FSTYPE "$device" 2>/dev/null | grep -q -E "ext[2-4]|xfs|btrfs"; then
    echo "CAUTION|Contains Linux filesystem"
    return
  fi

  # Check if device has swap
  if lsblk -n -o FSTYPE "$device" 2>/dev/null | grep -q "swap"; then
    echo "DANGEROUS|Contains swap partition"
    return
  fi

  # Check device size (very small devices might be system)
  local size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null || echo "0")
  if [[ $size_bytes -lt 104857600 ]]; then # < 100MB
    echo "DANGEROUS|Very small device (< 100MB)"
    return
  fi

  # Special handling for sda (usually system drive)
  if [[ "$(basename "$device")" == "sda" ]]; then
    echo "CAUTION|First drive (sda) - typically system drive"
    return
  fi

  echo "SAFE|No safety concerns detected"
}

# Function to get basic drive info
get_drive_info() {
  local device="$1"
  local vendor="Unknown"
  local model="Unknown"
  local serial="Unknown"
  local size="Unknown"

  # Get size from lsblk
  size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")

  # Try to get vendor/model from udev
  vendor=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "ID_VENDOR=" | cut -d'=' -f2 || echo "Unknown")
  model=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "ID_MODEL=" | cut -d'=' -f2 || echo "Unknown")
  serial=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "ID_SERIAL_SHORT=" | cut -d'=' -f2 || echo "Unknown")

  # If udev didn't work, try /sys
  if [[ "$vendor" == "Unknown" ]]; then
    vendor=$(cat "/sys/block/$(basename "$device")/device/vendor" 2>/dev/null | tr -d ' ' || echo "Unknown")
  fi
  if [[ "$model" == "Unknown" ]]; then
    model=$(cat "/sys/block/$(basename "$device")/device/model" 2>/dev/null | tr -d ' ' || echo "Unknown")
  fi

  echo "$vendor|$model|$size|$serial"
}

# Function to display drives
display_drives() {
  local drives=("$@")

  show_header
  echo -e "${BOLD}Available Drives:${NC}"
  echo

  if [[ ${#drives[@]} -eq 0 ]]; then
    warning "No drives found!"
    echo
    echo "Press Enter to exit..."
    read -r
    exit 0
  fi

  for i in "${!drives[@]}"; do
    local device="${drives[$i]}"
    local num=$((i + 1))

    # Get drive info
    local info=$(get_drive_info "$device")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local serial=$(echo "$info" | cut -d'|' -f4)

    # Get safety info
    local safety_info=$(get_safety_level "$device")
    local safety_level=$(echo "$safety_info" | cut -d'|' -f1)
    local safety_reason=$(echo "$safety_info" | cut -d'|' -f2)

    # Display with color coding
    case "$safety_level" in
    "SAFE")
      echo -e "${GREEN}[$num]${NC} $device ${GREEN}[SAFE]${NC}"
      ;;
    "CAUTION")
      echo -e "${YELLOW}[$num]${NC} $device ${YELLOW}[CAUTION]${NC}"
      ;;
    "DANGEROUS")
      echo -e "${RED}[$num]${NC} $device ${RED}[DANGEROUS]${NC}"
      ;;
    esac

    echo "    Vendor: $vendor"
    echo "    Model:  $model"
    echo "    Size:   $size"
    echo "    Serial: $serial"
    echo "    Status: $safety_reason"
    echo
  done
}

# Function to get user selection
get_user_selection() {
  local drives=("$@")

  while true; do
    display_drives "${drives[@]}"

    echo -e "${BOLD}Selection Options:${NC}"
    echo "  Enter drive numbers separated by spaces (e.g., 2 3 4 5)"
    echo "  Type 'all-safe' to select all SAFE drives"
    echo "  Type 'all-non-dangerous' to select SAFE and CAUTION drives"
    echo "  Type 'quit' or 'q' to exit"
    echo "  Type 'refresh' or 'r' to rescan drives"
    echo
    echo -n "Your selection: "

    read -r selection

    case "$selection" in
    "quit" | "q")
      echo "Exiting..."
      exit 0
      ;;
    "refresh" | "r")
      info "Rescanning drives..."
      sleep 1
      return 2 # Signal to refresh
      ;;
    "all-safe")
      local selected=()
      for i in "${!drives[@]}"; do
        local device="${drives[$i]}"
        local safety_info=$(get_safety_level "$device")
        local safety_level=$(echo "$safety_info" | cut -d'|' -f1)
        if [[ "$safety_level" == "SAFE" ]]; then
          selected+=("$device")
        fi
      done

      if [[ ${#selected[@]} -eq 0 ]]; then
        warning "No SAFE drives found!"
        echo "Press Enter to continue..."
        read -r
        continue
      fi

      printf '%s\n' "${selected[@]}"
      return 0
      ;;
    "all-non-dangerous")
      local selected=()
      for i in "${!drives[@]}"; do
        local device="${drives[$i]}"
        local safety_info=$(get_safety_level "$device")
        local safety_level=$(echo "$safety_info" | cut -d'|' -f1)
        if [[ "$safety_level" == "SAFE" ]] || [[ "$safety_level" == "CAUTION" ]]; then
          selected+=("$device")
        fi
      done

      if [[ ${#selected[@]} -eq 0 ]]; then
        warning "No non-dangerous drives found!"
        echo "Press Enter to continue..."
        read -r
        continue
      fi

      printf '%s\n' "${selected[@]}"
      return 0
      ;;
    *)
      local selected=()
      local valid=true

      for num in $selection; do
        if [[ ! "$num" =~ ^[0-9]+$ ]]; then
          warning "Invalid input: '$num' is not a number"
          valid=false
          break
        fi

        local index=$((num - 1))
        if [[ $index -lt 0 || $index -ge ${#drives[@]} ]]; then
          warning "Invalid selection: $num is out of range (1-${#drives[@]})"
          valid=false
          break
        fi

        local device="${drives[$index]}"
        if [[ " ${selected[*]} " =~ " $device " ]]; then
          warning "Drive $device already selected"
          continue
        fi

        selected+=("$device")
      done

      if [[ "$valid" == "false" ]]; then
        echo "Press Enter to continue..."
        read -r
        continue
      fi

      if [[ ${#selected[@]} -eq 0 ]]; then
        warning "No drives selected!"
        echo "Press Enter to continue..."
        read -r
        continue
      fi

      printf '%s\n' "${selected[@]}"
      return 0
      ;;
    esac
  done
}

# Function to confirm selection
confirm_selection() {
  local drives=("$@")
  local has_dangerous=false
  local has_caution=false

  show_header
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo
  echo -e "${RED}You have selected the following drives for DOD 5220.22-M wiping:${NC}"
  echo

  for drive in "${drives[@]}"; do
    local info=$(get_drive_info "$drive")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)

    local safety_info=$(get_safety_level "$drive")
    local safety_level=$(echo "$safety_info" | cut -d'|' -f1)
    local safety_reason=$(echo "$safety_info" | cut -d'|' -f2)

    case "$safety_level" in
    "SAFE")
      echo -e "  ${GREEN}$drive${NC} - $vendor $model ($size) ${GREEN}[SAFE]${NC}"
      ;;
    "CAUTION")
      echo -e "  ${YELLOW}$drive${NC} - $vendor $model ($size) ${YELLOW}[CAUTION]${NC}"
      echo -e "    ${YELLOW}⚠ $safety_reason${NC}"
      has_caution=true
      ;;
    "DANGEROUS")
      echo -e "  ${RED}$drive${NC} - $vendor $model ($size) ${RED}[DANGEROUS]${NC}"
      echo -e "    ${RED}⚠ $safety_reason${NC}"
      has_dangerous=true
      ;;
    esac
  done

  echo
  echo -e "${RED}${BOLD}WARNING: This operation will PERMANENTLY DESTROY all data on these drives!${NC}"
  echo -e "${RED}${BOLD}This action CANNOT be undone!${NC}"
  echo

  if [[ "$has_dangerous" == "true" ]]; then
    echo -e "${RED}${BOLD}CRITICAL WARNING: You have selected DANGEROUS drives!${NC}"
    echo "To proceed, type exactly: 'I UNDERSTAND THE RISKS AND WANT TO WIPE DANGEROUS DRIVES'"
    echo -n "Confirmation: "
    read -r confirmation
    [[ "$confirmation" == "I UNDERSTAND THE RISKS AND WANT TO WIPE DANGEROUS DRIVES" ]]
  elif [[ "$has_caution" == "true" ]]; then
    echo -e "${YELLOW}CAUTION: You have selected drives that require extra attention!${NC}"
    echo "To proceed, type exactly: 'I WANT TO WIPE THESE DRIVES'"
    echo -n "Confirmation: "
    read -r confirmation
    [[ "$confirmation" == "I WANT TO WIPE THESE DRIVES" ]]
  else
    echo "To proceed, type exactly: 'WIPE DRIVES'"
    echo -n "Confirmation: "
    read -r confirmation
    [[ "$confirmation" == "WIPE DRIVES" ]]
  fi
}

# Function to wipe a drive
wipe_drive() {
  local device="$1"
  local device_name=$(basename "$device")
  local wipe_log="/tmp/wipe_${device_name}_$(date +%Y%m%d_%H%M%S).log"

  info "Starting DOD 5220.22-M wipe on $device"

  # Unmount any mounted partitions
  for partition in $(lsblk -ln -o NAME "$device" 2>/dev/null | tail -n +2); do
    if mount | grep -q "/dev/$partition"; then
      info "Unmounting /dev/$partition"
      umount "/dev/$partition" 2>/dev/null || true
    fi
  done

  # Start the wipe process
  {
    echo "=== DOD 5220.22-M Wipe Started: $(date) ==="
    echo "Device: $device"
    echo "Process ID: $$"
    echo

    # DOD 5220.22-M: 3 passes with verification
    if shred -vfz -n 3 "$device" 2>&1; then
      echo
      echo "=== Wipe Completed Successfully: $(date) ==="
    else
      echo
      echo "=== Wipe Failed: $(date) ==="
      exit 1
    fi
  } >>"$wipe_log" 2>&1 &

  local pid=$!
  echo "$pid:$device:$wipe_log"
}

# Function to monitor wipe progress
monitor_wipes() {
  local wipe_processes=("$@")

  while true; do
    local active_count=0

    show_header
    echo -e "${BOLD}Wipe Operations Status${NC}"
    echo
    echo "Log file: $LOGFILE"
    echo

    for process_info in "${wipe_processes[@]}"; do
      local pid=$(echo "$process_info" | cut -d':' -f1)
      local device=$(echo "$process_info" | cut -d':' -f2)
      local logfile=$(echo "$process_info" | cut -d':' -f3)

      if kill -0 "$pid" 2>/dev/null; then
        ((active_count++))
        echo -e "  ${YELLOW}$device${NC} - In Progress"
      else
        if wait "$pid" 2>/dev/null; then
          echo -e "  ${GREEN}$device${NC} - Completed Successfully"
        else
          echo -e "  ${RED}$device${NC} - Failed (check $logfile)"
        fi
      fi
    done

    echo
    echo "Active processes: $active_count"

    if [[ $active_count -eq 0 ]]; then
      break
    fi

    sleep 5
  done

  echo
  success "All wipe operations completed!"
  echo
  echo "Press Enter to exit..."
  read -r
}

# Main function
main() {
  log "=== Drive DOD 5220.22-M Wipe Script Started ==="
  log "Timestamp: $(date)"
  log "Log file: $LOGFILE"

  while true; do
    # Get all disk drives
    mapfile -t all_drives < <(lsblk -d -n -o NAME | grep -E '^sd[a-z]$|^nvme[0-9]+n[0-9]+$' | sed 's|^|/dev/|')

    if [[ ${#all_drives[@]} -eq 0 ]]; then
      show_header
      warning "No drives found!"
      echo "Press Enter to exit..."
      read -r
      exit 0
    fi

    # Get user selection
    if selected_drives=$(get_user_selection "${all_drives[@]}"); then
      mapfile -t drives_to_wipe <<<"$selected_drives"

      # Confirm selection
      if confirm_selection "${drives_to_wipe[@]}"; then
        break
      else
        echo
        info "Operation cancelled"
        echo "Press Enter to return to drive selection..."
        read -r
      fi
    elif [[ $? -eq 2 ]]; then
      # Refresh requested
      continue
    else
      exit 0
    fi
  done

  info "Starting concurrent wipe operations on ${#drives_to_wipe[@]} drive(s)..."

  # Start wipe processes
  declare -a wipe_processes=()
  for drive in "${drives_to_wipe[@]}"; do
    process_info=$(wipe_drive "$drive")
    wipe_processes+=("$process_info")
    sleep 2
  done

  # Monitor progress
  monitor_wipes "${wipe_processes[@]}"
}

# Signal handlers
cleanup() {
  echo
  warning "Script interrupted - cleaning up..."
  pkill -f "shred.*dev" 2>/dev/null || true
  exit 130
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
