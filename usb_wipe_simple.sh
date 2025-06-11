#!/bin/bash

# USB Drive Wiper - DoD 5220.22-M Standard
# Simplified version with direct drive handling - no complex array manipulation

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
  local missing=""

  if [[ "$(uname)" == "Darwin" ]]; then
    for cmd in diskutil dd; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing="$missing $cmd"
      fi
    done
    if ! command -v shred >/dev/null 2>&1; then
      echo -e "${YELLOW}Warning: 'shred' not found. Install with: brew install coreutils${NC}"
      echo "Will use dd for wiping instead"
    fi
  else
    for cmd in lsblk; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing="$missing $cmd"
      fi
    done
  fi

  if [[ -n "$missing" ]]; then
    echo -e "${RED}Error: Missing required commands:${missing}${NC}"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "Install required tools with: brew install coreutils"
    else
      echo "Install required tools with: apt-get install util-linux coreutils"
    fi
    exit 1
  fi
}

# Get enhanced drive info with more details
get_drive_info() {
  local device="$1"
  local size="Unknown"
  local model="Unknown"
  local removable="Unknown"
  local mounted=""
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
    fi
    
  else
    # Linux - use lsblk and other tools
    # Get size
    size=$(lsblk -d -no SIZE "$device" 2>/dev/null || echo "Unknown")
    
    # Get model name
    model=$(lsblk -d -no MODEL "$device" 2>/dev/null || echo "Unknown")
    
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
    fi
  fi

  echo "$size|$model|$removable|$mounted|$virtual"
}

# Determine safety level based on drive attributes
get_safety_level() {
  local device="$1"
  local info="$2"
  local size=$(echo "$info" | cut -d'|' -f1)
  local model=$(echo "$info" | cut -d'|' -f2)
  local removable=$(echo "$info" | cut -d'|' -f3)
  local mounted=$(echo "$info" | cut -d'|' -f4)
  local virtual=$(echo "$info" | cut -d'|' -f5)

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
  show_banner
  echo -e "${BOLD}Legend:${NC}"
  echo -e "  ${GREEN}SAFE${NC}     - Likely removable/external drive"
  echo -e "  ${YELLOW}CAUTION${NC}  - Check carefully before wiping"
  echo -e "  ${RED}SYSTEM${NC}   - Likely system drive - DO NOT WIPE"
  echo

  # Table header
  printf "  %-5s %-12s %-10s %-30s %-12s %s\n" "NUM" "DEVICE" "SIZE" "MODEL" "STATUS" "SAFETY"
  printf "  %-5s %-12s %-10s %-30s %-12s %s\n" "===" "======" "====" "=====" "======" "======"

  local num=1
  local drives_file="/tmp/usb_wipe_drives.$$"
  
  # Use temporary file to store drive paths for selection
  > "$drives_file"
  
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Get all disk drives
    diskutil list | grep -E "^/dev/disk[0-9]+" | while read -r line; do
      local device=$(echo "$line" | awk '{print $1}')
      if [[ -n "$device" && "$device" =~ /dev/disk[0-9]+$ && -r "$device" ]]; then
        echo "$device" >> "$drives_file"
        
        # Get info with error handling
        local info
        if info=$(get_drive_info "$device" 2>/dev/null); then
          local size=$(echo "$info" | cut -d'|' -f1)
          local model=$(echo "$info" | cut -d'|' -f2 | cut -c 1-30)
          local removable=$(echo "$info" | cut -d'|' -f3)
          local mounted=$(echo "$info" | cut -d'|' -f4)
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
      fi
    done
  else
    # Linux: Get all disk drives, focusing on physical disks
    lsblk -d -n -o NAME,TYPE | grep "disk" | while read -r line; do
      local name=$(echo "$line" | awk '{print $1}')
      local device="/dev/$name"
      
      echo "$device" >> "$drives_file"
      
      # Get info with error handling
      local info
      if info=$(get_drive_info "$device" 2>/dev/null); then
        local size=$(echo "$info" | cut -d'|' -f1)
        local model=$(echo "$info" | cut -d'|' -f2 | cut -c 1-30)
        local removable=$(echo "$info" | cut -d'|' -f3)
        local mounted=$(echo "$info" | cut -d'|' -f4)
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
  fi
  
  local total=$(wc -l < "$drives_file" | tr -d ' ')
  if [[ $total -eq 0 ]]; then
    echo -e "${YELLOW}No drives found.${NC}"
    rm -f "$drives_file"
    return 1
  fi
  
  echo
  echo -e "${GREEN}Found $total drive(s)${NC}"
  echo
  
  return 0
}

