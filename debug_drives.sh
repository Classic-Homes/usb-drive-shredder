#!/bin/bash

echo "=== Enhanced Drive Detection Debug ==="
echo "Timestamp: $(date)"
echo "User: $(whoami)"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "WARNING: Not running as root. Some information may be limited."
  echo "Run with 'sudo bash debug_drives.sh' for complete information."
  echo
fi

echo "1. System Information:"
# Check if on macOS or Linux and adjust commands
if [[ "$(uname)" == "Darwin" ]]; then
  echo "   OS: macOS $(sw_vers -productVersion)"
  echo "   Kernel: $(uname -r)"
  echo "   Architecture: $(uname -m)"
else
  echo "   OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")"
  echo "   Kernel: $(uname -r)"
  echo "   Architecture: $(uname -m)"
fi
echo

echo "2. Block Device Commands Available:"
# Add diskutil for macOS
if [[ "$(uname)" == "Darwin" ]]; then
  for cmd in diskutil dd shred; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "   ✓ $cmd: $(which "$cmd")"
    else
      echo "   ✗ $cmd: NOT FOUND"
    fi
  done
else
  for cmd in lsblk udevadm blockdev shred; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "   ✓ $cmd: $(which "$cmd")"
    else
      echo "   ✗ $cmd: NOT FOUND"
    fi
  done
fi
echo

# OS-specific block device listing
if [[ "$(uname)" == "Darwin" ]]; then
  echo "3. Raw diskutil output (all devices):"
  diskutil list
  echo

  echo "4. Raw diskutil output (physical disks only):"
  diskutil list | grep -E "^/dev/disk[0-9]+" | grep -v "(disk image)"
  echo
else
  echo "3. Raw lsblk output (all devices):"
  lsblk
  echo

  echo "4. Raw lsblk output (disks only with details):"
  lsblk -d -o NAME,SIZE,TYPE,VENDOR,MODEL,SERIAL,TRAN
  echo
fi

echo "5. Processing each disk device:"
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS version to process disks
  while read -r device; do
    name=$(basename "$device")
    echo "  Device name: '$name'"
    size=$(diskutil info "$device" | grep "Disk Size" | awk '{print $3, $4}')
    echo "  Size: '$size'"

    echo "  → Processing as disk: $device"

    # Check if device exists
    if [[ -b "$device" ]]; then
      echo "    ✓ Block device exists"
    else
      echo "    ✗ Block device does not exist"
    fi

    # Check if device is readable
    if [[ -r "$device" ]]; then
      echo "    ✓ Device is readable"
    else
      echo "    ✗ Device is not readable (may need root)"
    fi

    # Get device info
    echo "    Device properties:"
    diskutil info "$device" | grep -E "Device|Protocol|Removable|Ejectable|Whole|Internal" | sed 's/^/      /'

    # Check mount status
    echo "    Mount status:"
    mount_point=$(diskutil info "$device" | grep "Mount Point" | sed 's/.*Mount Point: *//')
    if [[ -n "$mount_point" && "$mount_point" != "(not mounted)" ]]; then
      echo "      MOUNTED: $device on $mount_point"
    else
      echo "      Not mounted"
    fi

    # Check filesystem types
    echo "    Filesystem type:"
    fs_type=$(diskutil info "$device" | grep "File System" | head -1 | sed 's/.*File System: *//')
    if [[ -n "$fs_type" && "$fs_type" != "None" ]]; then
      echo "      $fs_type"
    else
      echo "      None detected"
    fi
    echo
  done < <(diskutil list | grep -E "^/dev/disk[0-9]+" | awk '{print $1}')
