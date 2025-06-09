# USB Drive Shredder

A set of Bash scripts to securely wipe USB drives according to DoD 5220.22-M standards. This tool is designed to work in both Linux and macOS environments, including virtual machines with USB passthrough.

## Features

- Securely wipes drives using DoD 5220.22-M standard (3 passes + final zero pass)
- Cross-platform compatibility (Linux and macOS)
- Safety checks to prevent accidental wiping of system drives
- Concurrent wiping of multiple drives
- Detailed logging of all operations
- Debug mode for troubleshooting drive detection issues

## Requirements

### For Linux:
- `bash` 4.0+
- `lsblk`, `udevadm`, `blockdev` (typically included in most Linux distributions)
- `shred` (part of GNU coreutils)
- Root access (sudo)

### For macOS:
- `bash` 3.2+
- `diskutil` (included in macOS)
- `shred` (can be installed via Homebrew: `brew install coreutils`)
- Root access (sudo)

## Usage

### Debug Script

If you're having trouble with drive detection, run the debug script first:

```bash
sudo bash debug_drives.sh
```

This script will:
- Display system information
- List all detected storage devices
- Check for USB devices 
- Test the drive detection function
- Provide recommendations for troubleshooting

### Drive Wiping Script

To securely wipe USB drives:

```bash
sudo bash usb_wipe.sh
```

The script will:
1. Display all detected drives with safety ratings
2. Allow you to select drives for wiping
3. Ask for confirmation before starting the wiping process
4. Show real-time progress of the wiping operation
5. Generate detailed logs

## Safety Features

The script includes several safety mechanisms:
- Color-coded safety levels for each drive (SAFE, CAUTION, DANGEROUS)
- Detection of system drives and mounted partitions
- Multiple confirmation prompts for dangerous operations
- Different confirmation levels based on drive safety rating

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Disclaimer

This software is provided as-is with no warranty. Always verify the selected drives before wiping as data recovery from wiped drives is extremely difficult or impossible.
