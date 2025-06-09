# Check what the script would see
for dev in sdb sdc sdd sde; do
  echo "=== /dev/$dev ==="
  echo "udev ID_BUS: $(udevadm info --query=property --name=/dev/$dev 2>/dev/null | grep ID_BUS || echo 'Not found')"
  echo "Device path: $(udevadm info --query=path --name=/dev/$dev 2>/dev/null)"
  echo "Removable: $(cat /sys/block/$dev/removable 2>/dev/null || echo 'Unknown')"
  echo "Size: $(blockdev --getsize64 /dev/$dev 2>/dev/null || echo 'Unknown') bytes"
  echo "Vendor: $(cat /sys/block/$dev/device/vendor 2>/dev/null | tr -d ' ' || echo 'Unknown')"
  echo "Model: $(cat /sys/block/$dev/device/model 2>/dev/null | tr -d ' ' || echo 'Unknown')"
  echo
done
