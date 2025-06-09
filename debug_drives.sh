#!/bin/bash

# Debug script to identify drive detection issues

echo "=== Drive Detection Debug ==="
echo "OS: $(uname)"
echo "User: $(whoami)"
echo

if [[ "$(uname)" == "Darwin" ]]; then
  echo "1. Raw diskutil list:"
  diskutil list || echo "diskutil failed"
  echo

  echo "2. Checking for external drives:"
  diskutil list | grep -E "^/dev/disk[0-9]+" | while read device rest; do
    echo "  Device: $device"
    echo "    Checking if readable..."
    if [[ -r "$device" ]]; then
      echo "    ✓ Readable"
      echo "    Getting info..."
      if timeout 5 diskutil info "$device" | grep -E "(Removable|Protocol|Internal)" | head -3; then
        echo "    ✓ Info retrieved"
      else
        echo "    ✗ Info retrieval failed/timeout"
      fi
    else
      echo "    ✗ Not readable"
    fi
    echo
  done
else
  echo "1. Raw lsblk output:"
  lsblk -d -n -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE || echo "lsblk failed"
  echo

  echo "2. Checking each disk:"
  lsblk -d -n -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE | while read line; do
    name=$(echo "$line" | awk '{print $1}')
    removable=$(echo "$line" | awk '{print $3}')
    type=$(echo "$line" | awk '{print $6}')

    echo "  Device: /dev/$name (removable=$removable, type=$type)"

    if [[ -r "/dev/$name" ]]; then
      echo "    ✓ Readable"
    else
      echo "    ✗ Not readable"
    fi
  done
fi

echo
echo "3. Testing get_drives function:"

get_drives() {
  local drives=()

  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  macOS path - checking diskutil list"
    while read -r device; do
      echo "    Found device: $device"
      if [[ "$device" =~ /dev/disk[0-9]+$ ]]; then
        echo "      Matches pattern"
        if [[ -r "$device" ]]; then
          echo "      Is readable"
          echo "      Getting diskutil info..."
          if info=$(timeout 10 diskutil info "$device" 2>/dev/null); then
            echo "      Got info successfully"
            if echo "$info" | grep -E "(Removable Media: +Yes|Protocol: +USB)" >/dev/null; then
              echo "      Is removable/USB - ADDING"
              drives+=("$device")
            else
              echo "      Not removable/USB - skipping"
            fi
          else
            echo "      Failed to get info - skipping"
          fi
        else
          echo "      Not readable - skipping"
        fi
      else
        echo "      Doesn't match pattern - skipping"
      fi
    done < <(diskutil list | grep -E "^/dev/disk[0-9]+" | awk '{print $1}')
  else
    echo "  Linux path - checking lsblk"
    while read -r line; do
      echo "    Processing line: $line"
      local name=$(echo "$line" | awk '{print $1}')
      local removable=$(echo "$line" | awk '{print $3}')
      local type=$(echo "$line" | awk '{print $6}')

      echo "      name=$name, removable=$removable, type=$type"

      if [[ "$type" == "disk" && "$removable" == "1" ]]; then
        echo "      Is removable disk - ADDING"
        drives+=("/dev/$name")
      else
        echo "      Not removable disk - skipping"
      fi
    done < <(lsblk -d -n -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE 2>/dev/null || echo "lsblk failed")
  fi

  printf '%s\n' "${drives[@]}"
}

echo "Running get_drives function..."
get_drives

echo
echo "=== Debug Complete ==="
