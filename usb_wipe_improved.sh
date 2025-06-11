#!/bin/bash

# USB Drive Wiper - DoD 5220.22-M Standard
# Enhanced version with better drive detection, verification, and progress reporting

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
  exit 1
fi

# Banner for the tool
show_banner() {
  clear
  cat << EOF
${BOLD}${BLUE}======================================================${NC}
${BOLD}${BLUE}             USB Drive Secure Wiper                   ${NC}
${BOLD}${BLUE}      DoD 5220.22-M (3 passes + verification)         ${NC}
${BOLD}${BLUE}======================================================${NC}

EOF
}

# Check required commands
check_requirements() {
  local missing=()

  if [[ "$(uname)" == "Darwin" ]]; then
    for cmd in diskutil dd pv; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    done
    if ! command -v shred >/dev/null 2>&1; then
      echo -e "${YELLOW}Warning: 'shred' not found. Install with: brew install coreutils${NC}"
      echo "Will use dd for wiping instead"
    fi
    if ! command -v pv >/dev/null 2>&1; then
      echo -e "${YELLOW}Warning: 'pv' not found. Install with: brew install pv${NC}"
      echo "Progress bars will not be shown during wiping"
    fi
  else
    for cmd in lsblk shred pv; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        if [[ "$cmd" == "pv" ]]; then
          echo -e "${YELLOW}Warning: 'pv' not found. Progress bars will not be shown during wiping${NC}"
        else
          missing+=("$cmd")
        fi
      fi
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing required commands: ${missing[*]}${NC}"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "Install required tools with: brew install coreutils pv"
    else
      echo "Install required tools with: apt-get install util-linux coreutils pv"
    fi
    exit 1
  fi
}

# Get all disk drives with enhanced detection
get_all_drives() {
  local drives=()

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Get all disk drives, including external drives
    diskutil list | grep -E "^/dev/disk[0-9]+" | while read -r line; do
      local device=$(echo "$line" | awk '{print $1}')
      if [[ -n "$device" && "$device" =~ /dev/disk[0-9]+$ && -r "$device" ]]; then
        drives+=("$device")
      fi
    done

    # Also check for any external physical disks that might not be captured above
    diskutil list external physical | grep -E "^/dev/disk[0-9]+" | while read -r line; do
      local device=$(echo "$line" | awk '{print $1}')
      if [[ -n "$device" && ! " ${drives[*]} " =~ " $device " ]]; then
        drives+=("$device")
      fi
    done
  else
    # Linux: Get all disk drives, focusing on physical and removable disks
    lsblk -d -n -o NAME,TYPE,HOTPLUG,RM | while read -r line; do
      if [[ -n "$line" ]]; then
        local name=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local hotplug=$(echo "$line" | awk '{print $3}')
        local removable=$(echo "$line" | awk '{print $4}')
        
        if [[ "$type" == "disk" ]]; then
          drives+=("/dev/$name")
        fi
      fi
    done
  fi

  printf '%s\n' "${drives[@]}"
}

