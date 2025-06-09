# Test each drive individually
for drive in /dev/sd? /dev/nvme*; do
  if [[ -e "$drive" ]]; then
    echo "Testing $drive..."
    timeout 3 lsblk -d -no size "$drive" || echo "  -> This drive timed out"
  fi
done
