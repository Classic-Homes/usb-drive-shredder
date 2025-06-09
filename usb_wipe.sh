#!/bin/bash

# Drive DOD 5220.22-M Wipe Script with Manual Selection
# Displays all available drives and allows manual selection
# Ubuntu VM environment with comprehensive safety warnings

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

# Function to get all drives with detailed info and safety analysis
get_all_drives_detailed() {
  local -A drives_info

  echo "DEBUG: Starting drive detection..." >&2

  # Get all block devices
  while IFS= read -r line; do
    echo "DEBUG: Processing line: '$line'" >&2
    local device=$(echo "$line" | awk '{print $1}')
    local size=$(echo "$line" | awk '{print $2}')
    local type=$(echo "$line" | awk '{print $3}')

    # Skip if not a disk or if it's a partition
    if [[ "$type" != "disk" ]]; then
      echo "DEBUG: Skipping $device (type: $type)" >&2
      continue
    fi

    echo "DEBUG: Processing disk $device" >&2

    # Get detailed device information
    echo "DEBUG: Getting device info for $device" >&2
    local vendor=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_VENDOR=" | cut -d'=' -f2 || echo "Unknown")
    local model=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_MODEL=" | cut -d'=' -f2 || echo "Unknown")
    local serial=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_SERIAL_SHORT=" | cut -d'=' -f2 || echo "Unknown")
    local bus_type=$(udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep "ID_BUS=" | cut -d'=' -f2 || echo "Unknown")
    local device_path=$(udevadm info --query=path --name="/dev/$device" 2>/dev/null || echo "Unknown")
    local size_bytes=$(blockdev --getsize64 "/dev/$device" 2>/dev/null || echo "0")

    echo "DEBUG: Got basic info for $device" >&2

    # If vendor/model are unknown, try alternative methods
    if [[ "$vendor" == "Unknown" ]] && [[ "$model" == "Unknown" ]]; then
      vendor=$(cat "/sys/block/$device/device/vendor" 2>/dev/null | tr -d ' ' || echo "Unknown")
      model=$(cat "/sys/block/$device/device/model" 2>/dev/null | tr -d ' ' || echo "Unknown")
    fi

    # Safety analysis
    echo "DEBUG: Starting safety analysis for $device" >&2
    local warning_flags=""
    local safety_level="SAFE"
    local safety_reasons=()

    # Check if device is the Ubuntu system drive
    echo "DEBUG: Checking if $device is system drive" >&2
    if is_system_drive "/dev/$device"; then
      echo "DEBUG: $device is system drive" >&2
      warning_flags+="[SYSTEM-DRIVE] "
      safety_level="DANGEROUS"
      safety_reasons+=("Contains Ubuntu system partitions")
    fi

    # Check if device is mounted to important directories
    echo "DEBUG: Checking system mounts for $device" >&2
    if mount | grep "/dev/$device" | grep -E "(/ |/boot |/home |/usr |/var |/opt )"; then
      echo "DEBUG: $device has system mounts" >&2
      warning_flags+="[SYSTEM-MOUNT] "
      safety_level="DANGEROUS"
      safety_reasons+=("Mounted to system directories")
    fi

    # Check if device is currently mounted (any partition)
    echo "DEBUG: Checking general mounts for $device" >&2
    local mount_info=""
    if mount | grep -q "/dev/$device"; then
      if [[ "$safety_level" != "DANGEROUS" ]]; then
        warning_flags+="[MOUNTED] "
        safety_level="CAUTION"
        mount_info=$(mount | grep "/dev/$device" | awk '{print $3}' | tr '\n' ' ')
        safety_reasons+=("Currently mounted at: $mount_info")
      fi
    fi

    echo "DEBUG: Checking Ubuntu media for $device" >&2

    # Check if device appears to be Ubuntu installation media
    if udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep -q "ID_FS_LABEL.*[Uu]buntu"; then
      warning_flags+="[UBUNTU-MEDIA] "
      safety_level="DANGEROUS"
      safety_reasons+=("Ubuntu installation media")
    fi

    # Check for very small devices (< 100MB, likely system devices)
    if [[ $size_bytes -lt 104857600 ]]; then
      warning_flags+="[TOO-SMALL] "
      safety_level="DANGEROUS"
      safety_reasons+=("Very small device (< 100MB)")
    fi

    # Check if device has swap partitions
    if lsblk -n -o FSTYPE "/dev/$device" 2>/dev/null | grep -q "swap"; then
      warning_flags+="[HAS-SWAP] "
      safety_level="DANGEROUS"
      safety_reasons+=("Contains swap partition")
    fi

    # Check for Linux filesystem signatures on main device
    local fstype=$(lsblk -n -o FSTYPE "/dev/$device" 2>/dev/null | head -1)
    if [[ "$fstype" =~ ^(ext[2-4]|xfs|btrfs)$ ]]; then
      warning_flags+="[LINUX-FS] "
      if [[ "$safety_level" == "SAFE" ]]; then
        safety_level="CAUTION"
      fi
      safety_reasons+=("Contains Linux filesystem ($fstype)")
    fi

    # Check if device contains LVM or RAID signatures
    if udevadm info --query=property --name="/dev/$device" 2>/dev/null | grep -E "(LVM|MD_|RAID)"; then
      warning_flags+="[LVM-RAID] "
      safety_level="DANGEROUS"
      safety_reasons+=("Contains LVM/RAID configuration")
    fi

    # Special handling for sda (usually system drive)
    if [[ "$device" == "sda" ]] && [[ "$safety_level" == "SAFE" ]]; then
      safety_level="CAUTION"
      safety_reasons+=("First drive (sda) - typically system drive")
    fi

    # Determine connection type from bus and path
    local connection_type="Unknown"
    if [[ "$bus_type" == "usb" ]]; then
      connection_type="USB"
    elif [[ "$device_path" =~ /usb[0-9]+/ ]]; then
      connection_type="USB (via bridge)"
    elif [[ "$bus_type" == "ata" ]]; then
      connection_type="SATA/ATA"
    elif [[ "$bus_type" == "scsi" ]]; then
      connection_type="SCSI"
    elif [[ "$bus_type" == "nvme" ]]; then
      connection_type="NVMe"
    fi

    # Join safety reasons
    local reasons_str=""
    if [[ ${#safety_reasons[@]} -gt 0 ]]; then
      reasons_str=$(
        IFS="; "
        echo "${safety_reasons[*]}"
      )
    fi

    # Store drive information: vendor|model|size|serial|bus_type|connection_type|warning_flags|safety_level|reasons
    echo "DEBUG: Storing info for $device" >&2
    drives_info["/dev/$device"]="$vendor|$model|$size|$serial|$bus_type|$connection_type|$warning_flags|$safety_level|$reasons_str"
    echo "DEBUG: Stored info for $device" >&2

  done < <(lsblk -d -n -o NAME,SIZE,TYPE)

  echo "DEBUG: Finished processing drives" >&2
  echo "DEBUG: Found ${#drives_info[@]} drives" >&2

  # Return the associative array as key-value pairs
  echo "DEBUG: Outputting drive info" >&2
  for device in "${!drives_info[@]}"; do
    echo "DEBUG: Outputting info for $device" >&2
    echo "$device:${drives_info[$device]}"
  done
  echo "DEBUG: Finished outputting drive info" >&2
}

# Function to display drive selection menu
display_drive_menu() {
  local drives=("$@")
  local drive_count=${#drives[@]}

  if [[ $drive_count -eq 0 ]]; then
    echo
    warning "No drives found!"
    echo
    echo "Press Enter to exit..."
    read -r
    exit 0
  fi

  show_header
  echo -e "${BOLD}Found $drive_count drive(s):${NC}"
  echo

  # Display drives with numbers
  for i in "${!drives[@]}"; do
    local device=$(echo "${drives[$i]}" | cut -d':' -f1)
    local info=$(echo "${drives[$i]}" | cut -d':' -f2)
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local serial=$(echo "$info" | cut -d'|' -f4)
    local bus_type=$(echo "$info" | cut -d'|' -f5)
    local connection_type=$(echo "$info" | cut -d'|' -f6)
    local warnings=$(echo "$info" | cut -d'|' -f7)
    local safety_level=$(echo "$info" | cut -d'|' -f8)
    local reasons=$(echo "$info" | cut -d'|' -f9)

    local num=$((i + 1))

    # Color-code based on safety level
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
    echo "    Bus:    $bus_type"
    echo "    Type:   $connection_type"

    if [[ -n "$reasons" ]]; then
      case "$safety_level" in
      "SAFE")
        echo -e "    ${GREEN}Status: Safe for wiping${NC}"
        ;;
      "CAUTION")
        echo -e "    ${YELLOW}Status: Use caution - $reasons${NC}"
        ;;
      "DANGEROUS")
        echo -e "    ${RED}Status: DANGEROUS - $reasons${NC}"
        ;;
      esac
    else
      echo -e "    ${GREEN}Status: Safe for wiping${NC}"
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
    echo "  Type 'all-safe' to select all SAFE drives only"
    echo "  Type 'all-non-dangerous' to select SAFE and CAUTION drives"
    echo "  Type 'quit' or 'q' to exit"
    echo "  Type 'refresh' or 'r' to rescan drives"
    echo
    echo -e "${YELLOW}Note: DANGEROUS drives can still be selected but require extra confirmation${NC}"
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
      # Select all safe drives
      selected_drives=()
      for i in "${!drives[@]}"; do
        local info=$(echo "${drives[$i]}" | cut -d':' -f2)
        local safety_level=$(echo "$info" | cut -d'|' -f8)
        if [[ "$safety_level" == "SAFE" ]]; then
          local device=$(echo "${drives[$i]}" | cut -d':' -f1)
          selected_drives+=("$device")
        fi
      done

      if [[ ${#selected_drives[@]} -eq 0 ]]; then
        echo
        warning "No SAFE drives available for selection!"
        echo "Press Enter to continue..."
        read -r
        continue
      fi
      break
      ;;
    "all-non-dangerous")
      # Select all safe and caution drives
      selected_drives=()
      for i in "${!drives[@]}"; do
        local info=$(echo "${drives[$i]}" | cut -d':' -f2)
        local safety_level=$(echo "$info" | cut -d'|' -f8)
        if [[ "$safety_level" == "SAFE" ]] || [[ "$safety_level" == "CAUTION" ]]; then
          local device=$(echo "${drives[$i]}" | cut -d':' -f1)
          selected_drives+=("$device")
        fi
      done

      if [[ ${#selected_drives[@]} -eq 0 ]]; then
        echo
        warning "No non-dangerous drives available for selection!"
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

        local device=$(echo "${drives[$index]}" | cut -d':' -f1)

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

# Function to confirm selection with extra checks for dangerous drives
confirm_wipe() {
  local drives=("$@")
  local has_dangerous=false
  local has_caution=false

  # Check safety levels of selected drives
  for drive in "${drives[@]}"; do
    local drive_info=$(get_all_drives_detailed | grep "^$drive:")
    local info=$(echo "$drive_info" | cut -d':' -f2)
    local safety_level=$(echo "$info" | cut -d'|' -f8)

    if [[ "$safety_level" == "DANGEROUS" ]]; then
      has_dangerous=true
    elif [[ "$safety_level" == "CAUTION" ]]; then
      has_caution=true
    fi
  done

  show_header
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo
  echo -e "${RED}You have selected the following drives for DOD 5220.22-M wiping:${NC}"
  echo

  for drive in "${drives[@]}"; do
    local drive_info=$(get_all_drives_detailed | grep "^$drive:")
    local info=$(echo "$drive_info" | cut -d':' -f2)
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    local safety_level=$(echo "$info" | cut -d'|' -f8)
    local reasons=$(echo "$info" | cut -d'|' -f9)

    case "$safety_level" in
    "SAFE")
      echo -e "  ${GREEN}$drive${NC} - $vendor $model ($size) ${GREEN}[SAFE]${NC}"
      ;;
    "CAUTION")
      echo -e "  ${YELLOW}$drive${NC} - $vendor $model ($size) ${YELLOW}[CAUTION]${NC}"
      if [[ -n "$reasons" ]]; then
        echo -e "    ${YELLOW}⚠ $reasons${NC}"
      fi
      ;;
    "DANGEROUS")
      echo -e "  ${RED}$drive${NC} - $vendor $model ($size) ${RED}[DANGEROUS]${NC}"
      if [[ -n "$reasons" ]]; then
        echo -e "    ${RED}⚠ $reasons${NC}"
      fi
      ;;
    esac
  done

  echo
  echo -e "${RED}${BOLD}WARNING: This operation will PERMANENTLY DESTROY all data on these drives!${NC}"
  echo -e "${RED}${BOLD}This action CANNOT be undone!${NC}"
  echo

  # Different confirmation levels based on danger
  if [[ "$has_dangerous" == "true" ]]; then
    echo -e "${RED}${BOLD}CRITICAL WARNING: You have selected DANGEROUS drives!${NC}"
    echo -e "${RED}These may contain system files or important data!${NC}"
    echo
    echo "To proceed with DANGEROUS drives, type exactly:"
    echo "'I UNDERSTAND THE RISKS AND WANT TO WIPE DANGEROUS DRIVES'"
    echo
    echo -n "Confirmation: "

    read -r confirmation

    if [[ "$confirmation" == "I UNDERSTAND THE RISKS AND WANT TO WIPE DANGEROUS DRIVES" ]]; then
      return 0
    else
      echo
      info "Operation cancelled - dangerous drives not confirmed"
      echo "Press Enter to return to drive selection..."
      read -r
      return 1
    fi
  elif [[ "$has_caution" == "true" ]]; then
    echo -e "${YELLOW}${BOLD}CAUTION: You have selected drives that require extra attention!${NC}"
    echo
    echo "To proceed, type exactly: 'I WANT TO WIPE THESE DRIVES'"
    echo "Or type anything else to cancel"
    echo
    echo -n "Confirmation: "

    read -r confirmation

    if [[ "$confirmation" == "I WANT TO WIPE THESE DRIVES" ]]; then
      return 0
    else
      echo
      info "Operation cancelled"
      echo "Press Enter to return to drive selection..."
      read -r
      return 1
    fi
  else
    echo "To proceed with safe drives, type exactly: 'WIPE DRIVES'"
    echo "Or type anything else to cancel"
    echo
    echo -n "Confirmation: "

    read -r confirmation

    if [[ "$confirmation" == "WIPE DRIVES" ]]; then
      return 0
    else
      echo
      info "Operation cancelled"
      echo "Press Enter to return to drive selection..."
      read -r
      return 1
    fi
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
  log "=== Drive DOD 5220.22-M Wipe Script Started ==="
  log "Timestamp: $(date)"
  log "Log file: $LOGFILE"

  while true; do
    echo "DEBUG: Getting all drives" >&2
    # Get all drives
    mapfile -t drive_list < <(get_all_drives_detailed)
    echo "DEBUG: Got ${#drive_list[@]} drives from get_all_drives_detailed" >&2

    if [[ ${#drive_list[@]} -eq 0 ]]; then
      echo "DEBUG: No drives found, showing warning" >&2
      show_header
      warning "No drives found!"
      echo
      echo "Press Enter to exit..."
      read -r
      exit 0
    fi

    echo "DEBUG: About to call get_user_selection" >&2

    echo "DEBUG: About to call get_user_selection" >&2
    # Get user selection
    if selected_drives=$(get_user_selection "${drive_list[@]}"); then
      echo "DEBUG: User selection completed" >&2
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