# Get enhanced drive info with more details
get_drive_info() {
  local device="$1"
  local size="Unknown"
  local model="Unknown"
  local serial="Unknown"
  local removable="Unknown"
  local mounted=""
  local filesystem=""
  local virtual="No"

  if [[ "$(uname)" == "Darwin" ]]; then
    # Mac OS X - use diskutil
    local info=$(diskutil info "$device" 2>/dev/null)
    
    # Get size from diskutil
    size=$(echo "$info" | grep "Disk Size" | awk -F': ' '{print $2}' | sed 's/ (.*//' || echo "Unknown")
    
    # Get model info
    model=$(echo "$info" | grep "Device / Media Name" | awk -F': ' '{print $2}' || echo "Unknown")
    
    # Check if it's a virtual disk
    if echo "$info" | grep -q "Virtual:" && echo "$info" | grep -q "Yes"; then
      virtual="Yes"
    fi
    
    # Check if it's removable
    if echo "$info" | grep -q "Removable Media:" && echo "$info" | grep -q "Removable"; then
      removable="Yes"
    else
      removable="No"
    fi
    
    # Check if it's mounted
    if echo "$info" | grep -q "Mounted:" && echo "$info" | grep -q "Yes"; then
      mounted="MOUNTED"
      filesystem=$(echo "$info" | grep "File System:" | awk -F': ' '{print $2}' || echo "Unknown")
    fi
    
  else
    # Linux - use lsblk and other tools
    # Get size
    size=$(lsblk -d -no SIZE "$device" 2>/dev/null || echo "Unknown")
    
    # Get model name
    model=$(lsblk -d -no MODEL "$device" 2>/dev/null || echo "Unknown")
    
    # Get serial if available
    serial=$(lsblk -d -no SERIAL "$device" 2>/dev/null || echo "Unknown")
    
    # Check if removable
    local rm_val=$(lsblk -d -no RM "$device" 2>/dev/null)
    if [[ "$rm_val" == "1" ]]; then
      removable="Yes"
    elif [[ "$rm_val" == "0" ]]; then
      removable="No"
    fi
    
    # Check if it's a virtual disk
    if [[ "$device" == *"/dev/loop"* || "$device" == *"/dev/ram"* ]]; then
      virtual="Yes"
    fi
    
    # Get mount info
    local mount_point=$(lsblk -d -no MOUNTPOINT "$device" 2>/dev/null)
    if [[ -n "$mount_point" && "$mount_point" != "null" ]]; then
      mounted="MOUNTED"
      filesystem=$(lsblk -d -no FSTYPE "$device" 2>/dev/null || echo "Unknown")
    fi
  fi

  # Output in a pipe-delimited format for easy parsing
  echo "Drive|$size|$model|$serial|$removable|$mounted|$filesystem|$virtual"
}

# Determine safety level based on drive attributes
get_safety_level() {
  local device="$1"
  local info="$2"
  local size=$(echo "$info" | cut -d'|' -f2)
  local model=$(echo "$info" | cut -d'|' -f3)
  local removable=$(echo "$info" | cut -d'|' -f5)
  local mounted=$(echo "$info" | cut -d'|' -f6)
  local virtual=$(echo "$info" | cut -d'|' -f8)

  # Virtual disks should never be wiped
  if [[ "$virtual" == "Yes" ]]; then
    echo "SYSTEM"
    return
  fi

  # Check for obvious system drive patterns
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: disk0 is usually the system drive
    if [[ "$device" == "/dev/disk0" ]]; then
      echo "SYSTEM"
      return
    fi
    
    # Check if it's the boot drive
    if diskutil info "$device" 2>/dev/null | grep -q "APFS Container.*disk1" && diskutil info disk1 2>/dev/null | grep -q "Macintosh HD"; then
      echo "SYSTEM"
      return
    fi
  else
    # Linux: sda or nvme0n1 are often system drives
    if [[ "$device" == "/dev/sda" || "$device" == "/dev/nvme0n1" ]]; then
      echo "SYSTEM"
      return
    fi
    
    # Check if mounted to system locations
    if mount | grep "^$device" | grep -E "( /| /boot| /home)" >/dev/null 2>&1; then
      echo "SYSTEM"
      return
    fi
  fi

  # External/removable drives are generally safer
  if [[ "$removable" == "Yes" ]]; then
    echo "SAFE"
    return
  fi

  # Check if mounted (could be important)
  if [[ "$mounted" == "MOUNTED" ]]; then
    echo "CAUTION"
    return
  fi

  # Large drives might be important (1TB+)
  if [[ "$size" =~ ([0-9]+).*T ]] && [[ ${BASH_REMATCH[1]} -ge 1 ]]; then
    echo "CAUTION"
    return
  fi

  # Default to caution for anything else
  echo "CAUTION"
}

