#!/bin/bash

# Drive DOD 5220.22-M Wipe Script with Manual Selection
# Simplified cross-platform version for Linux and macOS environments
# 
# Features:
# - Secure disk wiping using DoD 5220.22-M standard (3 passes + zero verification)
# - Safety checks to prevent accidental wiping of system disks
# - Color-coded safety ratings for each drive
# - Progress indicators and status updates

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Function to clear screen and show header
show_header() {
  clear
  echo -e "${BOLD}${BLUE}=================================================${NC}"
  echo -e "${BOLD}${BLUE}    Drive DOD 5220.22-M Wipe Utility${NC}"
  echo -e "${BOLD}${BLUE}         Manual Drive Selection${NC}"
  echo -e "${BOLD}${BLUE}=================================================${NC}"
  echo
}

# Function to get all available disk drives
get_available_drives() {
  local drives=()

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version - only get external drives
    while read -r device; do
      if [[ "$device" =~ /dev/disk[0-9]+$ ]]; then
        if diskutil info "$device" | grep -q "Removable Media: *Yes" || \
           diskutil info "$device" | grep -q "Protocol: *USB"; then
          # Only add if it's a removable or USB device
          drives+=("$device")
        fi
      fi
    done < <(diskutil list | grep -E "^/dev/disk[0-9]+" | awk '{print $1}')
  else
    # Linux version - focus on removable drives
    while IFS= read -r line; do
      local name=$(echo "$line" | awk '{print $1}')
      local type=$(echo "$line" | awk '{print $3}')

      if [[ "$type" == "disk" ]]; then
        # Add /dev/ prefix if not present
        if [[ "$name" != /dev/* ]]; then
          name="/dev/$name"
        fi
        
        # Check if removable or not primary disk
        if [[ -e "/sys/block/$(basename "$name")/removable" ]] && \
           [[ "$(cat /sys/block/$(basename "$name")/removable)" == "1" ]] || \
           [[ "$name" != "/dev/sda" && "$name" != "/dev/vda" && "$name" != "/dev/hda" ]]; then
          # Only add if it's not the primary system disk and is actually accessible
          if [[ -b "$name" && -r "$name" ]]; then
            drives+=("$name")
          fi
        fi
      fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null)
  fi

  printf '%s\n' "${drives[@]}"
}

# Function to check drive safety
get_drive_safety() {
  local device="$1"
  
  # Check if device exists and is readable
  if [[ ! -e "$device" || ! -b "$device" || ! -r "$device" ]]; then
    echo "ERROR|Device not accessible"
    return
  fi
  
  # Check if it's a system drive
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS checks
    if diskutil info "$device" | grep -q "Internal: *Yes" || \
       diskutil info "$device" | grep -q "Boot: *Yes" || \
       diskutil info "$device" | grep -q "Part of Whole: *disk0"; then
      echo "DANGEROUS|System disk"
      return
    fi
    
    # Check if it's mounted
    if diskutil info "$device" | grep -q "Mount Point:" | grep -v "(not mounted)"; then
      echo "CAUTION|Drive is mounted"
      return
    fi
    
    # Check if it's USB or removable (safer)
    if diskutil info "$device" | grep -q "Protocol.*USB" || \
       diskutil info "$device" | grep -q "Removable Media: *Yes"; then
      echo "SAFE|External drive"
      return
    fi
  else
    # Linux checks
    # Check if it's a primary system disk
    if [[ "$device" == "/dev/sda" || "$device" == "/dev/vda" || "$device" == "/dev/hda" ]]; then
      echo "DANGEROUS|Likely system disk"
      return
    fi
    
    # Check if it's mounted
    if mount | grep -q "^$device "; then
      echo "CAUTION|Drive is mounted"
      return
    fi
    
    # Check if it's removable
    if [[ -e "/sys/block/$(basename "$device")/removable" ]] && \
       [[ "$(cat /sys/block/$(basename "$device")/removable)" == "1" ]]; then
      echo "SAFE|Removable drive"
      return
    fi
    
    # Check if it's USB
    if udevadm info --query=property --name="$device" 2>/dev/null | grep -q "ID_BUS=usb"; then
      echo "SAFE|USB drive"
      return
    fi
  fi
  
  # Default to caution if we're not sure
  echo "CAUTION|Unknown drive type"
}

# Function to get drive info
get_drive_info() {
  local device="$1"
  local vendor="Unknown"
  local model="Unknown"
  local size="Unknown"
  
  if [[ ! -e "$device" ]]; then
    echo "Unknown|Unknown|Unknown"
    return
  fi
  
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version
    local device_info=$(diskutil info "$device" 2>/dev/null)
    
    # Extract device information
    vendor=$(echo "$device_info" | grep -i "Device / Media Name" | sed 's/.*Device \/ Media Name: *//' | awk '{print $1}' || echo "Unknown")
    model=$(echo "$device_info" | grep -i "Device Model" | sed 's/.*Device Model: *//' || echo "Unknown")
    size=$(echo "$device_info" | grep -i "Disk Size" | sed 's/.*Disk Size: *//' | awk '{print $1" "$2}' || echo "Unknown")
  else
    # Linux version
    vendor=$(lsblk -d -no vendor "$device" 2>/dev/null || echo "Unknown")
    model=$(lsblk -d -no model "$device" 2>/dev/null || echo "Unknown")
    size=$(lsblk -d -no size "$device" 2>/dev/null || echo "Unknown")
  fi
  
  # Clean up any empty values
  if [[ -z "$vendor" ]]; then vendor="Unknown"; fi
  if [[ -z "$model" ]]; then model="Unknown"; fi
  if [[ -z "$size" ]]; then size="Unknown"; fi
  
  echo "$vendor|$model|$size"
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
    echo "- You need to run with sudo"
    echo
    echo "Press Enter to exit..."
    read -r
    exit 0
  fi
  
  echo -e "${BLUE}Loading drive information...${NC}"
  
  for i in "${!drives[@]}"; do
    local device="${drives[$i]}"
    local num=$((i + 1))
    
    # Get drive info
    local info=$(get_drive_info "$device")
    local vendor=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    local size=$(echo "$info" | cut -d'|' -f3)
    
    # Get safety info
    local safety_info=$(get_drive_safety "$device")
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
    echo "  Enter drive numbers separated by spaces (e.g., 1 2 3)"
    echo "  Type 'all-safe' to select all SAFE drives"
    echo "  Type 'refresh' to rescan drives"
    echo "  Type 'quit' to exit"
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
      return 2
      ;;
    "all-safe")
      local selected=()
      for i in "${!drives[@]}"; do
        local device="${drives[$i]}"
        local safety_info=$(get_drive_safety "$device")
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
    
    local safety_info=$(get_drive_safety "$drive")
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

# Function to unmount device
unmount_device() {
  local device="$1"
  
  info "Unmounting any mounted partitions on $device"
  
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS version
    diskutil unmountDisk force "$device" 2>/dev/null || true
  else
    # Linux version
    # Unmount any partitions
    lsblk -ln -o NAME "$device" 2>/dev/null | tail -n +2 | while read -r part; do
      umount -f "/dev/$part" 2>/dev/null || true
    done
    
    # Unmount the device itself
    umount -f "$device" 2>/dev/null || true
  fi
  
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
    echo
    
    # Use shred command for all platforms
    if shred -vfz -n 3 "$device" 2>&1; then
      echo
      echo "=== Wipe Completed Successfully: $(date) ==="
    else
      echo
      echo "=== Wipe Failed: $(date) ==="
      exit 1
    fi
  } >"$wipe_log" 2>&1 &
  
  local pid=$!
  echo "$pid:$device:$wipe_log"
}

# Function to monitor wipe progress
monitor_wipes() {
  local wipe_processes=("$@")
  local spinner=('-' '\' '|' '/')
  local spin_idx=0
  
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
        echo -e "  ${YELLOW}$device${NC} - In Progress ${spinner[$spin_idx]} (PID: $pid)"
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
    
    # Update spinner
    spin_idx=$(( (spin_idx + 1) % 4 ))
    
    # Show update time
    echo -e "\nLast update: $(date +"%H:%M:%S")"
    echo -e "Refreshing in 2 seconds... (press Ctrl+C to stop monitoring)"
    
    sleep 2
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
  
  while true; do
    # Get all available drives
    echo -e "${BLUE}Scanning for available drives...${NC}"
    mapfile -t all_drives < <(get_available_drives)
    
    if [[ ${#all_drives[@]} -eq 0 ]]; then
      show_header
      warning "No drives found!"
      echo
      echo "This could happen if:"
      echo "- No external drives are connected"
      echo "- You need to run with sudo"
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
  
  # Start wipe processes
  declare -a wipe_processes=()
  
  for drive in "${drives_to_wipe[@]}"; do
    info "Starting wipe process for $drive..."
    process_info=$(wipe_drive "$drive")
    wipe_processes+=("$process_info")
    sleep 2
  done
  
  # Monitor progress
  monitor_wipes "${wipe_processes[@]}"
}

# Signal handler
trap "echo; warning 'Script interrupted!'; exit 130" SIGINT SIGTERM

# Run main function
main "$@"