else
  # Linux version to process disks
  while IFS= read -r line; do
    # Parse the line
    name=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    type=$(echo "$line" | awk '{print $3}')

    echo "  Line: '$line'"
    echo "  Device name: '$name'"
    echo "  Size: '$size'"
    echo "  Type: '$type'"

    if [[ "$type" != "disk" ]]; then
      echo "  → Skipping (not a disk)"
    else
      device="/dev/$name"
      echo "  → Processing as disk: $device"

      # Check if device exists
      if [[ -b "$device" ]]; then
        echo "    ✓ Block device exists"
      else
        echo "    ✗ Block device does not exist"
      fi

      # Check if device is readable
      if [[ -r "$device" ]]; then
        echo "    ✓ Device is readable"
      else
        echo "    ✗ Device is not readable (may need root)"
      fi

      # Get device size
      if command -v blockdev >/dev/null 2>&1 && [[ -r "$device" ]]; then
        size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null || echo "unknown")
        echo "    Size: $size_bytes bytes"
      fi

      # Get udev info
      echo "    udev properties:"
      if command -v udevadm >/dev/null 2>&1; then
        udevadm info --query=property --name="$device" 2>/dev/null | grep -E "ID_(VENDOR|MODEL|SERIAL|BUS|TYPE)" | head -10 | sed 's/^/      /'
      else
        echo "      udevadm not available"
      fi

      # Check mount status
      echo "    Mount status:"
      if mount | grep -q "^$device"; then
        mount | grep "^$device" | sed 's/^/      MOUNTED: /'
      else
        echo "      Not mounted"
      fi

      # Check filesystem types - FIXED DUPLICATE OUTPUT
      echo "    Filesystem types:"
      if lsblk -n -o FSTYPE "$device" 2>/dev/null | grep -v "^$" | head -5 >/dev/null; then
        lsblk -n -o FSTYPE "$device" 2>/dev/null | grep -v "^$" | sed 's/^/      /' | head -5
      else
        echo "      None detected"
      fi
    fi
    echo
  done < <(lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null)
fi

echo "6. USB Devices Detection:"
if [[ "$(uname)" == "Darwin" ]]; then
  echo "   USB devices from system_profiler:"
  system_profiler SPUSBDataType 2>/dev/null | grep -A 10 -B 3 -i "Mass Storage" | sed 's/^/   /' || echo "   Unable to get USB info"
else
  echo "   USB devices from lsusb:"
  if command -v lsusb >/dev/null 2>&1; then
    lsusb | grep -i -E "(storage|mass|disk|drive)" | sed 's/^/   /'
    if [[ $(lsusb | grep -i -E "(storage|mass|disk|drive)" | wc -l) -eq 0 ]]; then
      echo "   No USB storage devices found by lsusb"
    fi
  else
    echo "   lsusb not available"
  fi
fi
echo

echo "7. Drive Detection Function Test:"
echo "   Function to get available drives:"

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
    # Linux version - unchanged
    while IFS= read -r line; do
      local name=$(echo "$line" | awk '{print $1}')
      local size=$(echo "$line" | awk '{print $2}')
      local type=$(echo "$line" | awk '{print $3}')

      if [[ "$type" == "disk" ]]; then
        if [[ "$name" != /dev/* ]]; then
          name="/dev/$name"
        fi

        if [[ -b "$name" ]] && [[ -r "$name" ]]; then
          drives+=("$name")
        fi
      fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null || true)
  fi

  printf '%s\n' "${drives[@]}"
}

mapfile -t detected_drives < <(get_available_drives)
echo "   Detected drives:"
if [[ ${#detected_drives[@]} -eq 0 ]]; then
  echo "   No drives detected by function"
else
  for drive in "${detected_drives[@]}"; do
    echo "     $drive"
  done
fi
echo

echo "8. VM-Specific Checks:"
echo "   Checking for virtualization:"
if [[ "$(uname)" == "Darwin" ]]; then
  if system_profiler SPHardwareDataType | grep -q "Model.*Virtual"; then
    echo "   Virtualization: Running in a virtual machine"
  else
    echo "   Virtualization: Physical hardware detected"
  fi
else
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt_type=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    echo "   Virtualization: $virt_type"
  else
    echo "   systemd-detect-virt not available"
  fi
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "   Checking system.log for USB events (last 10 lines):"
  if [[ $EUID -eq 0 ]]; then
    log show --predicate 'subsystem == "com.apple.iokit.IOUSBFamily"' --last 1h | tail -10 | sed 's/^/   /'
  else
    echo "   (Need root access to check detailed USB logs)"
  fi
else
  echo "   Checking dmesg for USB events (last 10 lines):"
  if [[ $EUID -eq 0 ]]; then
    dmesg | grep -i usb | tail -10 | sed 's/^/   /'
  else
    echo "   (Need root access to check dmesg)"
  fi
fi
echo

echo "9. Recommendations:"
if [[ ${#detected_drives[@]} -eq 0 ]]; then
  echo "   No drives detected. Try:"
  echo "   - Ensure USB drives are properly connected"
  echo "   - Check VM USB passthrough configuration (if applicable)"
  echo "   - Run as root: sudo bash debug_drives.sh"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "   - Check Security & Privacy settings for disk access"
  else
    echo "   - Check VM host USB device assignment"
  fi
  echo "   - Try unplugging and reconnecting USB devices"
else
  echo "   Found ${#detected_drives[@]} drive(s). The script should work."
fi

echo
echo "=== Debug Complete ==="