# Display all drives with enhanced info and safety indicators
display_drives() {
  local drives=("$@")

  show_banner
  echo -e "${BOLD}Legend:${NC}"
  echo -e "  ${GREEN}SAFE${NC}     - Likely removable/external drive"
  echo -e "  ${YELLOW}CAUTION${NC}  - Check carefully before wiping"
  echo -e "  ${RED}SYSTEM${NC}   - Likely system drive - DO NOT WIPE"
  echo

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No drives found.${NC}"
    return 1
  fi

  # Table header
  printf "  %-5s %-12s %-10s %-30s %-12s %s\n" "NUM" "DEVICE" "SIZE" "MODEL" "STATUS" "SAFETY"
  printf "  %-5s %-12s %-10s %-30s %-12s %s\n" "===" "======" "====" "=====" "======" "======"

  local num=1
  for device in "${drives[@]}"; do
    # Get info with error handling
    local info
    if info=$(get_drive_info "$device" 2>/dev/null); then
      local size=$(echo "$info" | cut -d'|' -f2)
      local model=$(echo "$info" | cut -d'|' -f3 | cut -c 1-30)
      local removable=$(echo "$info" | cut -d'|' -f5)
      local mounted=$(echo "$info" | cut -d'|' -f6)
      local safety=$(get_safety_level "$device" "$info")

      # Format the display line
      local status="Available"
      if [[ "$mounted" == "MOUNTED" ]]; then
        status="MOUNTED"
      fi

      # Choose color based on safety
      local safety_display=""
      case "$safety" in
      "SAFE")
        safety_display="${GREEN}SAFE${NC}"
        ;;
      "CAUTION")
        safety_display="${YELLOW}CAUTION${NC}"
        ;;
      "SYSTEM")
        safety_display="${RED}SYSTEM${NC}"
        ;;
      esac

      printf "  [%3d] %-12s %-10s %-30s %-12s %s\n" "$num" "$device" "$size" "$model" "$status" "$safety_display"
    else
      # If we can't get info, show minimal details
      printf "  [%3d] %-12s %-10s %-30s %-12s %s\n" "$num" "$device" "Unknown" "Could not read device info" "Unknown" "${YELLOW}CAUTION${NC}"
    fi
    ((num++))
  done
  echo
}

# Get user selection with safety checks
get_selection() {
  local drives=("$@")

  while true; do
    display_drives "${drives[@]}"

    echo -e "${BOLD}Selection Instructions:${NC}"
    echo "• Enter drive numbers separated by spaces (example: 2 3 4)"
    echo "• Type 'r' to refresh the drive list"
    echo "• Type 'q' to quit"
    echo "• ${RED}AVOID drives marked as SYSTEM${NC}"
    echo "• ${YELLOW}Double-check CAUTION drives${NC}"
    echo
    echo -n "Your selection: "
    read -r selection

    if [[ "$selection" == "q" ]]; then
      exit 0
    fi
    
    if [[ "$selection" == "r" ]]; then
      echo "Refreshing drive list..."
      mapfile -t new_drives < <(get_all_drives)
      drives=("${new_drives[@]}")
      continue
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
        echo -e "${RED}ERROR: $device is marked as a SYSTEM drive - refusing to select${NC}"
        has_system=true
        valid=false
        continue
      fi

      if [[ "$safety" == "CAUTION" ]]; then
        echo -e "${YELLOW}WARNING: $device is marked as CAUTION${NC}"
        echo -e "  Device: $device ($(echo "$info" | cut -d'|' -f2))"
        echo -e "  Model: $(echo "$info" | cut -d'|' -f3)"
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
      local size=$(echo "$info" | cut -d'|' -f2)
      local model=$(echo "$info" | cut -d'|' -f3)
      echo -e "  ${YELLOW}$drive${NC} - $size - $model"
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

  show_banner
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo "=================="
  echo
  echo -e "${RED}The following drives will be PERMANENTLY WIPED using DoD 5220.22-M standard:${NC}"
  echo

  for drive in "${drives[@]}"; do
    local info=$(get_drive_info "$drive")
    local size=$(echo "$info" | cut -d'|' -f2)
    local model=$(echo "$info" | cut -d'|' -f3)
    echo -e "  ${YELLOW}$drive${NC} - $size - $model"
  done

  echo
  echo -e "${RED}${BOLD}THIS WILL PERMANENTLY DESTROY ALL DATA!${NC}"
  echo -e "${RED}${BOLD}THIS OPERATION CANNOT BE UNDONE!${NC}"
  echo
  echo -e "${YELLOW}Please type 'WIPE' (all uppercase) to confirm:${NC}"
  read -r confirmation

  [[ "$confirmation" == "WIPE" ]]
}

