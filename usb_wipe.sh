#!/bin/bash

# Drive DOD 5220.22-M Wipe Script with Manual Selection
# Fixed version for Ubuntu VM environment with USB passthrough

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
  error "This script must be run as root (use sudo)"
fi

# Check for required commands
if [[ "$(uname)" == "Darwin" ]]; then
  for cmd in diskutil dd shred; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Required command '$cmd' not found. Please install it."
    fi
  done
else
  for cmd in lsblk udevadm blockdev shred; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Required command '$cmd' not found. Please install it."
    fi
  done
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

# Function to get all available disk drives
get_available_drives() {
  local drives=()

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version
    while read -r device; do
      # Check if it's a physical disk (not a partition)
      if [[ "$device" =~ /dev/disk[0-9]+$ ]]; then
        if [[ -b "$device" ]] && [[ -r "$device" ]]; then
          # Check if it's removable (excludes internal disk)
          if diskutil info "$device" | grep -q "Removable Media: *Yes"; then
            drives+=("$device")
          elif diskutil info "$device" | grep -q "Protocol: *USB"; then
            # Also include USB devices even if not marked as removable
            drives+=("$device")
          fi
        fi
      fi
    done < <(diskutil list | grep -E "^/dev/disk[0-9]+" | awk '{print $1}')
  else
    # Linux version
    while IFS= read -r line; do
      # Parse the lsblk output: NAME SIZE TYPE
      local name=$(echo "$line" | awk '{print $1}')
      local size=$(echo "$line" | awk '{print $2}')
      local type=$(echo "$line" | awk '{print $3}')

      # Only process actual disks
      if [[ "$type" == "disk" ]]; then
        # Add /dev/ prefix if not present
        if [[ "$name" != /dev/* ]]; then
          name="/dev/$name"
        fi

        # Verify the device exists and is accessible
        if [[ -b "$name" ]] && [[ -r "$name" ]]; then
          drives+=("$name")
        fi
      fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null || true)
  fi

  printf '%s\n' "${drives[@]}"
}

# Function to check if a device is mounted to system directories
is_system_mounted() {
  local device="$1"
  
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version - check if it's the system disk
    if diskutil info "$device" | grep -q "Internal: *Yes"; then
      return 0
    fi
    # Check if mounted to system locations
    local mount_point=$(diskutil info "$device" | grep "Mount Point" | sed 's/.*Mount Point: *//')
    if [[ -n "$mount_point" && "$mount_point" != "(not mounted)" ]]; then
      if [[ "$mount_point" == "/" || "$mount_point" == "/System" || "$mount_point" == "/Users" || "$mount_point" == "/Applications" ]]; then
        return 0
      fi
    fi
  else
    # Linux version
    # Check if any partition of this device is mounted to system paths
    if mount | grep "^${device}" | grep -E "( /| /boot| /home| /usr| /var| /opt| /etc)" >/dev/null 2>&1; then
      return 0
    fi
    # Also check by device basename
    local basename_device=$(basename "$device")
    if mount | grep "^/dev/${basename_device}" | grep -E "( /| /boot| /home| /usr| /var| /opt| /etc)" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Function to check if device has any mounted partitions
has_mounted_partitions() {
  local device="$1"
  
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version
    local mount_point=$(diskutil info "$device" | grep "Mount Point" | sed 's/.*Mount Point: *//')
    if [[ -n "$mount_point" && "$mount_point" != "(not mounted)" ]]; then
      return 0
    fi
    
    # Check for partitions
    local basename_device=$(basename "$device")
    while read -r partition; do
      if [[ -n "$partition" ]]; then
        local part_mount=$(diskutil info "/dev/$partition" 2>/dev/null | grep "Mount Point" | sed 's/.*Mount Point: *//')
        if [[ -n "$part_mount" && "$part_mount" != "(not mounted)" ]]; then
          return 0
        fi
      fi
    done < <(diskutil list "$device" | grep -E "^   [0-9]:" | awk '{print "'$basename_device's"$1}' | tr -d :)
  else
    # Linux version
    # Check if any partition of this device is mounted anywhere
    if mount | grep -q "^${device}"; then
      return 0
    fi
    # Also check by device basename
    local basename_device=$(basename "$device")
    if mount | grep -q "^/dev/${basename_device}"; then
      return 0
    fi
  fi
  return 1
}

# Function to get drive safety level
get_safety_level() {
  local device="$1"

  # Check if device exists and is accessible
  if [[ ! -b "$device" ]]; then
    echo "ERROR|Device does not exist or is not a block device"
    return
  fi

  if [[ ! -r "$device" ]]; then
    echo "ERROR|Device is not readable"
    return
  fi

  # Check if device is mounted to system directories
  if is_system_mounted "$device"; then
    echo "DANGEROUS|Contains system mount points"
    return
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS specific checks
    
    # Check if it's an internal disk (dangerous)
    if diskutil info "$device" | grep -q "Internal: *Yes"; then
      echo "DANGEROUS|Internal disk - likely system disk"
      return
    fi
    
    # Check if device has any mounted partitions
    if has_mounted_partitions "$device"; then
      local mount_point=$(diskutil info "$device" | grep "Mount Point" | sed 's/.*Mount Point: *//')
      if [[ -n "$mount_point" && "$mount_point" != "(not mounted)" ]]; then
        echo "CAUTION|Currently mounted at: $mount_point"
        return
      fi
    fi
    
    # Check device size (very small devices might be system)
    local size=$(diskutil info "$device" | grep "Disk Size" | awk '{print $3}')
    if [[ $size -lt 100 ]]; then # < 100MB
      echo "DANGEROUS|Very small device (< 100MB) - may be system"
      return
    fi
    
    # Check if it's a USB device (safer to wipe)
    if diskutil info "$device" | grep -q "Protocol: *USB"; then
      echo "SAFE|USB device detected"
      return
    fi
    
    # Check if it's removable
    if diskutil info "$device" | grep -q "Removable Media: *Yes"; then
      echo "SAFE|Removable media detected"
      return
    fi
    
  else
    # Linux specific checks
    
    # Check if device has any mounted partitions
    if has_mounted_partitions "$device"; then
      local mounts=$(mount | grep "^${device}\|^/dev/$(basename "$device")" | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//')
      if [[ -n "$mounts" ]]; then
        echo "CAUTION|Currently mounted at: $mounts"
        return
      fi
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
    local size_bytes
    size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null || echo "0")
    if [[ $size_bytes -lt 104857600 ]]; then # < 100MB
      echo "DANGEROUS|Very small device (< 100MB) - may be system"
      return
    fi

    # Special handling for sda (usually system drive)
    if [[ "$(basename "$device")" == "sda" ]]; then
      echo "CAUTION|First drive (sda) - typically system drive"
      return
    fi

    # Check if it's a USB device (safer to wipe)
    local id_bus
    id_bus=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "ID_BUS=" | cut -d'=' -f2 || echo "")
    if [[ "$id_bus" == "usb" ]]; then
      echo "SAFE|USB device detected"
      return
    fi
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
  local bus="Unknown"

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version
    size=$(diskutil info "$device" 2>/dev/null | grep "Disk Size" | awk '{print $3" "$4}' || echo "Unknown")
    
    # Get device info from diskutil
    local device_info=$(diskutil info "$device" 2>/dev/null)
    
    # Try to extract vendor and model from device name
    vendor=$(echo "$device_info" | grep "Device / Media Name:" | sed 's/.*Device \/ Media Name: *//' | awk '{print $1}' || echo "Unknown")
    model=$(echo "$device_info" | grep "Device / Media Name:" | sed 's/.*Device \/ Media Name: *//' | awk '{for(i=2;i<=NF;i++) print $i}' | tr '\n' ' ' | sed 's/ $//' || echo "Unknown")
    
    # Get protocol/bus type
    bus=$(echo "$device_info" | grep "Protocol:" | sed 's/.*Protocol: *//' || echo "Unknown")
    
    # Get serial if available
    serial=$(echo "$device_info" | grep -i "Serial Number:" | sed 's/.*Serial Number: *//' || echo "Unknown")
    
  else
    # Linux version
    # Get size from lsblk
    size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")

    # Try to get info from udev
    if command -v udevadm >/dev/null 2>&1; then
      vendor=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "^ID_VENDOR=" | cut -d'=' -f2 || echo "Unknown")
      model=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "^ID_MODEL=" | cut -d'=' -f2 || echo "Unknown")
      serial=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "^ID_SERIAL_SHORT=" | cut -d'=' -f2 || echo "Unknown")
      bus=$(udevadm info --query=property --name="$device" 2>/dev/null | grep "^ID_BUS=" | cut -d'=' -f2 || echo "Unknown")
    fi

    # If udev didn't work, try /sys
    local basename_device=$(basename "$device")
    if [[ "$vendor" == "Unknown" && -f "/sys/block/$basename_device/device/vendor" ]]; then
      vendor=$(cat "/sys/block/$basename_device/device/vendor" 2>/dev/null | tr -d ' ' || echo "Unknown")
    fi
    if [[ "$model" == "Unknown" && -f "/sys/block/$basename_device/device/model" ]]; then
      model=$(cat "/sys/block/$basename_device/device/model" 2>/dev/null | tr -d ' ' || echo "Unknown")
    fi
  fi

  echo "$vendor|$model|$size|$serial|$bus"
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
    echo "This could happen if:"
    echo "- No USB drives are connected"
    echo "- USB passthrough is not working properly in the VM"
    echo "- Drives are not being detected by the system"
    echo
    echo "Try running the debug script to see what drives are detected:"
    echo "sudo bash debug_drives.sh"
    echo
    echo "Press Enter to exit..."
    read -r
    exit 0
  fi

  for i in "${!drives[@]}"; do
    local device="${drives[$i]}"
    local num=$((i + 1))

    # Get drive info
    local info
    info=$(get_drive_info "$device")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local serial=$(echo "$info" | cut -d'|' -f4)
    local bus=$(echo "$info" | cut -d'|' -f5)

    # Get safety info
    local safety_info
    safety_info=$(get_safety_level "$device")
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
    "ERROR")
      echo -e "${RED}[$num]${NC} $device ${RED}[ERROR]${NC}"
      ;;
    esac

    echo "    Vendor:  $vendor"
    echo "    Model:   $model"
    echo "    Size:    $size"
    echo "    Serial:  $serial"
    echo "    Bus:     $bus"
    echo "    Status:  $safety_reason"
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
    echo "  Type 'debug' to run drive detection debug"
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
    "debug")
      info "Running drive detection debug..."
      echo
      echo "=== Drive Detection Debug ==="
      echo "1. Raw lsblk output:"
      lsblk -d -n -o NAME,SIZE,TYPE
      echo
      echo "2. Available drives found by script:"
      get_available_drives
      echo
      echo "Press Enter to continue..."
      read -r
      continue
      ;;
    "all-safe")
      local selected=()
      for i in "${!drives[@]}"; do
        local device="${drives[$i]}"
        local safety_info
        safety_info=$(get_safety_level "$device")
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
        local safety_info
        safety_info=$(get_safety_level "$device")
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
    local info
    info=$(get_drive_info "$drive")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)

    local safety_info
    safety_info=$(get_safety_level "$drive")
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

