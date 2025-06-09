#!/bin/bash

echo "=== Drive Detection Debug ==="
echo

echo "1. Raw lsblk output:"
lsblk -d -n -o NAME,SIZE,TYPE
echo

echo "2. Processing each line:"
while IFS= read -r line; do
  device=$(echo "$line" | awk '{print $1}')
  size=$(echo "$line" | awk '{print $4}')
  type=$(echo "$line" | awk '{print $6}')

  echo "  Line: '$line'"
  echo "  Device: '$device'"
  echo "  Size: '$size'"
  echo "  Type: '$type'"

  if [[ "$type" != "disk" ]]; then
    echo "  → Skipping (not a disk)"
  else
    echo "  → Processing as disk"
    echo "    udev info for /dev/$device:"
    udevadm info --query=property --name="/dev/$device" 2>/dev/null | head -5
  fi
  echo
done < <(lsblk -d -n -o NAME,SIZE,TYPE)

echo "3. Count of disk devices:"
lsblk -d -n -o NAME,SIZE,TYPE | awk '$6 == "disk"' | wc -l
