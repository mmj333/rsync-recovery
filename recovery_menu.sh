#!/bin/bash

# Recovery Menu - Orchestrator for rsync recovery tools
# Provides easy access to all recovery functions

# Debug mode - set to "yes" to enable flow tracing (should match rsync_recovery.sh setting)
DEBUG_MODE="no"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory - also cd there for consistent behavior
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Debug logging function
debug_log() {
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo -e "${PURPLE}[DEBUG recovery_menu]${NC} $1"
    fi
}

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

# Check if running with sudo
check_sudo_status() {
    if [ "$EUID" -eq 0 ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Auto-elevate to sudo if not already running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}This script works best with sudo privileges.${NC}"
    echo -e "${CYAN}Attempting to elevate for full features (SMART data, mounting, etc.)...${NC}"
    echo ""
    # Preserve DISPLAY and XAUTHORITY so gnome-terminal can open windows
    sudo DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" "$0" "$@"
    sudo_result=$?
    # If sudo succeeded and the script ran, we're done (the elevated script already ran)
    if [ $sudo_result -eq 0 ]; then
        exit 0
    fi
    # Sudo failed - ask user what to do
    echo ""
    echo -e "${YELLOW}Could not obtain sudo privileges.${NC}"
    echo -n "Continue with limited features? [y/N]: "
    read -r continue_choice
    if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
        echo "Exiting."
        exit 1
    fi
    echo ""
fi

# Function to display the main menu
show_main_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}     ${GREEN}Data Recovery Tool Suite${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}        ${YELLOW}Main Menu${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"

    # Show sudo status
    if [ "$(check_sudo_status)" = "true" ]; then
        echo -e "${GREEN}Running with administrator privileges ✓${NC}"
    else
        echo -e "${YELLOW}Running without sudo (limited features)${NC}"
        echo -e "${CYAN}Some features unavailable:${NC} SMART data, mounting partitions"
    fi

    echo ""
    echo -e "${GREEN}1.${NC} Start New Recovery"
    echo -e "${GREEN}2.${NC} Resume Previous Recovery"
    echo -e "${GREEN}3.${NC} Verify Recent Recovery"
    echo -e "${GREEN}4.${NC} View Recent Recovery Sessions"
    echo -e "${GREEN}5.${NC} Test Folder Processing Order"
    echo -e "${GREEN}6.${NC} Advanced Options"
    echo -e "${GREEN}7.${NC} Help & Documentation"
    echo -e "${RED}8.${NC} Exit"

    echo ""
    echo -n "Select an option [1-8]: "
}

# Function to display recent recoveries
show_recent_recoveries() {
    echo -e "${YELLOW}Recent Recovery Sessions:${NC}"
    echo "========================="
    
    local recovery_dir="$RECOVERY_DIR"
    if [ ! -d "$recovery_dir" ]; then
        echo "No recovery sessions found."
        return 1
    fi
    
    # Get last 10 recovery files
    local count=0
    for recovery_file in $(ls -t "$recovery_dir"/recovery_* 2>/dev/null | head -10); do
        count=$((count + 1))
        echo ""
        echo -e "${GREEN}[$count]${NC} Session from: $(basename "$recovery_file")"
        
        # Extract key details
        source "$recovery_file" 2>/dev/null
        echo "    Timestamp: $TIMESTAMP"
        echo "    Source: $SOURCE_PATH"
        # Show final destination if different from base destination
        if [ -n "$FINAL_DEST_PATH" ] && [ "$FINAL_DEST_PATH" != "$DEST_PATH" ]; then
            echo "    Destination: $FINAL_DEST_PATH"
            echo "    Base drive: $DEST_PATH"
        else
            echo "    Destination: $DEST_PATH"
        fi
        
        # Check if destination has verification reports and error logs
        # Use final destination if available
        local check_path="${FINAL_DEST_PATH:-$DEST_PATH}"
        if [ -n "$check_path" ] && [ -d "$check_path" ]; then
            local verif_count=$(ls "$check_path"/verification_summary_*.txt 2>/dev/null | wc -l)
            local error_count=$(ls "$check_path"/recovery_errors_*.txt 2>/dev/null | wc -l)
            
            if [ $verif_count -gt 0 ]; then
                echo -e "    ${CYAN}Verification reports available: $verif_count${NC}"
            fi
            
            if [ $error_count -gt 0 ]; then
                echo -e "    ${CYAN}Recovery logs available: $error_count${NC}"
                # Check the most recent error log for actual errors
                local latest_error_log=$(ls -t "$check_path"/recovery_errors_*.txt 2>/dev/null | head -1)
                if [ -f "$latest_error_log" ]; then
                    # Check if it's a success log
                    if grep -q "SUCCESS! NO ERRORS!" "$latest_error_log" 2>/dev/null; then
                        echo -e "    ${GREEN}✓ Last recovery: SUCCESS - No errors!${NC}"
                    else
                        local error_file_count=$(wc -l < "$latest_error_log")
                        if [ $error_file_count -gt 0 ]; then
                            echo -e "    ${RED}⚠️  Failed files in last recovery: $error_file_count${NC}"
                        fi
                    fi
                fi
            fi
        fi
    done
    
    return 0
}

