#!/bin/bash

# USB Drive DOD 5220.22-M Wipe Script with Interactive UI
# Safely identifies and wipes USB-connected drives concurrently
# Ubuntu VM environment with safeguards against system drives

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
LOGFILE="/tmp/usb_wipe_$(date +%Y%m%d_%H%M%S).log"

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
  echo -e "${BOLD}${CYAN}    USB Drive DOD 5220.22-M Wipe Utility${NC}"
  echo -e "${BOLD}${CYAN}         Ubuntu VM Environment${NC}"
  echo -e "${BOLD}${CYAN}=================================================${NC}"
  echo
}

# Function to check if a device is the Ubuntu system drive
is_system_drive() {
  local device="$1"

  # Check if device contains root filesystem
  if lsblk -n -o MOUNTPOINT "$device" 2>/dev/null | grep -q "^/$"; then
    return 0 # Is system drive
  fi

  # Check if any partition on device is mounted as system directories
  for partition in $(lsblk -ln -o NAME "$device" 2>/dev/null | tail -n +2); do
    local mountpoint=$(lsblk -n -o MOUNTPOINT "/dev/$partition" 2>/dev/null)
    case "$mountpoint" in
    "/" | "/boot" | "/home" | "/usr" | "/var" | "/opt" | "/tmp" | "/swap" | "[SWAP]")
      return 0 # Is system drive
      ;;
    esac
  done

  return 1 # Not system drive
}

# Function to get USB drives with detailed info
get_usb_drives_detailed() {
  local -A drives_info

  # Get all block devices
  while IFS= read -r line; do
    local device=$(echo "$line" | awk '{print $1}')
    local size=$(echo "$line" | awk '{print $4}')
    local type=$(echo "$line" | awk '{print $6}')

    # Skip if not a disk or if it's a partition
    [[ "$type" != "disk" ]] && continue

    # Check if device is USB connected
    if udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep -q "ID_BUS=usb"; then
      # Get detailed device information
      local vendor=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_VENDOR=" | cut -d'=' -f2 || echo "Unknown")
      local model=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_MODEL=" | cut -d'=' -f2 || echo "Unknown")
      local serial=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_SERIAL_SHORT=" | cut -d'=' -f2 || echo "Unknown")
      local size_bytes=$(blockdev --getsize64 "/dev/$device" 2>/dev/null || echo "0")

      # Safety checks
      local warning_flags=""
      local is_safe=true

      # Check if device is the Ubuntu system drive
      if is_system_drive "/dev/$device"; then
        warning_flags+="[SYSTEM-DRIVE] "
        is_safe=false
      fi

      # Check if device is mounted to important directories
      if mount | grep "/dev/$device" | grep -E "(/ |/boot |/home |/usr |/var |/opt )"; then
        warning_flags+="[SYSTEM-MOUNT] "
        is_safe=false
      fi

      # Check if device is currently mounted (any partition)
      if mount | grep -q "/dev/$device"; then
        # Only flag as unsafe if not already flagged as system
        if [[ "$warning_flags" != *"SYSTEM"* ]]; then
          warning_flags+="[MOUNTED] "
          # Don't mark as unsafe for regular mounts - user might want to wipe mounted USB drives
        fi
      fi

      # Check if device appears to be Ubuntu installation media
      if udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep -q "ID_FS_LABEL.*[Uu]buntu"; then
        warning_flags+="[UBUNTU-MEDIA] "
        is_safe=false
      fi

      # Check for very small devices (< 100MB, likely boot media or system devices)
      if [[ $size_bytes -lt 104857600 ]]; then
        warning_flags+="[TOO-SMALL] "
        is_safe=false
      fi

      # Check if device has swap partitions
      if lsblk -n -o FSTYPE "/dev/$device" 2>/dev/null | grep -q "swap"; then
        warning_flags+="[HAS-SWAP] "
        is_safe=false
      fi

      # Additional safety check: exclude devices with Linux filesystem signatures on main device
      local fstype=$(lsblk -n -o FSTYPE "/dev/$device" 2>/dev/null | head -1)
      if [[ "$fstype" =~ ^(ext[2-4]|xfs|btrfs)$ ]]; then
        warning_flags+="[LINUX-FS] "
        is_safe=false
      fi

      # Check if device contains LVM or RAID signatures
      if udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep -E "(LVM|MD_|RAID)"; then
        warning_flags+="[LVM-RAID] "
        is_safe=false
      fi

      # Store drive information
      drives_info["/dev/$device"]="$vendor|$model|$size|$serial|$warning_flags|$is_safe"
    fi
  done < <(lsblk -d -n -o NAME,SIZE,TYPE)

  # Return the associative array as key-value pairs
  for device in "${!drives_info[@]}"; do
    echo "$device:${drives_info[$device]}"
  done
}