# Unmount drive with enhanced error handling
unmount_drive() {
  local device="$1"

  echo "    Unmounting $device..."
  if [[ "$(uname)" == "Darwin" ]]; then
    # MacOS: Use diskutil to unmount
    diskutil unmountDisk force "$device" 2>/dev/null || {
      echo -e "    ${YELLOW}Warning: Failed to unmount $device but continuing anyway${NC}"
      return 0
    }
  else
    # Linux: Unmount all partitions individually first
    local partitions=$(lsblk -ln -o NAME,MOUNTPOINT "$device" 2>/dev/null | grep -v "^$(basename "$device") " | awk '$2 != "" {print $1}')
    for part in $partitions; do
      echo "    Unmounting /dev/$part..."
      umount "/dev/$part" 2>/dev/null || true
    done
    # Try to unmount the device itself, though this usually isn't needed
    umount "$device" 2>/dev/null || true
  fi
  sleep 1
}

# Function to format time in a human-readable format
format_time() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(( (seconds % 3600) / 60 ))
  local secs=$((seconds % 60))
  
  if [[ $hours -gt 0 ]]; then
    printf "%dh %dm %ds" $hours $minutes $secs
  elif [[ $minutes -gt 0 ]]; then
    printf "%dm %ds" $minutes $secs
  else
    printf "%ds" $secs
  fi
}

# Verify wipe by checking for non-zero data
verify_wipe() {
  local device="$1"
  local sample_size="10M"
  local report_file="$2"
  
  echo "    Verifying wipe by sampling data..."
  echo "$(date): Starting verification" >>"$report_file"
  
  # Sampling from the beginning, middle, and end
  local device_size=$(get_drive_info "$device" | cut -d'|' -f2 | sed 's/[^0-9]//g')
  if [[ -z "$device_size" || "$device_size" == "Unknown" ]]; then
    device_size=$(blockdev --getsize64 "$device" 2>/dev/null || echo "0")
  fi
  
  # If we can't determine size, just sample the beginning
  if [[ "$device_size" == "0" ]]; then
    local sample=$(dd if="$device" bs=1M count=1 2>/dev/null | hexdump -n 1024 -C)
    echo "Sample from beginning of drive:" >>"$report_file"
    echo "$sample" >>"$report_file"
    
    # Check if the sample is all zeros
    if [[ -z "$(echo "$sample" | grep -v "00 00 00 00")" ]]; then
      echo "$(date): Verification passed - drive appears to be wiped" >>"$report_file"
      return 0
    else
      echo "$(date): Verification FAILED - non-zero data found" >>"$report_file"
      return 1
    fi
  else
    # Sample beginning, middle and end if we know the size
    local samples_passed=0
    
    # Beginning
    echo "Sampling beginning of drive..." >>"$report_file"
    local sample_begin=$(dd if="$device" bs=1M count=1 2>/dev/null | hexdump -n 1024 -C)
    echo "$sample_begin" >>"$report_file"
    if [[ -z "$(echo "$sample_begin" | grep -v "00 00 00 00")" ]]; then
      ((samples_passed++))
    fi
    
    # Middle
    echo "Sampling middle of drive..." >>"$report_file"
    local middle_seek=$((device_size / 2 / 1024 / 1024))
    if [[ $middle_seek -gt 0 ]]; then
      local sample_middle=$(dd if="$device" bs=1M skip=$middle_seek count=1 2>/dev/null | hexdump -n 1024 -C)
      echo "$sample_middle" >>"$report_file"
      if [[ -z "$(echo "$sample_middle" | grep -v "00 00 00 00")" ]]; then
        ((samples_passed++))
      fi
    else
      ((samples_passed++))  # Skip this test for very small drives
    fi
    
    # End
    echo "Sampling end of drive..." >>"$report_file"
    local end_seek=$((device_size / 1024 / 1024 - 2))
    if [[ $end_seek -gt 0 ]]; then
      local sample_end=$(dd if="$device" bs=1M skip=$end_seek count=1 2>/dev/null | hexdump -n 1024 -C)
      echo "$sample_end" >>"$report_file"
      if [[ -z "$(echo "$sample_end" | grep -v "00 00 00 00")" ]]; then
        ((samples_passed++))
      fi
    else
      ((samples_passed++))  # Skip this test for very small drives
    fi
    
    # Check results
    if [[ $samples_passed -eq 3 ]]; then
      echo "$(date): Verification passed - all samples appear to be wiped" >>"$report_file"
      return 0
    else
      echo "$(date): Verification FAILED - non-zero data found in some samples" >>"$report_file"
      return 1
    fi
  fi
}