# Function to select a recent recovery
select_recent_recovery() {
    local recovery_dir="$RECOVERY_DIR"
    local recovery_files=($(ls -t "$recovery_dir"/recovery_* 2>/dev/null | head -10))
    
    if [ ${#recovery_files[@]} -eq 0 ]; then
        echo -e "${RED}No recent recovery sessions found.${NC}"
        return 1
    fi
    
    echo -n "Select recovery session number: "
    read -r selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#recovery_files[@]} ]; then
        local selected_file="${recovery_files[$((selection-1))]}"
        source "$selected_file"
        return 0
    else
        echo -e "${RED}Invalid selection.${NC}"
        return 1
    fi
}

# Function to run verification
run_verification() {
    echo -e "${YELLOW}Recovery Verification${NC}"
    echo "===================="
    
    show_recent_recoveries
    if [ $? -ne 0 ]; then
        echo ""
        echo "Alternatively, enter paths manually:"
        echo -n "Source path (or press Enter to go back): "
        read -r source_path
        [ -z "$source_path" ] && return
        
        echo -n "Destination path: "
        read -r dest_path
        [ -z "$dest_path" ] && return
        
        SOURCE_PATH="$source_path"
        DEST_PATH="$dest_path"
        # Check for final destination path
        FINAL_DEST_PATH="${FINAL_DEST_PATH:-$dest_path}"
    else
        echo ""
        if ! select_recent_recovery; then
            return
        fi
    fi
    
    # Check if error logs exist
    local verify_dest="${FINAL_DEST_PATH:-$DEST_PATH}"
    local error_logs_exist=false
    if [ -n "$verify_dest" ] && [ -d "$verify_dest" ]; then
        local error_count=$(ls "$verify_dest"/recovery_errors_*.txt 2>/dev/null | wc -l)
        [ $error_count -gt 0 ] && error_logs_exist=true
    fi
    
    echo ""
    echo -e "${GREEN}Verification Options:${NC}"
    echo "1. Quick (check existence only)"
    echo "2. Size verification"
    echo "3. Full checksum verification (slow)"
    if [ "$error_logs_exist" = true ]; then
        echo "4. View recovery logs only (safe for failing drives)"
    fi
    echo ""
    echo -e "${YELLOW}⚠️  Warning: If the source drive is failing, verification may cause:${NC}"
    echo "   - Additional stress on the failing drive"
    echo "   - System crashes or freezes"
    echo "   - Further drive degradation"
    echo ""
    if [ "$error_logs_exist" = true ]; then
        echo "   Consider option 4 (error logs) if drive is unstable."
    else
        echo "   Consider skipping verification if drive is unstable."
        echo "   (Error logs will be available after future recoveries)"
    fi
    echo ""
    local max_option=3
    [ "$error_logs_exist" = true ] && max_option=4
    echo -n "Select verification mode [1-$max_option]: "
    read -r verify_mode
    
    # Handle verification mode selection
    local verify_opts=""
    case "$verify_mode" in
        1) verify_opts="--quick" ;;
        2) verify_opts="--size" ;;
        3) verify_opts="--checksum" ;;
        4)
            if [ "$error_logs_exist" = true ]; then
                # View error logs instead of running verification
                echo ""
                echo -e "${YELLOW}Viewing recovery logs for: $verify_dest${NC}"
                echo ""
                
                # Find all error logs
                local error_logs=($(ls -t "$verify_dest"/recovery_errors_*.txt 2>/dev/null))
                
                if [ ${#error_logs[@]} -gt 0 ]; then
                    echo "Found ${#error_logs[@]} recovery log(s):"
                    echo ""
                    
                    # Display each error log
                    for log in "${error_logs[@]}"; do
                        # Check if it's a success log
                        if grep -q "SUCCESS! NO ERRORS!" "$log" 2>/dev/null; then
                            echo -e "${GREEN}=== $(basename "$log") ===${NC}"
                            cat "$log"
                        else
                            echo -e "${RED}=== $(basename "$log") ===${NC}"
                            local line_count=$(wc -l < "$log")
                            echo "Failed files: $line_count"
                            echo ""
                            
                            if [ $line_count -le 50 ]; then
                                cat "$log"
                            else
                                echo "First 25 files:"
                                head -25 "$log"
                                echo "..."
                                echo "Last 25 files:"
                                tail -25 "$log"
                                echo ""
                                echo "(Showing 50 of $line_count failed files)"
                            fi
                        fi
                        echo ""
                    done
                    
                    echo -e "${YELLOW}Summary:${NC}"
                    echo "- These files failed to copy during recovery"
                    echo "- You may want to attempt manual recovery of critical files"
                    echo "- Running --resume may retry these files (if drive is stable)"
                else
                    echo -e "${GREEN}No error logs found!${NC}"
                fi
                
                echo ""
                echo -n "Press Enter to continue..."
                read -r
                return
            else
                echo -e "${RED}Invalid option${NC}"
                return
            fi
            ;;
        *) echo -e "${RED}Invalid option${NC}"; return ;;
    esac
    
    # Use same exclude settings as original recovery
    # If it wasn't Copy Everything mode, exclude system folders
    if [ "$MODE_CHOICE" != "3" ] && [ "$MODE_CHOICE" != "" ]; then
        verify_opts="$verify_opts --exclude-system"
    fi
    
    # Show what settings we're using
    echo ""
    echo -e "${YELLOW}Original Recovery Settings:${NC}"
    echo "  Source: $(basename "$SOURCE_PATH")"
    echo "  Destination: $(basename "${FINAL_DEST_PATH:-$DEST_PATH}")"
    if [ "$FILE_TYPE_FILTER" = "yes" ]; then
        echo -n "  File types: "
        filter_list=""
        [ "$FILTER_PICTURES" = "yes" ] && filter_list="${filter_list}Pictures "
        [ "$FILTER_VIDEOS" = "yes" ] && filter_list="${filter_list}Videos "
        [ "$FILTER_DOCUMENTS" = "yes" ] && filter_list="${filter_list}Documents "
        [ "$FILTER_AUDIO" = "yes" ] && filter_list="${filter_list}Audio "
        # Remove trailing space and display
        echo "${filter_list% }"
    else
        echo "  File types: All"
    fi
    echo -n "  System folders: "
    if [ "$MODE_CHOICE" = "3" ]; then
        echo "Included"
    else
        echo "Excluded"
    fi
    
    echo ""
    echo -e "${YELLOW}Running verification...${NC}"
    # Use final destination if available for verification
    local verify_dest="${FINAL_DEST_PATH:-$DEST_PATH}"
    
    # Export filter settings for verification script
    # Debug: show current values before export
    # echo "DEBUG: Before export - FILTER_PICTURES=$FILTER_PICTURES, FILTER_VIDEOS=$FILTER_VIDEOS"
    
    # Don't modify variables if they already exist
    export FILE_TYPE_FILTER FILTER_PICTURES FILTER_VIDEOS FILTER_DOCUMENTS FILTER_AUDIO
    
    "$SCRIPT_DIR/verify_recovery.sh" "$SOURCE_PATH" "$verify_dest" $verify_opts
    
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# Function to manage loop devices
manage_loop_devices() {
    echo -e "${YELLOW}Loop Device Management${NC}"
    echo "====================="
    echo ""
    
    # Check if running with sudo
    if [ "$(check_sudo_status)" = "false" ]; then
        echo -e "${RED}Note: Some operations require sudo privileges${NC}"
        echo ""
    fi
    
    # List current loop devices
    echo "Current loop devices:"
    echo ""
    
    local loop_info=$(losetup -a 2>/dev/null)
    if [ -z "$loop_info" ]; then
        echo "No loop devices currently in use."
    else
        # Parse and display loop device info
        while IFS= read -r line; do
            local device=$(echo "$line" | cut -d: -f1)
            local file=$(echo "$line" | grep -o '(.*)' | tr -d '()')
            
            echo -e "${CYAN}$device${NC}"
            echo "  File: $file"
            
            # Check if mounted
            local mount_info=$(mount | grep "^$device" | awk '{print $3}')
            if [ -n "$mount_info" ]; then
                echo "  Mounted at: $mount_info"
            else
                # Check for partitions
                local partitions=$(ls ${device}p* 2>/dev/null)
                if [ -n "$partitions" ]; then
                    echo "  Partitions:"
                    for part in $partitions; do
                        local part_mount=$(mount | grep "^$part" | awk '{print $3}')
                        if [ -n "$part_mount" ]; then
                            echo "    $part → $part_mount"
                        else
                            echo "    $part (not mounted)"
                        fi
                    done
                else
                    echo "  Not mounted"
                fi
            fi
            echo ""
        done <<< "$loop_info"
    fi
    
    echo ""
    echo "Options:"
    echo "1. Unmount all loop devices"
    echo "2. Unmount specific loop device"
    echo "3. Refresh list"
    echo "4. Back to advanced menu"
    echo ""
    echo -n "Select option [1-4]: "
    read -r loop_choice
    
    case "$loop_choice" in
        1)
            if [ "$(check_sudo_status)" = "false" ]; then
                echo -e "${RED}This operation requires sudo privileges${NC}"
                echo "Please restart the menu with sudo"
            else
                echo ""
                echo "Unmounting all loop devices..."
                
                # First unmount any mounted partitions
                for device in $(losetup -a | cut -d: -f1); do
                    # Check device and its partitions
                    for part in $device ${device}p*; do
                        if mount | grep -q "^$part"; then
                            echo "Unmounting $part..."
                            umount "$part" 2>/dev/null || udisksctl unmount -b "$part" 2>/dev/null
                        fi
                    done
                    
                    # Remove loop device
                    echo "Removing $device..."
                    losetup -d "$device" 2>/dev/null
                done
                
                echo -e "${GREEN}All loop devices cleaned up${NC}"
            fi
            ;;
        2)
            echo -n "Enter loop device to unmount (e.g., /dev/loop0): "
            read -r specific_device
            
            if losetup -a | grep -q "^$specific_device:"; then
                if [ "$(check_sudo_status)" = "false" ]; then
                    echo -e "${RED}This operation requires sudo privileges${NC}"
                else
                    # Unmount any mounted partitions
                    for part in $specific_device ${specific_device}p*; do
                        if mount | grep -q "^$part"; then
                            echo "Unmounting $part..."
                            umount "$part" 2>/dev/null || udisksctl unmount -b "$part" 2>/dev/null
                        fi
                    done
                    
                    # Remove loop device
                    echo "Removing $specific_device..."
                    if losetup -d "$specific_device" 2>/dev/null; then
                        echo -e "${GREEN}Successfully removed $specific_device${NC}"
                    else
                        echo -e "${RED}Failed to remove $specific_device${NC}"
                    fi
                fi
            else
                echo -e "${RED}Device $specific_device not found${NC}"
            fi
            ;;
        3)
            manage_loop_devices
            return
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
    
    echo ""
    echo -n "Press Enter to continue..."
    read -r
    manage_loop_devices
}