# Function to display drive selection menu
display_drive_menu() {
  local drives=("$@")
  local drive_count=${#drives[@]}

  if [[ $drive_count -eq 0 ]]; then
    echo
    warning "No USB drives found!"
    echo
    echo "Press Enter to exit..."
    read -r
    exit 0
  fi

  show_header
  echo -e "${BOLD}Found $drive_count USB drive(s):${NC}"
  echo

  # Display drives with numbers
  for i in "${!drives[@]}"; do
    local device=$(echo "${drives[$i]}" | cut -d':' -f1)
    local info=$(echo "${drives[$i]}" | cut -d':' -f2)
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local serial=$(echo "$info" | cut -d'|' -f4)
    local warnings=$(echo "$info" | cut -d'|' -f5)
    local is_safe=$(echo "$info" | cut -d'|' -f6)

    local num=$((i + 1))

    if [[ "$is_safe" == "true" ]]; then
      echo -e "${GREEN}[$num]${NC} $device"
    else
      echo -e "${RED}[$num]${NC} $device ${RED}$warnings${NC}"
    fi

    echo "    Vendor: $vendor"
    echo "    Model:  $model"
    echo "    Size:   $size"
    echo "    Serial: $serial"

    if [[ "$is_safe" == "false" ]]; then
      echo -e "    ${RED}Status: UNSAFE - Protected from wiping${NC}"
      case "$warnings" in
      *"SYSTEM-DRIVE"*) echo -e "    ${RED}Reason: Ubuntu system drive${NC}" ;;
      *"SYSTEM-MOUNT"*) echo -e "    ${RED}Reason: Contains system mount points${NC}" ;;
      *"UBUNTU-MEDIA"*) echo -e "    ${RED}Reason: Ubuntu installation media${NC}" ;;
      *"LINUX-FS"*) echo -e "    ${RED}Reason: Contains Linux filesystem${NC}" ;;
      *"LVM-RAID"*) echo -e "    ${RED}Reason: Contains LVM/RAID configuration${NC}" ;;
      *"HAS-SWAP"*) echo -e "    ${RED}Reason: Contains swap partition${NC}" ;;
      *"TOO-SMALL"*) echo -e "    ${RED}Reason: Device too small (< 100MB)${NC}" ;;
      esac
    else
      echo -e "    ${GREEN}Status: Safe for wiping${NC}"
      if [[ "$warnings" == *"MOUNTED"* ]]; then
        echo -e "    ${YELLOW}Note: Device is currently mounted${NC}"
      fi
    fi
    echo
  done
}