# Wipe drive using DoD 5220.22-M standard with progress reporting
wipe_drive() {
  local device="$1"
  local report_dir="/tmp/wipe_reports"
  mkdir -p "$report_dir"
  
  local report_file="$report_dir/wipe_report_$(basename "$device")_$(date +%Y%m%d_%H%M%S).txt"

  echo -e "${BLUE}Wiping $device...${NC}"

  # Get device info for the report
  local info=$(get_drive_info "$device")
  local size=$(echo "$info" | cut -d'|' -f2)
  local model=$(echo "$info" | cut -d'|' -f3)
  local serial=$(echo "$info" | cut -d'|' -f4)

  # Create report
  {
    echo "====================================="
    echo "Drive Secure Wipe Report"
    echo "====================================="
    echo "Date: $(date)"
    echo "Device: $device"
    echo "Model: $model"
    echo "Serial: $serial"
    echo "Size: $size"
    echo "Standard: DoD 5220.22-M (3 passes + zero)"
    echo
    echo "Drive Information:"
    echo "$info" | sed 's/|/\n/g' | sed 's/^/    /'
    echo
    echo "Wipe Process:"
  } >"$report_file"

  # Unmount
  unmount_drive "$device"

  local start_time=$(date +%s)
  local status="SUCCESS"
  local pass_status=("SUCCESS" "SUCCESS" "SUCCESS" "SUCCESS")
  local has_pv=0
  
  # Check if pv is available for progress reporting
  if command -v pv >/dev/null 2>&1; then
    has_pv=1
  fi

  # Get device size for progress reporting
  local device_size_bytes=0
  if [[ "$(uname)" == "Darwin" ]]; then
    device_size_bytes=$(diskutil info "$device" 2>/dev/null | grep "Disk Size" | awk '{print $5}' | sed 's/[^0-9]//g' || echo "0")
  else
    device_size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null || echo "0")
  fi

  if command -v shred >/dev/null 2>&1; then
    echo "    Using shred (DoD 5220.22-M: 3 passes + zero)..."
    echo "$(date): Starting shred operation" >>"$report_file"
    
    if ! shred -vfz -n 3 "$device" >>"$report_file" 2>&1; then
      status="FAILED"
      echo -e "    ${RED}Shred operation failed${NC}"
    fi
  else
    echo "    Using dd (DoD 5220.22-M: 3 passes + zero)..."
    echo "$(date): Starting dd operation (fallback)" >>"$report_file"

    local bs_size="1M"
    for pass in {1..3}; do
      local pass_start=$(date +%s)
      echo "      Pass $pass/4: Random data"
      echo "$(date): Pass $pass - random data" >>"$report_file"
      
      if [[ $has_pv -eq 1 && $device_size_bytes -gt 0 ]]; then
        # Use pv for progress reporting
        if ! dd if=/dev/urandom bs="$bs_size" | pv -s "$device_size_bytes" | dd of="$device" bs="$bs_size" 2>>"$report_file"; then
          status="FAILED"
          pass_status[$((pass-1))]="FAILED"
          break
        fi
      else
        # Fallback to regular dd without progress
        if ! dd if=/dev/urandom of="$device" bs="$bs_size" 2>>"$report_file"; then
          status="FAILED"
          pass_status[$((pass-1))]="FAILED"
          break
        fi
      fi
      
      local pass_end=$(date +%s)
      local pass_duration=$((pass_end - pass_start))
      echo "      Pass $pass completed in $(format_time $pass_duration)"
      echo "Pass $pass completed in $(format_time $pass_duration)" >>"$report_file"
    done

    if [[ "$status" != "FAILED" ]]; then
      local pass_start=$(date +%s)
      echo "      Pass 4/4: Zero fill"
      echo "$(date): Pass 4 - zero fill" >>"$report_file"
      
      if [[ $has_pv -eq 1 && $device_size_bytes -gt 0 ]]; then
        # Use pv for progress reporting
        if ! dd if=/dev/zero bs="$bs_size" | pv -s "$device_size_bytes" | dd of="$device" bs="$bs_size" 2>>"$report_file"; then
          status="FAILED"
          pass_status[3]="FAILED"
        fi
      else
        # Fallback to regular dd without progress
        if ! dd if=/dev/zero of="$device" bs="$bs_size" 2>>"$report_file"; then
          status="FAILED"
          pass_status[3]="FAILED"
        fi
      fi
      
      local pass_end=$(date +%s)
      local pass_duration=$((pass_end - pass_start))
      echo "      Pass 4 completed in $(format_time $pass_duration)"
      echo "Pass 4 completed in $(format_time $pass_duration)" >>"$report_file"
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Verify the wipe if it was successful
  local verification="NOT PERFORMED"
  if [[ "$status" == "SUCCESS" ]]; then
    echo "    Verifying wipe..."
    if verify_wipe "$device" "$report_file"; then
      verification="PASSED"
    else
      verification="FAILED"
      status="VERIFICATION_FAILED"
    fi
  fi

  # Update report
  {
    echo
    echo "Wipe Completed: $(date)"
    echo "Duration: $(format_time $duration)"
    echo "Passes:"
    echo "  Pass 1 (Random): ${pass_status[0]}"
    echo "  Pass 2 (Random): ${pass_status[1]}"
    echo "  Pass 3 (Random): ${pass_status[2]}"
    echo "  Pass 4 (Zero): ${pass_status[3]}"
    echo "Verification: $verification"
    echo "Final Status: $status"
  } >>"$report_file"

  case "$status" in
    "SUCCESS")
      echo -e "    ${GREEN}✓ Wipe completed and verified successfully${NC}"
      ;;
    "VERIFICATION_FAILED")
      echo -e "    ${YELLOW}⚠ Wipe completed but verification failed${NC}"
      ;;
    *)
      echo -e "    ${RED}✗ Wipe failed${NC}"
      ;;
  esac

  echo -e "    Report saved: ${CYAN}$report_file${NC}"
  return 0
}

# Main function
main() {
  show_banner
  echo

  check_requirements

  echo "Scanning for disk drives..."
  mapfile -t drives < <(get_all_drives)

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo -e "${RED}No disk drives found!${NC}"
    echo "Check if running as root: sudo $0"
    exit 1
  fi

  echo -e "${GREEN}Found ${#drives[@]} drive(s)${NC}"
  echo

  # Get user selection
  mapfile -t selected < <(get_selection "${drives[@]}")

  # Final confirmation
  if ! confirm_wipe "${selected[@]}"; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 0
  fi

  echo
  echo -e "${BOLD}${BLUE}Starting wipe operations...${NC}"
  echo

  # Wipe each drive
  local start_total=$(date +%s)
  for drive in "${selected[@]}"; do
    wipe_drive "$drive"
    echo
  done
  local end_total=$(date +%s)
  local duration_total=$((end_total - start_total))

  echo -e "${GREEN}${BOLD}All operations completed!${NC}"
  echo -e "Total time: $(format_time $duration_total)"
  echo -e "Reports saved in ${CYAN}/tmp/wipe_reports/${NC}"
}

# Run main function
main "$@"