# Function for advanced options
show_advanced_menu() {
    clear
    echo -e "${PURPLE}Advanced Options${NC}"
    echo "================"
    echo ""
    echo "1. Edit rsync_recovery.sh"
    echo "2. View recovery logs"
    echo "3. Clean old recovery sessions"
    echo "4. Backup scripts to SMB"
    echo "5. Show script versions"
    echo "6. Manage loop devices (disk images)"
    echo "7. Back to main menu"
    echo ""
    echo -n "Select option [1-7]: "
    read -r adv_choice
    
    case "$adv_choice" in
        1)
            ${EDITOR:-nano} "$SCRIPT_DIR/rsync_recovery.sh"
            ;;
        2)
            echo "Recent recovery destinations:"
            local count=0
            for recovery_file in $(ls -t "$RECOVERY_DIR"/recovery_* 2>/dev/null | head -5); do
                source "$recovery_file" 2>/dev/null
                count=$((count + 1))
                # Show final destination if available
                local display_path="${FINAL_DEST_PATH:-$DEST_PATH}"
                echo "$count. $display_path"
            done
            echo -n "Select destination to view logs: "
            read -r log_choice
            # TODO: Implement log viewing
            ;;
        3)
            echo -n "Keep how many recent sessions? [10]: "
            read -r keep_count
            keep_count=${keep_count:-10}
            cd "$RECOVERY_DIR"
            ls -t recovery_* 2>/dev/null | tail -n +$((keep_count+1)) | xargs -r rm -v
            echo "Cleanup complete."
            ;;
        4)
            echo "Backing up scripts to SMB..."
            cp -v "$SCRIPT_DIR"/*.sh "/run/user/1000/gvfs/smb-share:server=fs,share=newservice/Backups - Data Recovery/Linux Scripts/" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Backup complete!${NC}"
            else
                echo -e "${RED}Backup failed. Is SMB mounted?${NC}"
            fi
            ;;
        5)
            echo "Script versions:"
            grep -H "^# Version:" "$SCRIPT_DIR"/*.sh 2>/dev/null || echo "Version information not found"
            echo ""
            echo "Changelog:"
            head -20 "$SCRIPT_DIR/CHANGELOG.md" 2>/dev/null
            ;;
        6)
            manage_loop_devices
            ;;
    esac
    
    if [ "$adv_choice" != "7" ]; then
        echo ""
        echo -n "Press Enter to continue..."
        read -r
    fi
}

# Function to play completion sound
play_completion_sound() {
    # Try different methods to play a sound
    if command -v paplay &> /dev/null; then
        # Use PulseAudio
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || \
        paplay /usr/share/sounds/ubuntu/stereo/dialog-information.ogg 2>/dev/null || \
        paplay /usr/share/sounds/gnome/default/alerts/glass.ogg 2>/dev/null
    elif command -v aplay &> /dev/null; then
        # Use ALSA
        echo -e '\a' | aplay 2>/dev/null
    else
        # Fallback to terminal bell
        echo -e '\a'
    fi
}

# Main menu loop
while true; do
    show_main_menu
    read -r choice
    
    case "$choice" in
        1)
            echo ""
            echo -e "${GREEN}Starting new recovery...${NC}"
            debug_log "Calling rsync_recovery.sh"
            "$SCRIPT_DIR/rsync_recovery.sh"
            debug_log "rsync_recovery.sh returned"
            
            # Ask if user wants to verify after completion
            echo ""
            echo -e "${GREEN}Recovery complete!${NC}"
            play_completion_sound
            
            debug_log "recovery_menu about to ask for verification"
            echo -n "Would you like to verify the recovery? [Y/n]: "
            read -r verify_choice
            if [[ ! "$verify_choice" =~ ^[Nn]$ ]]; then
                run_verification
            fi
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Resume Recovery Options:${NC}"
            echo "1. Normal resume (checks all files)"
            echo "2. Fast resume (uses manifest)"
            echo -n "Select resume type [1-2]: "
            read -r resume_type
            
            case "$resume_type" in
                1) "$SCRIPT_DIR/rsync_recovery.sh" --resume ;;
                2) "$SCRIPT_DIR/rsync_recovery.sh" --fast-resume ;;
                *) echo -e "${RED}Invalid option${NC}" ;;
            esac
            
            # Verification is now handled within rsync_recovery.sh
            # No need to ask again here
            ;;
        3)
            run_verification
            ;;
        4)
            clear
            show_recent_recoveries
            echo ""
            echo -n "Press Enter to continue..."
            read -r
            ;;
        5)
            echo -n "Enter source path to test: "
            read -r test_path
            if [ -n "$test_path" ] && [ -d "$test_path" ]; then
                "$SCRIPT_DIR/test_processing_order.sh" "$test_path"
            else
                echo -e "${RED}Invalid path${NC}"
            fi
            echo ""
            echo -n "Press Enter to continue..."
            read -r
            ;;
        6)
            show_advanced_menu
            ;;
        7)
            clear
            echo -e "${CYAN}Help & Documentation${NC}"
            echo "==================="
            echo ""
            echo "Recovery Script Suite v1.4.0"
            echo ""
            echo "Main Scripts:"
            echo "- rsync_recovery.sh: Main recovery tool"
            echo "- verify_recovery.sh: Verify completed recoveries"
            echo "- test_processing_order.sh: Preview folder processing order"
            echo "- recovery_menu.sh: This menu system"
            echo ""
            echo "For detailed documentation, see:"
            echo "- README.md: Full feature documentation"
            echo "- CHANGELOG.md: Version history"
            echo ""
            echo "Quick Tips:"
            echo "- Use Ctrl+C once to safely pause a recovery"
            echo "- Fast resume mode skips already-copied files"
            echo "- Copy Everything mode includes temp files and caches"
            echo "- Verification can catch missed or corrupted files"
            echo ""
            echo -n "Press Enter to continue..."
            read -r
            ;;
        8)
            echo ""
            echo -e "${GREEN}Thank you for using Recovery Tool Suite!${NC}"
            play_completion_sound
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
done