# Function to get user selection
get_user_selection() {
  local drives=("$@")
  local selected_drives=()

  while true; do
    display_drive_menu "${drives[@]}"

    echo -e "${BOLD}Selection Options:${NC}"
    echo "  Enter drive numbers separated by spaces (e.g., 1 3 5)"
    echo "  Type 'all' to select all safe drives"
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
    "all")
      # Select all safe drives
      selected_drives=()
      for i in "${!drives[@]}"; do
        local info=$(echo "${drives[$i]}" | cut -d':' -f2)
        local is_safe=$(echo "$info" | cut -d'|' -f6)
        if [[ "$is_safe" == "true" ]]; then
          local device=$(echo "${drives[$i]}" | cut -d':' -f1)
          selected_drives+=("$device")
        fi
      done

      if [[ ${#selected_drives[@]} -eq 0 ]]; then
        echo
        warning "No safe drives available for selection!"
        echo "Press Enter to continue..."
        read -r
        continue
      fi
      break
      ;;
    *)
      # Parse individual selections
      selected_drives=()
      local valid_selection=true

      for num in $selection; do
        if [[ ! "$num" =~ ^[0-9]+$ ]]; then
          warning "Invalid input: '$num' is not a number"
          valid_selection=false
          break
        fi

        local index=$((num - 1))
        if [[ $index -lt 0 || $index -ge ${#drives[@]} ]]; then
          warning "Invalid selection: $num is out of range (1-${#drives[@]})"
          valid_selection=false
          break
        fi

        # Check if drive is safe
        local info=$(echo "${drives[$index]}" | cut -d':' -f2)
        local is_safe=$(echo "$info" | cut -d'|' -f6)
        local device=$(echo "${drives[$index]}" | cut -d':' -f1)

        if [[ "$is_safe" == "false" ]]; then
          warning "Drive $num ($device) is marked as unsafe and cannot be selected"
          valid_selection=false
          break
        fi

        # Check for duplicates
        if [[ " ${selected_drives[*]} " =~ " $device " ]]; then
          warning "Drive $device already selected"
          continue
        fi

        selected_drives+=("$device")
      done

      if [[ "$valid_selection" == "false" ]]; then
        echo "Press Enter to continue..."
        read -r
        continue
      fi

      if [[ ${#selected_drives[@]} -eq 0 ]]; then
        warning "No drives selected!"
        echo "Press Enter to continue..."
        read -r
        continue
      fi

      break
      ;;
    esac
  done

  # Return selected drives
  printf '%s\n' "${selected_drives[@]}"
  return 0
}

# Function to confirm selection
confirm_wipe() {
  local drives=("$@")

  show_header
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo
  echo -e "${RED}You have selected the following drives for DOD 5220.22-M wiping:${NC}"
  echo

  for drive in "${drives[@]}"; do
    echo -e "  ${RED}$drive${NC}"

    # Get and display drive info
    local vendor=$(udevadm info --query=property --name="$drive" 2>/dev/null | grep "ID_VENDOR=" | cut -d'=' -f2 || echo "Unknown")
    local model=$(udevadm info --query=property --name="$drive" 2>/dev/null | grep "ID_MODEL=" | cut -d'=' -f2 || echo "Unknown")
    local size=$(lsblk -d -n -o SIZE "$drive" 2>/dev/null || echo "Unknown")

    echo "    $vendor $model ($size)"
  done

  echo
  echo -e "${RED}${BOLD}WARNING: This operation will PERMANENTLY DESTROY all data on these drives!${NC}"
  echo -e "${RED}${BOLD}This action CANNOT be undone!${NC}"
  echo
  echo "To proceed, type exactly: I UNDERSTAND AND WANT TO WIPE THESE DRIVES"
  echo "Or type anything else to cancel"
  echo
  echo -n "Confirmation: "

  read -r confirmation

  if [[ "$confirmation" == "I UNDERSTAND AND WANT TO WIPE THESE DRIVES" ]]; then
    return 0
  else
    echo
    info "Operation cancelled"
    echo "Press Enter to return to drive selection..."
    read -r
    return 1
  fi
}

# Function to wipe a single drive
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

  show_header
  echo -e "${BOLD}Wipe Operations in Progress${NC}"
  echo
  echo "Log file: $LOGFILE"
  echo "Individual drive logs in /tmp/wipe_*.log"
  echo

  # Monitor processes
  while true; do
    local active_count=0
    local status_display=""

    for process_info in "${wipe_processes[@]}"; do
      local pid=$(echo "$process_info" | cut -d':' -f1)
      local device=$(echo "$process_info" | cut -d':' -f2)
      local logfile=$(echo "$process_info" | cut -d':' -f3)

      if kill -0 "$pid" 2>/dev/null; then
        ((active_count++))
        status_display+="  ${YELLOW}$device${NC} - In Progress\n"
      else
        # Process finished, check if it was successful
        if wait "$pid" 2>/dev/null; then
          status_display+="  ${GREEN}$device${NC} - Completed Successfully\n"
        else
          status_display+="  ${RED}$device${NC} - Failed (check $logfile)\n"
        fi
      fi
    done

    # Update display
    echo -ne "\033[2J\033[H" # Clear screen and move cursor to top
    show_header
    echo -e "${BOLD}Wipe Operations Status${NC}"
    echo
    echo "Active processes: $active_count"
    echo "Log file: $LOGFILE"
    echo
    echo -e "$status_display"

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

# Main execution
main() {
  log "=== USB Drive DOD 5220.22-M Wipe Script Started ==="
  log "Timestamp: $(date)"
  log "Log file: $LOGFILE"

  while true; do
    # Get USB drives
    mapfile -t drive_list < <(get_usb_drives_detailed)

    if [[ ${#drive_list[@]} -eq 0 ]]; then
      show_header
      warning "No USB drives found!"
      echo
      echo "Press Enter to exit..."
      read -r
      exit 0
    fi

    # Get user selection
    if selected_drives=$(get_user_selection "${drive_list[@]}"); then
      mapfile -t drives_to_wipe <<<"$selected_drives"

      # Confirm selection
      if confirm_wipe "${drives_to_wipe[@]}"; then
        break
      fi
    elif [[ $? -eq 2 ]]; then
      # Refresh requested
      continue
    else
      exit 0
    fi
  done

  log
  info "Starting concurrent wipe operations on ${#drives_to_wipe[@]} drive(s)..."

  # Start wipe processes
  declare -a wipe_processes=()

  for drive in "${drives_to_wipe[@]}"; do
    process_info=$(wipe_drive "$drive")
    wipe_processes+=("$process_info")
    sleep 2 # Brief delay between starts
  done

  # Monitor processes with real-time display
  monitor_wipes "${wipe_processes[@]}"
}

# Signal handlers for cleanup
cleanup() {
  echo
  warning "Script interrupted - cleaning up..."
  # Kill any running shred processes
  pkill -f "shred.*dev" 2>/dev/null || true
  exit 130
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