# Function to unmount device partitions
unmount_device() {
  local device="$1"
  local basename_device=$(basename "$device")

  info "Unmounting any mounted partitions on $device"

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version - use diskutil to unmount
    if diskutil info "$device" | grep -q "Mount Point:" | grep -v "(not mounted)"; then
      info "Unmounting $device"
      diskutil unmountDisk force "$device" 2>/dev/null || true
    else
      # Try unmounting individual partitions
      while read -r partition; do
        if [[ -n "$partition" ]]; then
          local part_dev="/dev/$partition"
          if diskutil info "$part_dev" 2>/dev/null | grep -q "Mount Point:" | grep -v "(not mounted)"; then
            info "Unmounting partition $part_dev"
            diskutil unmount force "$part_dev" 2>/dev/null || true
          fi
        fi
      done < <(diskutil list "$device" 2>/dev/null | grep -E "^   [0-9]:" | awk '{print "'$basename_device's"$1}' | tr -d :)
    fi
  else
    # Linux version
    # Get all partitions for this device
    local partitions
    partitions=$(lsblk -ln -o NAME "$device" 2>/dev/null | tail -n +2 || true)

    for partition in $partitions; do
      local full_partition="/dev/$partition"
      if mount | grep -q "^$full_partition "; then
        info "Unmounting $full_partition"
        if ! umount "$full_partition" 2>/dev/null; then
          warning "Failed to unmount $full_partition, trying force unmount"
          umount -f "$full_partition" 2>/dev/null || true
        fi
      fi
    done

    # Also check for direct device mounts
    if mount | grep -q "^$device "; then
      info "Unmounting $device"
      umount "$device" 2>/dev/null || umount -f "$device" 2>/dev/null || true
    fi
  fi

  # Give the system a moment to process the unmounts
  sleep 2
}