# Get user selection with safety checks
get_selection() {
  local drives_file="$1"
  local selected_file="$2"
  
  # Clear any previous selections
  > "$selected_file"

  while true; do
    display_drives

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
      continue
    fi
    
    local valid=true
    local has_system=false
    local selected_count=0

    for num in $selection; do
      if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input: '$num' is not a number${NC}"
        valid=false
        break
      fi
      
      local total=$(wc -l < "$drives_file" | tr -d ' ')
      if [[ $num -lt 1 || $num -gt $total ]]; then
        echo -e "${RED}Invalid number: $num (valid range: 1-$total)${NC}"
        valid=false
        break
      fi

      local device=$(sed -n "${num}p" "$drives_file")
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
        echo -e "  Device: $device ($(echo "$info" | cut -d'|' -f1))"
        echo -e "  Model: $(echo "$info" | cut -d'|' -f2)"
        echo -n "Are you sure? Type 'YES' to confirm: "
        read -r confirm
        if [[ "$confirm" != "YES" ]]; then
          echo "Skipping $device"
          continue
        fi
      fi

      # Check for duplicates
      if grep -q "^$device$" "$selected_file" 2>/dev/null; then
        echo -e "${YELLOW}Drive $device already selected${NC}"
        continue
      fi

      echo "$device" >> "$selected_file"
      ((selected_count++))
    done

    if [[ "$valid" == "false" ]]; then
      if [[ "$has_system" == "true" ]]; then
        echo -e "${RED}Please remove SYSTEM drives from your selection.${NC}"
      fi
      echo "Press Enter to try again..."
      read -r
      continue
    fi

    if [[ $selected_count -eq 0 ]]; then
      echo -e "${YELLOW}No drives selected.${NC}"
      echo "Press Enter to try again..."
      read -r
      continue
    fi

    echo
    echo -e "${GREEN}Selected $selected_count drive(s):${NC}"
    while read -r drive; do
      local info=$(get_drive_info "$drive")
      local size=$(echo "$info" | cut -d'|' -f1)
      local model=$(echo "$info" | cut -d'|' -f2)
      echo -e "  ${YELLOW}$drive${NC} - $size - $model"
    done < "$selected_file"
    
    echo
    echo -n "Proceed with these drives? (y/N): "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      return 0
    else
      # Clear selections and try again
      > "$selected_file" 
    fi
  done
}

# Final confirmation
confirm_wipe() {
  local selected_file="$1"

  show_banner
  echo -e "${BOLD}${RED}FINAL CONFIRMATION${NC}"
  echo "=================="
  echo
  echo -e "${RED}The following drives will be PERMANENTLY WIPED using DoD 5220.22-M standard:${NC}"
  echo

  while read -r drive; do
    local info=$(get_drive_info "$drive")
    local size=$(echo "$info" | cut -d'|' -f1)
    local model=$(echo "$info" | cut -d'|' -f2)
    echo -e "  ${YELLOW}$drive${NC} - $size - $model"
  done < "$selected_file"

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

# Wipe drive using DoD 5220.22-M standard
wipe_drive() {
  local device="$1"
  local report_dir="/tmp/wipe_reports"
  mkdir -p "$report_dir"
  
  local report_file="$report_dir/wipe_report_$(basename "$device")_$(date +%Y%m%d_%H%M%S).txt"

  echo -e "${BLUE}Wiping $device...${NC}"

  # Get device info for the report
  local info=$(get_drive_info "$device")
  local size=$(echo "$info" | cut -d'|' -f1)
  local model=$(echo "$info" | cut -d'|' -f2)

  # Create report
  {
    echo "====================================="
    echo "Drive Secure Wipe Report"
    echo "====================================="
    echo "Date: $(date)"
    echo "Device: $device"
    echo "Model: $model"
    echo "Size: $size"
    echo "Standard: DoD 5220.22-M (3 passes + zero)"
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
      echo -e "    ${RED}Shred operation failed${NC}"
    fi
  else
    echo "    Using dd (DoD 5220.22-M: 3 passes + zero)..."
    echo "$(date): Starting dd operation" >>"$report_file"

    for pass in {1..3}; do
      echo "      Pass $pass/4: Random data"
      echo "$(date): Pass $pass - random data" >>"$report_file"
      
      if ! dd if=/dev/urandom of="$device" bs=1M 2>>"$report_file"; then
        status="FAILED"
        break
      fi
      echo "      Pass $pass completed"
    done

    if [[ "$status" == "SUCCESS" ]]; then
      echo "      Pass 4/4: Zero fill"
      echo "$(date): Pass 4 - zero fill" >>"$report_file"
      
      if ! dd if=/dev/zero of="$device" bs=1M 2>>"$report_file"; then
        status="FAILED"
      fi
      echo "      Pass 4 completed"
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Update report
  {
    echo
    echo "Wipe Completed: $(date)"
    echo "Duration: $(format_time $duration)"
    echo "Final Status: $status"
  } >>"$report_file"

  if [[ "$status" == "SUCCESS" ]]; then
    echo -e "    ${GREEN}✓ Wipe completed successfully${NC}"
  else
    echo -e "    ${RED}✗ Wipe failed${NC}"
  fi

  echo -e "    Report saved: ${CYAN}$report_file${NC}"
  return 0
}

# Main function
main() {
  show_banner
  echo

  check_requirements

  # Use temporary files for drive list and selections
  local drives_file=$(mktemp)
  local selected_file=$(mktemp)
  
  echo "Scanning for disk drives..."
  
  # Get user selection
  if ! get_selection "$drives_file" "$selected_file"; then
    rm -f "$drives_file" "$selected_file"
    exit 1
  fi
  
  # Check if any drives were selected
  if [[ ! -s "$selected_file" ]]; then
    echo -e "${RED}No drives were selected.${NC}"
    rm -f "$drives_file" "$selected_file"
    exit 1
  fi

  # Final confirmation
  if ! confirm_wipe "$selected_file"; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    rm -f "$drives_file" "$selected_file"
    exit 0
  fi

  echo
  echo -e "${BOLD}${BLUE}Starting wipe operations...${NC}"
  echo

  # Wipe each selected drive
  local start_total=$(date +%s)
  while read -r drive; do
    wipe_drive "$drive"
    echo
  done < "$selected_file"
  local end_total=$(date +%s)
  local duration_total=$((end_total - start_total))

  echo -e "${GREEN}${BOLD}All operations completed!${NC}"
  echo -e "Total time: $(format_time $duration_total)"
  echo -e "Reports saved in ${CYAN}/tmp/wipe_reports/${NC}"
  
  # Clean up temporary files
  rm -f "$drives_file" "$selected_file"
}

# Run main function
main "$@"
