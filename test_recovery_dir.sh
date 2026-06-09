#!/bin/bash

# Test script to verify recovery directory consistency

# Function to get the real user's home directory (handles sudo)
get_real_home() {
    if [ -n "$SUDO_USER" ]; then
        # Running with sudo - get the actual user's home
        echo "/home/$SUDO_USER"
    else
        # Running normally
        echo "$HOME"
    fi
}

# Set recovery directory to always use real user's home
RECOVERY_DIR="$(get_real_home)/.rsync_recovery"

echo "Test Recovery Directory Detection"
echo "================================"
echo ""
echo "Current user: $(whoami)"
echo "EUID: $EUID"
echo "HOME: $HOME"
echo "SUDO_USER: $SUDO_USER"
echo ""
echo "Real home directory: $(get_real_home)"
echo "Recovery directory: $RECOVERY_DIR"
echo ""

# Test if directory exists
if [ -d "$RECOVERY_DIR" ]; then
    echo "Recovery directory exists."
    echo "Number of recovery files: $(ls -1 "$RECOVERY_DIR"/recovery_* 2>/dev/null | wc -l)"
else
    echo "Recovery directory does not exist."
fi