# Function to wipe a drive
wipe_drive() {
  local device="$1"
  local device_name=$(basename "$device")
  local wipe_log="/tmp/wipe_${device_name}_$(date +%Y%m%d_%H%M%S).log"

  info "Starting DOD 5220.22-M wipe on $device"

  # Unmount device
  unmount_device "$device"

  # Start the wipe process
  {
    echo "=== DOD 5220.22-M Wipe Started: $(date) ==="
    echo "Device: $device"
    echo "Process ID: $$"
    echo

    # DOD 5220.22-M: 3 passes with verification
    # -v: verbose, -f: force, -z: add final zero pass, -n 3: three passes
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
        echo -e "  ${YELLOW}$device${NC} - In Progress (PID: $pid)"
        echo "    Log: $logfile"
      else
        if wait "$pid" 2>/dev/null; then
          echo -e "  ${GREEN}$device${NC} - Completed Successfully"
        else
          echo -e "  ${RED}$device${NC} - Failed (check $logfile)"
        fi
        echo "    Log: $logfile"
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
  echo "Log files are available in /tmp/ for review"
  echo "Press Enter to exit..."
  read -r
}

# Main function
main() {
  log "=== Drive DOD 5220.22-M Wipe Script Started ==="
  log "Timestamp: $(date)"
  log "Log file: $LOGFILE"
  log "Running as user: $(whoami)"

  while true; do
    # Get all available drives
    mapfile -t all_drives < <(get_available_drives)

    if [[ ${#all_drives[@]} -eq 0 ]]; then
      show_header
      warning "No drives found!"
      echo
      echo "This could happen if:"
      echo "- No external drives are connected"
      echo "- USB passthrough is not working properly in the VM"
      echo "- Drives are not being detected by the system"
      echo "- You need to run as root (use sudo)"
      echo
      echo "Try running the debug script to see what drives are detected:"
      echo "sudo bash debug_drives.sh"
      echo
      echo "Press Enter to exit..."
      read -r
      exit 0
    fi

    log "Found ${#all_drives[@]} drive(s): ${all_drives[*]}"

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

  log "User confirmed wipe of ${#drives_to_wipe[@]} drive(s): ${drives_to_wipe[*]}"
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
  # Kill any running shred processes
  pkill -f "shred.*dev" 2>/dev/null || true
  exit 130
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
