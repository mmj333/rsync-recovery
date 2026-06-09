#!/bin/bash

# Rsync Recovery Script
# Version: 1.9.3
# Date: 2025-08-18
#
# User preferences are stored the file: $SCRIPT_DIR/.rsync_recovery_preferences
# Currently stores: progress monitor on/off
# Future enhancements can add more preferences to this file

# Debug mode - set to "yes" to enable flow tracing
DEBUG_MODE="no"

# Get script directory for finding companion scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source preset configurations if available
if [ -f "$SCRIPT_DIR/recovery_presets.sh" ]; then
    source "$SCRIPT_DIR/recovery_presets.sh"
fi

# Source partition analyzer if available
if [ -f "$SCRIPT_DIR/partition_analyzer.sh" ]; then
    source "$SCRIPT_DIR/partition_analyzer.sh"
fi

# Source preset menu if available
if [ -f "$SCRIPT_DIR/preset_menu.sh" ]; then
    source "$SCRIPT_DIR/preset_menu.sh"
fi

# Source drive info functions if available
if [ -f "$SCRIPT_DIR/drive_info_functions.sh" ]; then
    source "$SCRIPT_DIR/drive_info_functions.sh"
fi

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

# Load user preferences
load_user_preferences() {
    # Store preferences in script directory (technician's system), not customer drive
    local prefs_file="$SCRIPT_DIR/.rsync_recovery_preferences"
    if [ -f "$prefs_file" ]; then
        # Load progress monitor preference
        local saved_progress=$(grep "^PROGRESS_MONITOR=" "$prefs_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$saved_progress" ]; then
            USE_PROGRESS_MONITOR="$saved_progress"
        fi
    fi
}

# Save user preferences
save_user_preferences() {
    # Store preferences in script directory (technician's system), not customer drive
    local prefs_file="$SCRIPT_DIR/.rsync_recovery_preferences"
    
    # Save current preferences
    cat > "$prefs_file" << EOF
# Rsync Recovery User Preferences
# Last updated: $(date)
PROGRESS_MONITOR=$USE_PROGRESS_MONITOR
EOF
}

# Function to cleanup mounted images on exit
cleanup_mounted_images() {
    if [ -n "$RECOVERY_IMAGE_MOUNT" ] && [ -d "$RECOVERY_IMAGE_MOUNT" ]; then
        echo "Cleaning up mounted image..."
        umount "$RECOVERY_IMAGE_MOUNT" 2>/dev/null
        rmdir "$RECOVERY_IMAGE_MOUNT" 2>/dev/null
    fi
    
    if [ -n "$RECOVERY_IMAGE_UDISK" ]; then
        echo "Unmounting via udisksctl..."
        udisksctl unmount -b "$RECOVERY_IMAGE_UDISK" 2>/dev/null
    fi
    
    if [ -n "$RECOVERY_IMAGE_LOOP" ] && [ -z "$RECOVERY_IMAGE_CREATED_LOOP" ]; then
        # Only remove loop device if we created it
        losetup -d "$RECOVERY_IMAGE_LOOP" 2>/dev/null
    fi
}

# Set trap to cleanup on exit
trap cleanup_mounted_images EXIT

# Function to find drive by label (for portable recovery)
find_drive_by_label() {
    local label="$1"
    
    # Check common mount points
    for mount_base in /media /mnt /Volumes; do
        if [ -d "$mount_base" ]; then
            # Check subdirectories
            for user_dir in "$mount_base"/*; do
                if [ -d "$user_dir/$label" ]; then
                    echo "$user_dir/$label"
                    return 0
                fi
            done
            # Also check direct mount
            if [ -d "$mount_base/$label" ]; then
                echo "$mount_base/$label"
                return 0
            fi
        fi
    done
    
    # Try using lsblk to find by label
    local mount_point=$(lsblk -o LABEL,MOUNTPOINT -n 2>/dev/null | grep "^$label " | awk '{print $2}')
    if [ -n "$mount_point" ] && [ "$mount_point" != "-" ]; then
        echo "$mount_point"
        return 0
    fi
    
    return 1
}

# Function to verify drive matches saved characteristics
verify_drive_match() {
    local mount_path="$1"
    local expected_size="$2"
    local expected_fstype="$3"
    local expected_uuid="$4"
    local drive_type="$5"  # "source" or "destination"
    
    # Get device from mount path
    local device=$(df --output=source "$mount_path" 2>/dev/null | tail -1)
    if [[ ! "$device" =~ ^/dev/ ]]; then
        echo -e "${YELLOW}Warning: Could not determine device for $mount_path${NC}"
        return 0  # Allow to proceed with warning
    fi
    
    # Get current drive info
    local current_size=$(lsblk -no SIZE "$device" 2>/dev/null | head -1)
    local current_fstype=$(lsblk -no FSTYPE "$device" 2>/dev/null | head -1)
    local current_uuid=$(lsblk -no UUID "$device" 2>/dev/null | head -1)
    
    local mismatches=0
    
    # Check size (most important)
    if [ "$expected_size" != "unknown" ] && [ "$expected_size" != "$current_size" ]; then
        echo -e "${RED}Size mismatch for $drive_type drive:${NC}"
        echo "  Expected: $expected_size"
        echo "  Found: $current_size"
        ((mismatches++))
    fi
    
    # Check filesystem type
    if [ "$expected_fstype" != "unknown" ] && [ "$expected_fstype" != "$current_fstype" ]; then
        echo -e "${YELLOW}Filesystem type mismatch for $drive_type drive:${NC}"
        echo "  Expected: $expected_fstype"
        echo "  Found: $current_fstype"
        ((mismatches++))
    fi
    
    # Check UUID if available
    if [ "$expected_uuid" != "unknown" ] && [ -n "$expected_uuid" ] && [ "$expected_uuid" != "$current_uuid" ]; then
        echo -e "${RED}UUID mismatch for $drive_type drive:${NC}"
        echo "  Expected: $expected_uuid"
        echo "  Found: $current_uuid"
        ((mismatches++))
    fi
    
    if [ $mismatches -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}This may not be the correct $drive_type drive!${NC}"
        echo -n "Continue anyway? [y/N]: "
        read -r continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Handles interrupted transfers and new copy operations with preservation of dates/properties
#
# LESSONS LEARNED & DESIGN DECISIONS:
#
# 1. FAILING DRIVE OPTIMIZATION:
#    - Single-pass directory scanning (no re-reading directories)
#    - Deferred items tracked by path for direct access later
#    - Priority order: User data → Fonts → Non-system folders → Programs → Games
#    - Minimizes disk seeks on struggling hardware
#
# 2. WHAT TO SKIP BY DEFAULT:
#    - Temp files/caches: Can save hours on slow drives
#    - System folders: Windows/Mac will recreate these
#    - Program Files: Usually need reinstalling anyway
#    - BUT: We grab Windows\Fonts and custom media (hard to recreate)
#
# 3. EDGE CASES WE HANDLE:
#    - Steam libraries: Huge but contain irreplaceable saves/mods
#    - Old games: Some only save in Program Files (pre-2010 era)
#    - Business software: QuickBooks files in ProgramData
#    - WSL/Dev environments: Often missed but critical
#    - Public/All Users folders: Sometimes contain shared business data
#
# 4. USER FOLDER PRIORITY:
#    - Pictures/Documents/Desktop first (irreplaceable)
#    - Then other folders (custom folders, etc.)
#    - AppData/Library last (mostly recreatable settings)
#
# 5. SMART DETECTION:
#    - Auto-detects user folders vs full drives
#    - Handles both "C:\Users\John" and "C:\Users" as source
#    - Skips symlinks (like "All Users" on newer Windows)
#
# 6. RECOVERY FEATURES:
#    - Resume capability with --append-verify (safer than --append)
#    - Error logging with failed file paths
#    - Summary of skipped folders with full paths
#    - Can re-run to grab missed files

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# File type definitions for filtering
# Picture formats - including RAW formats from various camera manufacturers
# Common formats first, then RAW, then specialized formats
PICTURE_EXTS="jpg jpeg jpe jfif png gif bmp tiff tif webp heic heif raw cr2 cr3 nef arw dng orf rw2 pef sr2 srw raf erf kdc dcr dcs mrw nrw ptx x3f mef mos gpr 3fr fff iiq rwl srf arq rw1 psd psb xcf ai eps svg ico icns jp2 j2k jxr hdp wdp tga pcx exr hdr pic pct pict kra krita clip afphoto aae xmp dop pp3 ctx"

# Video formats - common consumer and professional formats
# Phone/consumer formats first, then professional, then rare formats
VIDEO_EXTS="mp4 avi mkv mov wmv flv webm m4v mpg mpeg mpg4 mp2 mpe mpv m2p m4p qt h264 h265 hevc 3gp 3g2 mts m2ts ts m2v vob mod tod asf rm rmvb divx ogv ogg dv f4v f4p f4a f4b mxf braw r3d ari dnxhd dnxhr prores cine cin gifv m4s dav 264 265 lrv thm yuv mjpeg mjpg amv mtv mj2 roq nsv fli flc ivf vid rv rvmb dxr"

# Document formats - office documents, PDFs, ebooks, and text files
DOC_EXTS="doc docx docm pdf txt rtf odt odf ods odp odg xls xlsx xlsm xlsb xlam csv ppt pptx pptm pages numbers key tex md markdown rst epub mobi azw azw3 fb2 lit pdb html htm xml json yaml yml one wpd"

# Audio/Music formats - common and lossless formats
AUDIO_EXTS="mp3 wav flac aac ogg wma m4a m4b opus aiff aif ape alac mka mp2 ac3 dts ra rm ram mid midi kar"

# Global variable to track if we're in the middle of a transfer
TRANSFER_IN_PROGRESS=false
CURRENT_SOURCE=""
CURRENT_DEST=""
# Track exit code for completion checking
EXIT_CODE=0
# Session timestamp for consistency
SESSION_TIMESTAMP=""

# Manifest mode variables
USE_MANIFEST="no"
MANIFEST_FILE=""

# Progress monitoring variables
USE_PROGRESS_MONITOR="yes"  # Default value
PROGRESS_PIPE=""
PROGRESS_MONITOR_PID=""
PROGRESS_STATE_FILE="/tmp/rsync_progress_$$.state"

# Load saved user preferences (this may override the default)
load_user_preferences

# Debug logging function
debug_log() {
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1"
    fi
}

# File structure preference
FILE_STRUCTURE="keep"  # "keep" or "easy"

# Recovery preset
RECOVERY_PRESET="balanced"  # Default preset

# Deferred files tracking
DEFERRED_FILES=""
DEFERRED_COUNT=0
DEFERRED_SIZE=0

# Customer info globals
TICKET_NUMBER=""
CUSTOMER_NAME=""

# Latest settings file path for updates
LATEST_SETTINGS_FILE=""

# Function to save recovery settings
save_recovery_settings() {
    local recovery_dir="$RECOVERY_DIR"
    mkdir -p "$recovery_dir"
    
    # Create unique filename based on timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local settings_file="$recovery_dir/recovery_$timestamp"
    
    # Get portable identifiers for source
    local source_label=""
    local source_device=""
    local source_size=""
    local source_fstype=""
    local source_uuid=""
    local source_model=""
    
    if [[ "$1" =~ ^/dev/ ]]; then
        source_device="$1"
        source_label=$(lsblk -no LABEL "$1" 2>/dev/null | head -1)
        source_size=$(lsblk -no SIZE "$1" 2>/dev/null | head -1)
        source_fstype=$(lsblk -no FSTYPE "$1" 2>/dev/null | head -1)
        source_uuid=$(lsblk -no UUID "$1" 2>/dev/null | head -1)
        source_model=$(lsblk -no MODEL "$1" 2>/dev/null | head -1 | sed 's/ *$//')
    else
        # Try to find device from mount point
        source_device=$(df --output=source "$1" 2>/dev/null | tail -1)
        if [[ "$source_device" =~ ^/dev/ ]]; then
            source_label=$(lsblk -no LABEL "$source_device" 2>/dev/null | head -1)
            source_size=$(lsblk -no SIZE "$source_device" 2>/dev/null | head -1)
            source_fstype=$(lsblk -no FSTYPE "$source_device" 2>/dev/null | head -1)
            source_uuid=$(lsblk -no UUID "$source_device" 2>/dev/null | head -1)
            source_model=$(lsblk -no MODEL "$source_device" 2>/dev/null | head -1 | sed 's/ *$//')
        else
            source_label=$(basename "$1")
        fi
    fi
    
    # Get portable identifiers for destination
    local dest_label=""
    local dest_device=""
    local dest_size=""
    local dest_fstype=""
    local dest_uuid=""
    
    if [[ "$2" =~ ^/dev/ ]]; then
        dest_device="$2"
        dest_label=$(lsblk -no LABEL "$2" 2>/dev/null | head -1)
        dest_size=$(lsblk -no SIZE "$2" 2>/dev/null | head -1)
        dest_fstype=$(lsblk -no FSTYPE "$2" 2>/dev/null | head -1)
        dest_uuid=$(lsblk -no UUID "$2" 2>/dev/null | head -1)
    else
        # Try to find device from mount point
        dest_device=$(df --output=source "$2" 2>/dev/null | tail -1)
        if [[ "$dest_device" =~ ^/dev/ ]]; then
            dest_label=$(lsblk -no LABEL "$dest_device" 2>/dev/null | head -1)
            dest_size=$(lsblk -no SIZE "$dest_device" 2>/dev/null | head -1)
            dest_fstype=$(lsblk -no FSTYPE "$dest_device" 2>/dev/null | head -1)
            dest_uuid=$(lsblk -no UUID "$dest_device" 2>/dev/null | head -1)
        else
            # For destination, use the parent directory name if it's a subfolder
            dest_label=$(basename "$(dirname "$2")")
        fi
    fi
    
    cat > "$settings_file" << EOF
# Portable identifiers (for cross-workstation compatibility)
SOURCE_LABEL="${source_label:-unknown}"
SOURCE_DEVICE="${source_device:-unknown}"
SOURCE_SIZE="${source_size:-unknown}"
SOURCE_FSTYPE="${source_fstype:-unknown}"
SOURCE_UUID="${source_uuid:-unknown}"
SOURCE_MODEL="${source_model:-unknown}"
DEST_LABEL="${dest_label:-unknown}"
DEST_DEVICE="${dest_device:-unknown}"
DEST_SIZE="${dest_size:-unknown}"
DEST_FSTYPE="${dest_fstype:-unknown}"
DEST_UUID="${dest_uuid:-unknown}"

# Local paths (workstation-specific)
SOURCE_PATH="$1"
DEST_PATH="$2"
SKIP_TEMP="$3"
MODE_CHOICE="$4"
INCLUDE_PROGRAMS="$5"
INCLUDE_STEAM="$6"
INCLUDE_EXCLUDED="$7"
FILE_TYPE_FILTER="${8:-no}"
FILTER_PICTURES="${9:-no}"
FILTER_VIDEOS="${10:-no}"
FILTER_DOCUMENTS="${11:-no}"
FILTER_AUDIO="${12:-no}"
USE_MANIFEST="${13:-no}"
FILE_STRUCTURE="${14:-keep}"
RECOVERY_PRESET="${15:-balanced}"
FINAL_DEST_PATH="${16:-$2}"
SESSION_TIMESTAMP="${17:-$SESSION_TIMESTAMP}"
USE_PRIORITY="${18:-yes}"
TIMESTAMP="$(date)"
TICKET_NUMBER="$TICKET_NUMBER"
CUSTOMER_NAME="$CUSTOMER_NAME"
COMPUTER_MODEL="$COMPUTER_MODEL"
EOF
    chmod 600 "$settings_file"
    
    # Also save as "latest" for quick access
    cp "$settings_file" "$recovery_dir/latest"
    
    # Keep only last 10 recovery files
    ls -t "$recovery_dir"/recovery_* 2>/dev/null | tail -n +11 | xargs -r rm
    
    # Export the settings file path for later update
    LATEST_SETTINGS_FILE="$settings_file"
}

# Function to load recovery settings
load_recovery_settings() {
    local settings_file="$1"
    if [ -f "$settings_file" ]; then
        source "$settings_file"
        return 0
    fi
    return 1
}

# Function to handle Ctrl+C gracefully
handle_interrupt() {
    echo ""
    echo -e "${YELLOW}Transfer interrupted by user${NC}"
    debug_log "handle_interrupt called"
    
    # Update recovery settings with current working paths if different
    if [ "$TRANSFER_IN_PROGRESS" = true ] && [ -n "$LATEST_SETTINGS_FILE" ]; then
        # Update the settings file with actual current paths
        sed -i "s|^SOURCE_PATH=.*|SOURCE_PATH=\"$CURRENT_SOURCE\"|" "$LATEST_SETTINGS_FILE"
        sed -i "s|^DEST_PATH=.*|DEST_PATH=\"$CURRENT_DEST\"|" "$LATEST_SETTINGS_FILE"
        sed -i "s|^FINAL_DEST_PATH=.*|FINAL_DEST_PATH=\"$CURRENT_DEST\"|" "$LATEST_SETTINGS_FILE"
        
        # Also update the latest file
        local recovery_dir="$RECOVERY_DIR"
        cp "$LATEST_SETTINGS_FILE" "$recovery_dir/latest"
    fi
    
    # Save manifest to destination but keep on desktop for resume
    if [ "$TRANSFER_IN_PROGRESS" = true ]; then
        if [ "$USE_MANIFEST" = "yes" ] && [ -n "$MANIFEST_FILE" ] && [ -f "$MANIFEST_FILE" ]; then
            # Try to save a copy to destination
            local source_name=$(basename "$CURRENT_SOURCE")
            source_name="${source_name//[^a-zA-Z0-9-_]/_}"
            local dest_manifest="$CURRENT_DEST/recovery_manifest_${source_name}_${SESSION_TIMESTAMP}.txt"
            
            echo -e "${YELLOW}Saving manifest copy to destination...${NC}"
            if cp "$MANIFEST_FILE" "$dest_manifest" 2>/dev/null; then
                echo "Manifest backed up to destination with $(wc -l < "$MANIFEST_FILE") files tracked"
            else
                echo -e "${RED}Could not save manifest to destination${NC}"
            fi
            
            echo -e "${YELLOW}Manifest preserved on desktop for resume: $MANIFEST_FILE${NC}"
            echo "Contains $(wc -l < "$MANIFEST_FILE") files already copied"
        fi
        
        echo -e "${GREEN}Progress has been saved. You can resume by running:${NC}"
        echo "  $0 --resume       # Normal resume (checks all files)"
        echo "  $0 --fast-resume  # Fast resume (skips already-copied files)"
        echo ""
        echo "Recovery settings stored in: $RECOVERY_DIR/"
        echo "Or run without flags to start a new transfer."
    fi
    
    # Cleanup progress monitor if running
    cleanup_progress_monitor
    
    exit 130
}

# Set up the interrupt handler
trap handle_interrupt SIGINT

# Function to display usage
usage() {
    echo -e "${GREEN}Rsync Recovery Script${NC}"
    echo "This script helps recover interrupted file transfers and perform new copies"
    echo ""
    echo "Usage options:"
    echo "1. Run without arguments for interactive mode"
    echo "2. Run with --resume to continue last recovery"
    echo "3. Run with --fast-resume for manifest-based resume (much faster)"
    echo ""
    echo "Examples:"
    echo "  $0              # Start new recovery"
    echo "  $0 --resume     # Resume last recovery with saved settings"
    echo "  $0 --fast-resume # Resume using manifest (skips already-copied files)"
    echo ""
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

# Function to check if a file should be deferred
should_defer_file() {
    local file="$1"
    local size="$2"
    local preset="${3:-balanced}"
    local ext="${file##*.}"
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local parent_dir=$(basename "$(dirname "$file")")
    
    # Don't defer small files (under 100MB)
    [ $size -lt 104857600 ] && return 1
    
    # Load preset configuration if available
    if command -v get_preset_config &> /dev/null; then
        eval "$(get_preset_config "$preset")"
        
        # Never defer critical files for this preset
        for critical_pattern in "${CRITICAL_FILES[@]}"; do
            [[ "$file" =~ $critical_pattern ]] && return 1
        done
        
        # Never defer priority extensions for this preset
        for priority_ext in "${PRIORITY_EXTENSIONS[@]}"; do
            [[ "$ext_lower" == "$priority_ext" ]] && return 1
        done
    fi
    
    # Check for obviously misplaced large files
    case "$parent_dir" in
        Pictures|Photos|Images)
            # Large non-image files in photo folders
            [[ "$ext_lower" =~ ^(iso|vhd|vmdk|vhdx|exe|zip|rar|7z)$ ]] && return 0
            ;;
        Documents)
            # Huge media/VM files in documents
            [[ "$ext_lower" =~ ^(iso|vhd|vmdk|vhdx|mkv|avi|mp4)$ ]] && [ $size -gt 1073741824 ] && return 0
            ;;
        Desktop)
            # Very large files on desktop (over 2GB)
            [[ "$ext_lower" =~ ^(iso|vhd|vmdk|vhdx)$ ]] && [ $size -gt 2147483648 ] && return 0
            ;;
    esac
    
    # Defer large files that are clearly not priority
    if [[ "$ext_lower" =~ ^(iso|vhd|vmdk|vhdx|ova|ovf)$ ]] && [ $size -gt 524288000 ]; then
        return 0  # Defer 500MB+ VM/ISO files
    fi
    
    # Defer very large archives (over 1GB)
    if [[ "$ext_lower" =~ ^(zip|rar|7z|tar|gz|bz2)$ ]] && [ $size -gt 1073741824 ]; then
        return 0
    fi
    
    return 1  # Don't defer
}

# Function to add file to deferred list
defer_file() {
    local file="$1"
    local size="$2"
    local preset="$3"
    
    # Initialize deferred file if needed
    if [ -z "$DEFERRED_FILES" ]; then
        DEFERRED_FILES="$RECOVERY_DIR/deferred_$(date +%Y%m%d_%H%M%S).txt"
        mkdir -p "$(dirname "$DEFERRED_FILES")"
    fi
    
    # Add to deferred list with size and priority score
    local priority_score=100  # Default score
    local ext="${file##*.}"
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    
    # Adjust score based on preset
    if command -v get_preset_config &> /dev/null; then
        eval "$(get_preset_config "$preset")"
        
        # Higher score for secondary priority extensions
        for sec_ext in "${SECONDARY_EXTENSIONS[@]}"; do
            [[ "$ext_lower" == "$sec_ext" ]] && priority_score=200 && break
        done
    fi
    
    # Format: size:priority:path
    echo "$size:$priority_score:$file" >> "$DEFERRED_FILES"
    
    # Update counters
    DEFERRED_COUNT=$((DEFERRED_COUNT + 1))
    DEFERRED_SIZE=$((DEFERRED_SIZE + size))
    
    # Show progress
    local size_mb=$((size / 1048576))
    echo -e "${YELLOW}Deferring large file (${size_mb}MB): $(basename "$file")${NC}"
}

# Function to process deferred files
process_deferred_files() {
    if [ -z "$DEFERRED_FILES" ] || [ ! -f "$DEFERRED_FILES" ] || [ $DEFERRED_COUNT -eq 0 ]; then
        return 0
    fi
    
    local dest="$1"
    local source="$2"
    
    # Convert size to human readable
    local size_gb=$(echo "scale=2; $DEFERRED_SIZE / 1073741824" | bc)
    
    echo ""
    echo "========================================="
    echo -e "${YELLOW}Deferred Files Summary${NC}"
    echo "========================================="
    echo "Found $DEFERRED_COUNT large files (${size_gb}GB total)"
    echo ""
    echo -n "Copy these files now? [Y/n] (auto-continues in 10 seconds): "
    
    # Play alert sound
    play_completion_sound
    
    # Read with timeout
    local response
    if read -t 10 -r response; then
        if [[ "$response" =~ ^[Nn]$ ]]; then
            echo ""
            echo "Skipping deferred files. List saved to: $DEFERRED_FILES"
            return 0
        fi
    else
        echo ""
        echo "No response - auto-continuing with deferred files..."
    fi
    
    echo ""
    echo -e "${GREEN}Processing deferred files in optimized order...${NC}"
    echo "Priority: High-value files first, then by size (smallest to largest)"
    echo ""
    
    # Sort by priority (descending) then by size (ascending)
    # This gets priority files first, and within each priority, smallest files first
    sort -t: -k2,2nr -k1,1n "$DEFERRED_FILES" | while IFS=: read -r size priority file; do
        if [ -f "$file" ]; then
            local rel_path="${file#$source/}"
            local dest_file="$dest/$rel_path"
            local dest_dir=$(dirname "$dest_file")
            
            # Create destination directory
            mkdir -p "$dest_dir"
            
            # Show what we're copying
            local size_mb=$((size / 1048576))
            echo -e "${GREEN}Copying deferred file (${size_mb}MB): $rel_path${NC}"
            
            # Copy with manifest logging
            local rsync_cmd="rsync -avh --progress --partial --append-verify '$file' '$dest_file'"
            execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
        fi
    done
    
    echo ""
    echo -e "${GREEN}Deferred files processing complete!${NC}"
    
    # Clean up deferred list
    rm -f "$DEFERRED_FILES"
}

# Function to setup progress monitoring
setup_progress_monitor() {
    # Deprecated - using disk-based progress_monitor.sh instead
    # This function is kept for compatibility but does nothing
    return 0
}

# Function to cleanup progress monitoring
cleanup_progress_monitor() {
    # Progress pipe cleanup removed - using disk-based monitoring now
    
    # Kill monitor process if still running
    if [ -n "$PROGRESS_MONITOR_PID" ]; then
        kill $PROGRESS_MONITOR_PID 2>/dev/null
    fi
    
    # Clean up progress state file
    if [ -n "$PROGRESS_STATE_FILE" ]; then
        rm -f "$PROGRESS_STATE_FILE" 2>/dev/null
    fi
}

# Progress monitoring is now handled via disk usage monitoring
# See progress_monitor.sh for implementation

# Function to write progress state
write_progress_state() {
    local state="$1"
    local transferred_size="${2:-0}"
    local total_size="${3:-0}"
    
    if [ -n "$PROGRESS_STATE_FILE" ]; then
        cat > "$PROGRESS_STATE_FILE" <<EOF
STATE=$state
TRANSFERRED=$transferred_size
TOTAL=$total_size
PID=$$
TIMESTAMP=$(date +%s)
EOF
    fi
}

# Function to execute rsync with deferral checking
execute_rsync_with_deferral() {
    local rsync_cmd="$1"
    local dest_base="$2"
    local error_log="$3"
    local source_path="$4"
    local preset="${5:-balanced}"
    
    # For directory copies, we need to handle deferral differently
    # Create a temporary exclude file for deferred items
    local defer_excludes=""
    if [ -n "$source_path" ] && [ -d "$source_path" ]; then
        defer_excludes="$RECOVERY_DIR/defer_excludes_$(date +%Y%m%d_%H%M%S).txt"
        mkdir -p "$RECOVERY_DIR"
        
        # Check each file in the source directory for deferral
        # Use process substitution to avoid subshell
        while IFS= read -r -d '' file; do
            local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
            if should_defer_file "$file" "$size" "$preset"; then
                defer_file "$file" "$size" "$preset"
                # Add to exclude list (relative path from source)
                local rel_path="${file#$source_path/}"
                echo "$rel_path" >> "$defer_excludes"
            fi
        done < <(find "$source_path" -type f -print0 2>/dev/null)
        
        # Add exclude file to rsync command if any deferrals
        if [ -f "$defer_excludes" ] && [ -s "$defer_excludes" ]; then
            echo -e "${YELLOW}Deferring $(wc -l < "$defer_excludes") large files for later processing${NC}"
            rsync_cmd="${rsync_cmd/rsync /rsync --exclude-from='$defer_excludes' }"
        fi
    fi
    
    # Execute the rsync command
    execute_rsync_with_manifest "$rsync_cmd" "$dest_base" "$error_log" "$source_path" "$preset"
    
    # Clean up exclude file
    [ -f "$defer_excludes" ] && rm -f "$defer_excludes"
}

# Function to execute rsync with manifest logging if enabled
execute_rsync_with_manifest() {
    local rsync_cmd="$1"
    local dest_base="$2"
    local error_log="$3"
    local source_path="${4:-}"
    local preset="${5:-balanced}"
    
    # Variables to track sizes
    local total_size=0
    local transferred_size=0
    
    # Initialize or update manifest header
    if [ "$USE_MANIFEST" = "yes" ] && [ -n "$MANIFEST_FILE" ]; then
        # If this is a new manifest, write header
        if [ ! -f "$MANIFEST_FILE" ] || [ ! -s "$MANIFEST_FILE" ]; then
            cat > "$MANIFEST_FILE" <<EOF
# RSYNC_RECOVERY_MANIFEST_V2
# SESSION_START: $(date +%Y-%m-%d_%H:%M:%S)
# TOTAL_SIZE: 0
# TRANSFERRED_SIZE: 0
EOF
        else
            # Read existing sizes from manifest
            if grep -q "^# TOTAL_SIZE:" "$MANIFEST_FILE" 2>/dev/null; then
                total_size=$(grep "^# TOTAL_SIZE:" "$MANIFEST_FILE" | cut -d: -f2 | tr -d ' ')
                transferred_size=$(grep "^# TRANSFERRED_SIZE:" "$MANIFEST_FILE" | cut -d: -f2 | tr -d ' ')
            fi
        fi
        
        # Write initial RUNNING state with existing sizes
        write_progress_state "RUNNING" "$transferred_size" "$total_size"
        
        # Create temp file for size tracking
        local size_tracker=$(mktemp /tmp/rsync_sizes_$$.XXXXXX)
        echo "TOTAL:$total_size" > "$size_tracker"
        echo "TRANSFERRED:$transferred_size" >> "$size_tracker"
        
        # Run rsync with custom output format to get sizes
        # Using --out-format to get filename and size
        eval "$rsync_cmd --out-format='%n|%l' --itemize-changes" 2>&1 | while IFS= read -r line; do
            # Always echo the line if it's not our custom format
            if [[ ! "$line" =~ ^[^|]+\|[0-9]+$ ]]; then
                echo "$line"
            fi
            
            # Parse custom format: filename|size
            if [[ "$line" =~ ^(.+)\|([0-9]+)$ ]]; then
                local file_path="${BASH_REMATCH[1]}"
                local file_size="${BASH_REMATCH[2]}"
                
                # Update sizes
                total_size=$((total_size + file_size))
                transferred_size=$((transferred_size + file_size))
                
                # Write to manifest with size
                echo "$dest_base/$file_path|$file_size" >> "$MANIFEST_FILE"
                
                # Update size tracker
                echo "TOTAL:$total_size" > "$size_tracker"
                echo "TRANSFERRED:$transferred_size" >> "$size_tracker"
                
                # Update progress state
                write_progress_state "RUNNING" "$transferred_size" "$total_size"
            fi
        done | tee -a >(grep -E "failed:|error:|cannot|permission denied" >> "$error_log")
        
        # Read final sizes
        if [ -f "$size_tracker" ]; then
            total_size=$(grep "^TOTAL:" "$size_tracker" | cut -d: -f2)
            transferred_size=$(grep "^TRANSFERRED:" "$size_tracker" | cut -d: -f2)
            rm -f "$size_tracker"
        fi
        
        # Update manifest header with final sizes
        sed -i "s/^# TOTAL_SIZE:.*$/# TOTAL_SIZE: $total_size/" "$MANIFEST_FILE"
        sed -i "s/^# TRANSFERRED_SIZE:.*$/# TRANSFERRED_SIZE: $transferred_size/" "$MANIFEST_FILE"
        
    else
        # Normal rsync without manifest logging
        write_progress_state "RUNNING" "0" "0"
        eval "$rsync_cmd" 2>&1 | tee -a >(grep -E "failed:|error:|cannot|permission denied" >> "$error_log")
    fi
    
    # Write completion state
    write_progress_state "COMPLETED" "$transferred_size" "$total_size"
}

# Function to build exclude list from manifest
build_manifest_excludes() {
    local manifest="$1"
    local dest_path="$2"
    
    # Create a temporary exclude file
    local exclude_file=$(mktemp /tmp/rsync_manifest_excludes.XXXXXX)
    local count=0
    
    if [ -f "$manifest" ] && [ -s "$manifest" ]; then
        # Count non-comment lines
        local file_count=$(grep -v "^#" "$manifest" | wc -l)
        echo -e "${GREEN}Found manifest with $file_count completed files${NC}" >&2
        echo "Building exclude file from manifest..." >&2
        
        # Convert absolute paths in manifest to relative paths for rsync
        while IFS= read -r manifest_line; do
            # Skip comments
            [[ "$manifest_line" =~ ^# ]] && continue
            
            # Extract path (handle both old format and new format with size)
            local completed_file
            if [[ "$manifest_line" =~ ^([^|]+)\|[0-9]+$ ]]; then
                # New format: path|size
                completed_file="${BASH_REMATCH[1]}"
            else
                # Old format: just path
                completed_file="$manifest_line"
            fi
            
            if [[ "$completed_file" == "$dest_path/"* ]]; then
                local relative_path="${completed_file#$dest_path/}"
                echo "$relative_path" >> "$exclude_file"
                ((count++))
            fi
        done < "$manifest"
        
        echo -e "${GREEN}Created exclude file with $count entries${NC}" >&2
    fi
    
    # Return the exclude file path
    echo "$exclude_file"
}

# Function to copy folder metadata files (desktop.ini, .DS_Store) for folders we've backed up
copy_folder_metadata_files() {
    local source="$1"
    local dest="$2"
    
    echo ""
    echo -e "${YELLOW}Copying folder metadata files (desktop.ini, .DS_Store)...${NC}"
    
    local metadata_count=0
    local temp_metadata_list=$(mktemp)
    
    # Find all directories in destination that contain files (not empty)
    find "$dest" -type d -exec sh -c '[ -n "$(ls -A "$1" 2>/dev/null)" ]' _ {} \; -print | while IFS= read -r dest_dir; do
        # Get relative path from destination root
        local rel_path="${dest_dir#$dest}"
        rel_path="${rel_path#/}"  # Remove leading slash if present
        
        # Skip if it's the root directory
        [ -z "$rel_path" ] && continue
        
        # Construct source path
        local source_dir="$source/$rel_path"
        
        # Check if source directory exists
        if [ -d "$source_dir" ]; then
            # Check for desktop.ini (Windows)
            if [ -f "$source_dir/desktop.ini" ] && [ ! -f "$dest_dir/desktop.ini" ]; then
                if cp -p "$source_dir/desktop.ini" "$dest_dir/" 2>/dev/null; then
                    ((metadata_count++))
                    echo "$dest_dir/desktop.ini" >> "$temp_metadata_list"
                fi
            fi
            
            # Check for .DS_Store (Mac)
            if [ -f "$source_dir/.DS_Store" ] && [ ! -f "$dest_dir/.DS_Store" ]; then
                if cp -p "$source_dir/.DS_Store" "$dest_dir/" 2>/dev/null; then
                    ((metadata_count++))
                    echo "$dest_dir/.DS_Store" >> "$temp_metadata_list"
                fi
            fi
        fi
    done
    
    if [ $metadata_count -gt 0 ]; then
        echo -e "${GREEN}Copied $metadata_count folder metadata files${NC}"
        
        # Add to manifest if using manifest mode
        if [ "$USE_MANIFEST" = "yes" ] && [ -n "$MANIFEST_FILE" ] && [ -f "$MANIFEST_FILE" ]; then
            cat "$temp_metadata_list" >> "$MANIFEST_FILE"
        fi
    else
        echo "No additional folder metadata files found to copy"
    fi
    
    rm -f "$temp_metadata_list"
}

# Function to perform rsync with optimal settings
perform_rsync() {
    local source="$1"
    local dest="$2"
    local skip_temp="${3:-yes}"  # Default to skipping temp files
    local include_programs="${4:-no}"
    local include_steam="${5:-no}"
    local include_excluded="${6:-no}"
    local file_type_filter="${7:-no}"
    local filter_pictures="${8:-no}"
    local filter_videos="${9:-no}"
    local filter_documents="${10:-no}"
    local filter_audio="${11:-no}"
    local file_structure="${12:-keep}"  # Default to keeping original structure
    local recovery_preset="${13:-balanced}"  # Default preset
    local use_priority="${14:-yes}"  # Default to using priority
    
    # Remove trailing slashes for consistency
    source="${source%/}"
    dest="${dest%/}"
    
    # Initialize manifest if using fast resume
    local manifest_excludes=""
    local temp_manifest=""
    
    # Create unique manifest name based on source
    local source_name=$(basename "$source")
    # Sanitize source name for filename (replace problematic chars)
    source_name="${source_name//[^a-zA-Z0-9-_]/_}"
    
    # Ensure we have a session timestamp
    # This handles cases where perform_rsync is called directly (e.g., resume mode)
    # or recursively without going through interactive_mode first
    if [ -z "$SESSION_TIMESTAMP" ]; then
        SESSION_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    fi
    
    local dest_manifest="$dest/recovery_manifest_${source_name}_${SESSION_TIMESTAMP}.txt"
    
    if [ "$USE_MANIFEST" = "yes" ]; then
        # Use desktop for manifest during recovery - visible to user and avoids destination writes
        local desktop_path="$HOME/Desktop"
        if [ ! -d "$desktop_path" ]; then
            # Fallback to user home if no Desktop folder
            desktop_path="$HOME"
        fi
        
        # Create temp manifest with source name and consistent timestamp
        temp_manifest="$desktop_path/rsync_recovery_manifest_${source_name}_${SESSION_TIMESTAMP}.txt"
        MANIFEST_FILE="$temp_manifest"
        
        echo -e "${GREEN}Using manifest mode for fast resume${NC}"
        echo "Temporary manifest: $temp_manifest"
        echo -e "${YELLOW}Note: Manifest saved on desktop for visibility${NC}"
        echo "Final destination: $dest_manifest"
        
        # Check for existing manifest - first at destination, then on desktop
        local found_manifest=false
        
        # Check destination first for manifests matching this source
        local dest_manifests=("$dest"/recovery_manifest_${source_name}_*.txt)
        if [ -f "${dest_manifests[0]}" ]; then
            # Find the most recent one
            local latest_dest_manifest=$(ls -t "$dest"/recovery_manifest_${source_name}_*.txt 2>/dev/null | head -1)
            if [ -f "$latest_dest_manifest" ]; then
                echo "Found existing manifest at destination, copying to desktop for resume..."
                echo "Using: $(basename "$latest_dest_manifest")"
                cp "$latest_dest_manifest" "$temp_manifest"
                found_manifest=true
            fi
        fi
        
        if [ "$found_manifest" = false ]; then
            # Check desktop for interrupted recovery manifests
            local desktop_manifests=("$desktop_path"/rsync_recovery_manifest_${source_name}_*.txt)
            if [ -f "${desktop_manifests[0]}" ]; then
                # Find the most recent one
                local latest_manifest=$(ls -t "$desktop_path"/rsync_recovery_manifest_${source_name}_*.txt 2>/dev/null | head -1)
                if [ -f "$latest_manifest" ]; then
                    echo "Found existing manifest on desktop from interrupted recovery..."
                    echo "Using: $(basename "$latest_manifest")"
                    # Copy to our new temp location
                    cp "$latest_manifest" "$temp_manifest"
                    found_manifest=true
                fi
            fi
        fi
        
        if [ "$found_manifest" = true ]; then
            echo "Loaded $(wc -l < "$temp_manifest") already-copied files"
            manifest_excludes=$(build_manifest_excludes "$temp_manifest" "$dest")
        else
            echo "Starting new manifest"
        fi
    fi
    
    echo -e "${YELLOW}Starting rsync operation...${NC}"
    echo "Source: $source"
    echo "Destination: $dest"
    echo "Skip temporary files: $skip_temp"
    if [ "$USE_MANIFEST" = "yes" ]; then
        echo "Fast resume: ENABLED"
    fi
    echo ""
    echo -e "${GREEN}Press Ctrl+C (just once!) at any time to safely pause the transfer${NC}"
    
    # Set global variables for interrupt handler and verification
    TRANSFER_IN_PROGRESS=true
    CURRENT_SOURCE="$source"
    CURRENT_DEST="$dest"  # This is the actual final destination
    
    # Setup progress monitoring if enabled
    if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
        echo "Setting up progress monitor window..."
        # setup_progress_monitor - removed, using disk-based monitor instead
        if [ $? -eq 0 ]; then
            echo "Progress monitor started"
        else
            echo "Progress monitor setup failed, continuing without monitoring"
        fi
        sleep 1
    fi
    
    # Check if this is a user folder (contains typical user directories)
    local is_user_folder=false
    if [[ -d "$source/Desktop" || -d "$source/Documents" || -d "$source/Pictures" || -d "$source/AppData" || -d "$source/Library" || -d "$source/My Documents" ]]; then
        is_user_folder=true
        if [ "$use_priority" = "yes" ]; then
            echo "Detected user folder - will copy high-priority folders first"
        else
            echo "Detected user folder - performing direct copy without prioritization"
        fi
    fi
    
    echo ""
    
    # Build filter file for all includes/excludes
    local filter_file=$(mktemp /tmp/rsync_filters.XXXXXX)
    local exclude_opts=""
    local include_opts=""
    
    # Track the filter file for cleanup
    trap "rm -f '$filter_file'" EXIT
    
    # Add manifest excludes if in fast resume mode
    if [ "$USE_MANIFEST" = "yes" ] && [ -n "$manifest_excludes" ] && [ -f "$manifest_excludes" ]; then
        # manifest_excludes is now a file path, convert to filter format
        while IFS= read -r line; do
            echo "- $line" >> "$filter_file"
        done < "$manifest_excludes"
        rm -f "$manifest_excludes"  # Clean up the temporary manifest exclude file
    fi
    
    if [ "$skip_temp" = "yes" ]; then
        # Add temporary file patterns to filter file (- means exclude)
        cat >> "$filter_file" << 'EOF'
- Temporary Internet Files/
- */Cache/*
- */cache/*
- */Caches/*
- */tmp/*
- */temp/*
- */Temp/*
- *.tmp
- ~*
- *~
- Thumbs.db
- */Google/Chrome/User Data/*/Cache*
- */Mozilla/Firefox/Profiles/*/cache*
- */Microsoft/Edge/User Data/*/Cache*
- pagefile.sys
- hiberfil.sys
- swapfile.sys
- $RECYCLE.BIN/
- System Volume Information/
- */Windows/Temp/*
- */AppData/Local/Temp/*
- */AppData/Local/Microsoft/Windows/WebCache/*
- */AppData/Local/Microsoft/Windows/INetCache/*
- */AppData/Local/Microsoft/OneDrive/*
- */AppData/Local/Dropbox/bin/*
- */AppData/Local/Google/Drive/*
- .Spotlight-V100/
- .Trashes/
- .fseventsd/
- */Library/Caches/*
- */Library/Logs/*
- */Library/Application Support/*/Cache*
- node_modules/
- .git/
- __pycache__/
- *.pyc
- */Spotify/Storage/*
- */Steam/steamapps/downloading/*
- *.vmdk
- *.vhd
- *.vhdx
- *.vdi
- *.qcow2
- *.iso
- */Downloads/*.exe
- */Downloads/*.msi
- */temp/*.exe
- */temp/*.msi
- *.dmg
- *.pkg
- *.deb
- *.rpm
- *.appx
- *.msix
- *.dmp
- */Minidump/*
- */.npm/*
- */.cache/*
- */pip-cache/*
- */.m2/repository/*
- */Docker/containers/*
- */Docker/images/*
- */Adobe/Common/Media Cache*
- */Final Cut Pro/Render Files/*
- */DaVinci Resolve/Cache/*
EOF
        
        echo -e "${YELLOW}Excluding temporary files and caches${NC}"
    fi
    
    # Build include options for file-type filtering
    if [ "$file_type_filter" = "yes" ]; then
        echo -e "${YELLOW}Preparing file-type filters (this is quick)...${NC}"
        
        # Always include directories to maintain structure
        echo "+ */" >> "$filter_file"
        
        # Add picture extensions
        if [ "$filter_pictures" = "yes" ]; then
            for ext in $PICTURE_EXTS; do
                echo "+ *.$ext" >> "$filter_file"
                echo "+ *.${ext^^}" >> "$filter_file"
            done
            echo "  Including picture files"
        fi
        
        # Add video extensions
        if [ "$filter_videos" = "yes" ]; then
            for ext in $VIDEO_EXTS; do
                echo "+ *.$ext" >> "$filter_file"
                echo "+ *.${ext^^}" >> "$filter_file"
            done
            echo "  Including video files"
        fi
        
        # Add document extensions
        if [ "$filter_documents" = "yes" ]; then
            for ext in $DOC_EXTS; do
                echo "+ *.$ext" >> "$filter_file"
                echo "+ *.${ext^^}" >> "$filter_file"
            done
            echo "  Including document files"
        fi
        
        # Add audio/music extensions
        if [ "$filter_audio" = "yes" ]; then
            for ext in $AUDIO_EXTS; do
                echo "+ *.$ext" >> "$filter_file"
                echo "+ *.${ext^^}" >> "$filter_file"
            done
            echo "  Including music files"
        fi
        
        # SPECIAL HANDLING: Photo management packages
        # These directories contain databases and other critical files
        # that don't match our extension filters but are essential
        echo "  Including photo library packages (all contents):"
        
        # Photos/iPhoto libraries
        cat >> "$filter_file" << 'EOF'
+ *.photoslibrary/***
+ *.photolibrary/***
+ *.aplibrary/***
EOF
        echo "    - Photos, iPhoto, and Aperture libraries"
        
        # Lightroom catalogs and their associated folders
        cat >> "$filter_file" << 'EOF'
+ *.lrcat
+ *.lrdata/***
+ *Lightroom*/***
EOF
        echo "    - Lightroom catalogs and data"
        
        # Photo Booth libraries
        cat >> "$filter_file" << 'EOF'
+ Photo Booth Library/***
+ Pictures/Photo Booth/***
EOF
        echo "    - Photo Booth libraries"
        
        # Other photo management tools
        cat >> "$filter_file" << 'EOF'
+ *.c1catalog
+ *.coc1catalog/***
+ *.darktable/***
+ *.lmnr
+ *.luminar
+ *Luminar*/***
+ *.on1
+ *.on1pho
+ *ON1*/***
+ *.dop
+ *.dopdata
+ *DxO*/***
EOF
        echo "    - Other photo management tools (Capture One, Darktable, Luminar, ON1, DxO)"
        
        # Exclude everything else
        echo "- *" >> "$filter_file"
        
        echo ""
        echo -e "${RED}⚠️  File-type filtering is now active!${NC}"
        echo -e "${RED}   The initial file scan may take 10+ minutes...${NC}"
        echo -e "${RED}   CPU usage will be high during scanning phase.${NC}"
        echo ""
    fi
    
    # Set rsync filter options if we have any filters
    if [ -s "$filter_file" ]; then
        exclude_opts="--filter='. $filter_file'"
        include_opts=""  # All filters are now in the filter file
    else
        exclude_opts=""
        include_opts=""
    fi
    
    # Add prune-empty-dirs when using file-type filtering
    local prune_opts=""
    if [ "$file_type_filter" = "yes" ]; then
        prune_opts="-m"  # --prune-empty-dirs
    fi
    
    # rsync options:
    # -a: archive mode (preserves permissions, times, etc.)
    # -v: verbose
    # -h: human-readable sizes
    # --progress: show progress
    # --partial: keep partially transferred files
    # --append-verify: resume interrupted transfers (safer than --append)
    # --stats: show transfer statistics
    
    # Create temporary files for logging
    local error_log=$(mktemp)
    local skipped_log=$(mktemp)
    local steam_dirs=$(mktemp)
    local symlinks_log=$(mktemp)
    
    # If priority is disabled, do a direct copy
    if [ "$use_priority" = "no" ]; then
        echo -e "${YELLOW}Starting direct copy (no prioritization)...${NC}"
        # Single rsync command for entire source
        # IMPORTANT: When using file filtering, excludes must come BEFORE includes
        local rsync_cmd="rsync -avh --progress --partial --append-verify $prune_opts $exclude_opts $include_opts '$source/' '$dest/'"
        execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log" "$source" "$recovery_preset"
        EXIT_CODE=$?  # Capture exit code explicitly
    # If this is a user folder, copy in priority order
    elif [ "$is_user_folder" = true ]; then
        # Priority folders (most important first) - adjust based on preset
        local priority_folders
        if [ "$FILE_TYPE_FILTER" = "yes" ] && [ "$FILTER_PICTURES" = "yes" ] && [ "$FILTER_VIDEOS" = "yes" ] && [ "$FILTER_DOCUMENTS" = "no" ]; then
            # Photos & Videos Only preset - prioritize media folders
            priority_folders=("Pictures" "Desktop" "Videos" "Documents" "Downloads" "Music" "Public" "Favorites" "Contacts" "Saved Games")
        elif [ "$recovery_preset" = "photographer_raw" ] || [ "$recovery_preset" = "photographer_export" ]; then
            # Photographer presets - Pictures first
            priority_folders=("Pictures" "Desktop" "Documents" "Videos" "Downloads" "Music" "Public" "Favorites" "Contacts" "Saved Games")
        elif [ "$recovery_preset" = "business" ]; then
            # Business preset - Documents first
            priority_folders=("Documents" "Desktop" "Downloads" "Pictures" "Videos" "Music" "Public" "Favorites" "Contacts" "Saved Games")
        else
            # Default priority order
            priority_folders=("Pictures" "Documents" "Desktop" "Videos" "Music" "Downloads" "Public" "Favorites" "Contacts" "Saved Games")
        fi
        local low_priority_folders=("AppData" "Library" "Application Data" "OneDrive" "Dropbox" "Google Drive" "iCloud Drive" "Box Sync" "Box" "MEGAsync")
        local deferred_folders=$(mktemp)
        
        echo -e "${YELLOW}Scanning user folder and copying by priority...${NC}"
        
        # Single pass through directory
        for item in "$source"/*; do
            if [ -d "$item" ] && [ ! -L "$item" ]; then  # Skip symlinks
                local basename=$(basename "$item")
                local is_priority=false
                local is_low_priority=false
                
                # Check if it's a priority folder
                for pf in "${priority_folders[@]}"; do
                    if [ "$basename" = "$pf" ]; then
                        is_priority=true
                        break
                    fi
                done
                
                # Check if it's a low priority folder
                for lf in "${low_priority_folders[@]}"; do
                    if [ "$basename" = "$lf" ]; then
                        is_low_priority=true
                        break
                    fi
                done
                
                if [ "$is_priority" = true ]; then
                    echo -e "${GREEN}Copying priority folder: $basename${NC}"
                    # IMPORTANT: When using file filtering, excludes must come BEFORE includes
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $prune_opts $exclude_opts $include_opts '$item' '$dest/'"
                    execute_rsync_with_deferral "$rsync_cmd" "$dest" "$error_log" "$item" "$recovery_preset"
                elif [ "$is_low_priority" = true ]; then
                    # Add specific message for cloud folders
                    if [[ "$basename" =~ ^(OneDrive|Dropbox|Google Drive|iCloud Drive|Box Sync|Box|MEGAsync)$ ]]; then
                        echo -e "${YELLOW}Deferring cloud folder: $basename (likely already backed up online)${NC}"
                    else
                        echo -e "${YELLOW}Deferring low-priority folder: $basename${NC}"
                    fi
                    echo "$item" >> "$deferred_folders"
                else
                    echo -e "${GREEN}Copying folder: $basename${NC}"
                    # IMPORTANT: When using file filtering, excludes must come BEFORE includes
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $prune_opts $exclude_opts $include_opts '$item' '$dest/'"
                    execute_rsync_with_deferral "$rsync_cmd" "$dest" "$error_log" "$item" "$recovery_preset"
                fi
            elif [ -L "$item" ]; then
                # Log symlinks that were skipped with their targets
                local link_name=$(basename "$item")
                local link_target=$(readlink "$item" 2>/dev/null || echo "unknown")
                echo "Skipping symlink: $link_name" >> "$skipped_log"
                echo "$link_name -> $link_target" >> "$symlinks_log"
            fi
        done
        
        # Copy root level files (not in folders)
        echo -e "${YELLOW}Copying root level files...${NC}"
        # IMPORTANT: When using file filtering, excludes must come BEFORE includes
        eval "rsync -avh --progress --partial --append-verify $prune_opts $exclude_opts $include_opts --exclude='*/' '$source/' '$dest/'" 2>&1 | tee -a >(grep -E "failed:|error:|cannot|permission denied" >> "$error_log")
        
        # Finally, copy low priority folders
        if [ -s "$deferred_folders" ]; then
            echo -e "${YELLOW}Copying low-priority folders (AppData/Library)...${NC}"
            while IFS= read -r folder_path; do
                # Double-check it's not a symlink (shouldn't be, but be safe)
                if [ ! -L "$folder_path" ]; then
                    local folder_name=$(basename "$folder_path")
                    echo -e "${YELLOW}Copying low-priority folder: $folder_name${NC}"
                    # IMPORTANT: When using file filtering, excludes must come BEFORE includes
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $prune_opts $exclude_opts $include_opts '$folder_path' '$dest/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                fi
            done < "$deferred_folders"
        fi
        
        rm -f "$deferred_folders"
    else
        # Check if this is a full drive (has Windows/System32 or System/Library)
        local is_full_drive=false
        if [[ -d "$source/Windows" && -d "$source/Program Files" ]] || [[ -d "$source/System" && -d "$source/Library" ]] || [[ -d "$source/Users" && -d "$source/Windows" ]]; then
            is_full_drive=true
            echo -e "${YELLOW}Detected full drive - will extract user data and non-system folders${NC}"
            if [ "$include_programs" = "yes" ]; then
                echo -e "${YELLOW}Including Program Files and ProgramData as requested${NC}"
            fi
            
            # First, process Users folder if it exists
            if [ -d "$source/Users" ]; then
                echo -e "${GREEN}Processing Users folder with priority...${NC}"
                mkdir -p "$dest/Users"
                perform_rsync "$source/Users" "$dest/Users" "$skip_temp" "$include_programs" "$include_steam" "$include_excluded" "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$file_structure" "$recovery_preset" "$use_priority"
            fi
            
            # Handle Windows XP/2000 "Documents and Settings" folder
            if [ -d "$source/Documents and Settings" ]; then
                echo -e "${GREEN}Detected Windows XP/2000 system - processing Documents and Settings...${NC}"
                mkdir -p "$dest/Documents and Settings"
                perform_rsync "$source/Documents and Settings" "$dest/Documents and Settings" "$skip_temp" "$include_programs" "$include_steam" "$include_excluded" "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$file_structure" "$recovery_preset" "$use_priority"
            fi
            
            # Define Windows system folders to skip
            local windows_system_folders=("Windows" "PerfLogs" "\$Recycle.Bin" "System Volume Information" "Config.Msi" "\$Windows.~BT" "\$Windows.~WS" "Windows.old" "Recovery" "Intel" "AMD" "NVIDIA")
            
            # Add Program Files to skip list only if not requested
            if [ "$include_programs" != "yes" ]; then
                windows_system_folders+=("Program Files" "Program Files (x86)" "ProgramData")
            fi
            
            # Define Mac system folders to skip
            local mac_system_folders=("System" "Library" "private" "var" "tmp" "cores" ".Spotlight-V100" ".fseventsd" ".Trashes" ".vol" "bin" "sbin" "usr" "etc" "dev")
            
            # Combine all system folders
            local all_system_folders=("${windows_system_folders[@]}" "${mac_system_folders[@]}")
            
            # Extract useful data from Windows folder if it exists
            if [ -d "$source/Windows" ]; then
                echo -e "${YELLOW}Extracting useful data from Windows folder...${NC}"
                
                # Copy Fonts (important for designers)
                if [ -d "$source/Windows/Fonts" ]; then
                    echo -e "${GREEN}Copying Windows Fonts folder (custom fonts)${NC}"
                    mkdir -p "$dest/Windows_Extracted/Fonts"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$source/Windows/Fonts' '$dest/Windows_Extracted/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                fi
                
                # Copy Media (custom sounds/themes)
                if [ -d "$source/Windows/Media" ]; then
                    echo -e "${GREEN}Copying Windows Media folder (custom sounds)${NC}"
                    mkdir -p "$dest/Windows_Extracted/Media"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$source/Windows/Media' '$dest/Windows_Extracted/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                fi
            fi
            
            # Extract useful data from Mac Library folder if it exists
            if [ -d "$source/Library" ] && [ -d "$source/System" ]; then
                echo -e "${YELLOW}Extracting useful data from Mac system folders...${NC}"
                
                # Copy system-wide Fonts
                if [ -d "$source/Library/Fonts" ]; then
                    echo -e "${GREEN}Copying Mac Library Fonts (custom fonts)${NC}"
                    mkdir -p "$dest/Library_Extracted/Fonts"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$source/Library/Fonts' '$dest/Library_Extracted/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                fi
            fi
            
            # Process root level folders with priority ordering
            echo -e "${YELLOW}Categorizing root-level folders for prioritized copying...${NC}"
            
            # Arrays to categorize folders
            local root_files=()
            local priority_folders=()
            local backup_folders=()
            local normal_folders=()
            local system_folders=()
            local recycle_folders=()
            
            # First pass: categorize all items at root
            for item in "$source"/*; do
                if [ -f "$item" ]; then
                    root_files+=("$item")
                elif [ -d "$item" ] && [ ! -L "$item" ]; then
                    local dirname=$(basename "$item")
                    
                    # Skip if it's Users (already processed)
                    if [ "$dirname" = "Users" ]; then
                        continue
                    fi
                    
                    # Check for $RECYCLE.BIN, RECYCLER, or .Trashes
                    if [[ "$dirname" == '$RECYCLE.BIN' ]] || [[ "$dirname" == "RECYCLER" ]] || [[ "$dirname" == ".Trashes" ]]; then
                        recycle_folders+=("$item")
                        continue
                    fi
                    
                    # Check if it's a system folder
                    local is_system=false
                    for sys_folder in "${all_system_folders[@]}"; do
                        if [ "$dirname" = "$sys_folder" ]; then
                            is_system=true
                            system_folders+=("$item")
                            break
                        fi
                    done
                    
                    if [ "$is_system" = true ]; then
                        continue
                    fi
                    
                    # Check if it's a Steam library (save for last)
                    if [[ "$dirname" =~ ^[Ss]team[Ll]ibrary ]] || [[ "$dirname" = "Games" && -d "$item/steamapps" ]]; then
                        if [ "$include_steam" != "yes" ]; then
                            echo "$item - Steam/Game library (deferred to end)" >> "$skipped_log"
                        else
                            echo "$item - Steam/Game library (will process last)" >> "$skipped_log"
                            echo "$item" >> "$steam_dirs"  # Save path for later
                        fi
                        continue
                    fi
                    
                    # Check if it's a priority folder (contains Documents, Pictures, etc.)
                    # But NEVER include recycle bins even if they contain these folders
                    if ([[ "$dirname" =~ (Documents|Pictures|Photos|Videos|Music) ]] || 
                        [ -d "$item/Documents" ] || [ -d "$item/Pictures" ] || [ -d "$item/Photos" ]) &&
                       [[ "$dirname" != '$RECYCLE.BIN' ]] && [[ "$dirname" != "RECYCLER" ]] && [[ "$dirname" != ".Trashes" ]]; then
                        priority_folders+=("$item")
                    # Check if it's a backup folder (date pattern or contains "backup"/"computer")
                    elif [[ "$dirname" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || 
                         [[ "$dirname" =~ [Bb]ackup ]] || 
                         [[ "$dirname" =~ [Cc]omputer ]] || 
                         [[ "$dirname" == "ip" ]] || 
                         [[ "$dirname" == "iPhone" ]] || 
                         [[ "$dirname" == "iPad" ]]; then
                        backup_folders+=("$item")
                    else
                        normal_folders+=("$item")
                    fi
                fi
            done
            
            # Process folders in priority order
            echo ""
            echo -e "${GREEN}Processing folders in priority order...${NC}"
            
            # Phase 1: Priority folders (Documents, Pictures, etc.)
            if [ ${#priority_folders[@]} -gt 0 ]; then
                echo -e "${YELLOW}Phase 1: Priority user folders${NC}"
                for folder in "${priority_folders[@]}"; do
                    local dirname=$(basename "$folder")
                    echo -e "${GREEN}Copying priority folder: $dirname${NC}"
                    mkdir -p "$dest/$dirname"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$folder' '$dest/'"
                    execute_rsync_with_deferral "$rsync_cmd" "$dest" "$error_log" "$folder" "$recovery_preset"
                done
            fi
            
            # Phase 2: Root files (if any)
            if [ ${#root_files[@]} -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}Phase 2: Root-level files${NC}"
                for file in "${root_files[@]}"; do
                    local filename=$(basename "$file")
                    echo -e "${GREEN}Copying root file: $filename${NC}"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$file' '$dest/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                done
            fi
            
            # Phase 3: Backup folders
            if [ ${#backup_folders[@]} -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}Phase 3: Backup/dated folders${NC}"
                for folder in "${backup_folders[@]}"; do
                    local dirname=$(basename "$folder")
                    echo -e "${GREEN}Copying backup folder: $dirname${NC}"
                    
                    # Check if this backup contains a Users folder
                    if [ -d "$folder/Users" ]; then
                        echo "  Found Users folder in backup - processing with priority"
                        mkdir -p "$dest/$dirname"
                        # Recursive call to handle Users with priority
                        perform_rsync "$folder" "$dest/$dirname" "$skip_temp" "$include_programs" "$include_steam" "$include_excluded" "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$file_structure" "$recovery_preset" "$use_priority"
                    else
                        mkdir -p "$dest/$dirname"
                        local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$folder' '$dest/'"
                        execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                    fi
                done
            fi
            
            # Phase 4: Normal folders
            if [ ${#normal_folders[@]} -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}Phase 4: Other folders${NC}"
                for folder in "${normal_folders[@]}"; do
                    local dirname=$(basename "$folder")
                    echo -e "${GREEN}Copying folder: $dirname${NC}"
                    mkdir -p "$dest/$dirname"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$folder' '$dest/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                done
            fi
            
            # Phase 5: System folders (if included)
            if [ ${#system_folders[@]} -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}Phase 5: System folders${NC}"
                for folder in "${system_folders[@]}"; do
                    local dirname=$(basename "$folder")
                    if [ "$include_programs" = "yes" ] && [[ "$dirname" =~ ^Program\ Files|^ProgramData$ ]]; then
                        echo -e "${YELLOW}Copying program folder: $dirname${NC}"
                        mkdir -p "$dest/$dirname"
                        local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$folder' '$dest/'"
                        execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                    else
                        echo "$folder - System folder (skipped)" >> "$skipped_log"
                    fi
                done
            fi
            
            # Phase 6: Recycle bin (absolutely last, only in "Copy Everything" mode)
            if [ ${#recycle_folders[@]} -gt 0 ]; then
                if [ "$skip_temp" = "no" ]; then  # Copy Everything mode doesn't skip temp
                    echo ""
                    echo -e "${YELLOW}Phase 6: Recycle bin folders (lowest priority)${NC}"
                    echo -e "${YELLOW}Note: Processing recycle bin as requested in Copy Everything mode${NC}"
                    for folder in "${recycle_folders[@]}"; do
                        local dirname=$(basename "$folder")
                        echo -e "${YELLOW}Copying recycle folder: $dirname${NC}"
                        mkdir -p "$dest/$dirname"
                        local rsync_cmd="rsync -avh --progress --partial --append-verify '$folder' '$dest/'"
                        execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                    done
                else
                    for folder in "${recycle_folders[@]}"; do
                        echo "$folder - Recycle bin (excluded)" >> "$skipped_log"
                    done
                fi
            fi
            
            # Process Steam libraries last if requested
            if [ "$include_steam" = "yes" ] && [ -s "$steam_dirs" ]; then
                echo ""
                echo -e "${YELLOW}Processing Steam/Game libraries (lowest priority)...${NC}"
                while IFS= read -r steam_path; do
                    local dirname=$(basename "$steam_path")
                    echo -e "${YELLOW}Copying game library: $dirname (this may take a long time)${NC}"
                    mkdir -p "$dest/$dirname"
                    local rsync_cmd="rsync -avh --progress --partial --append-verify $exclude_opts '$steam_path' '$dest/'"
                    execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
                done < "$steam_dirs"
            fi
            
            # Process excluded large files last if requested
            if [ "$include_excluded" = "yes" ]; then
                echo ""
                echo -e "${YELLOW}Processing previously excluded large files (lowest priority)...${NC}"
                echo -e "${YELLOW}This includes: VMs, ISOs, installers, etc.${NC}"
                echo -e "${RED}WARNING: This may take a very long time and use lots of space${NC}"
                
                # Build include patterns for previously excluded files
                local include_patterns=""
                include_patterns="$include_patterns --include='*.vmdk' --include='*.vhd' --include='*.vhdx' --include='*.vdi' --include='*.qcow2'"
                include_patterns="$include_patterns --include='*.iso'"
                include_patterns="$include_patterns --include='*/Downloads/*.exe' --include='*/Downloads/*.msi'"
                include_patterns="$include_patterns --include='*.dmg' --include='*.pkg'"
                include_patterns="$include_patterns --include='*.deb' --include='*.rpm' --include='*.appx' --include='*.msix'"
                
                # Copy with inverted logic - include these specific files
                local rsync_cmd="rsync -avh --progress --partial --append-verify $include_patterns --include='*/' --exclude='*' '$source' '$dest'"
                execute_rsync_with_manifest "$rsync_cmd" "$dest" "$error_log"
            fi
        else
            # Not a full drive - check if it's a Users folder containing multiple users
            local found_users=false
            if [[ "$source" =~ Users$ ]] || [[ -d "$source/Default" && -d "$source/Public" ]]; then
                echo -e "${YELLOW}Detected Users folder - will process each user with priority${NC}"
                found_users=true
            
            # Define system folders that should be copied last
            local system_folders=("Public" "All Users" "Default" "Default User" "defaultuser0")
            
            # First, process regular user folders
            echo -e "${GREEN}Processing regular user folders first...${NC}"
            for user_dir in "$source"/*; do
                local username=$(basename "$user_dir")
                local is_system_folder=false
                
                # Check if it's a system folder
                for sys_folder in "${system_folders[@]}"; do
                    if [ "$username" = "$sys_folder" ]; then
                        is_system_folder=true
                        break
                    fi
                done
                
                # Process if it's a real directory (not symlink) and not a system folder
                if [ -d "$user_dir" ] && [ ! -L "$user_dir" ] && [ "$is_system_folder" = false ]; then
                    echo -e "${GREEN}Processing user: $username${NC}"
                    
                    # Create destination user folder
                    mkdir -p "$dest/$username"
                    
                    # Copy this user's files with priority
                    perform_rsync "$user_dir" "$dest/$username" "$skip_temp" "$include_programs" "$include_steam" "$include_excluded" "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$file_structure" "$recovery_preset" "$use_priority"
                fi
            done
            
            # Then process system/shared folders (except Default/Default User/defaultuser0)
            echo -e "${YELLOW}Processing shared/system folders...${NC}"
            for sys_folder in "Public" "All Users"; do
                if [ -d "$source/$sys_folder" ] && [ ! -L "$source/$sys_folder" ]; then
                    echo -e "${YELLOW}Processing system folder: $sys_folder${NC}"
                    mkdir -p "$dest/$sys_folder"
                    perform_rsync "$source/$sys_folder" "$dest/$sys_folder" "$skip_temp" "$include_programs" "$include_steam" "$include_excluded" "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$file_structure" "$recovery_preset" "$use_priority"
                fi
            done
        fi
        
            # If not a users folder, just do regular copy
            if [ "$found_users" = false ]; then
                # IMPORTANT: When using file filtering, excludes must come BEFORE includes
                local rsync_cmd="rsync -avh --progress --partial --append-verify --stats $prune_opts $exclude_opts $include_opts '$source' '$dest'"
                execute_rsync_with_deferral "$rsync_cmd" "$dest" "$error_log" "$source" "$recovery_preset"
            fi
        fi
    fi
    
    EXIT_CODE=${PIPESTATUS[0]}
    
    echo ""
    echo "----------------------------------------"
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}Transfer completed successfully!${NC}"
    else
        echo -e "${RED}Transfer completed with errors (exit code: $EXIT_CODE)${NC}"
        echo "You can run this script again to resume the transfer"
    fi
    
    # Count files actually copied (if using manifest)
    local files_copied=0
    if [ "$USE_MANIFEST" = "yes" ] && [ -f "$MANIFEST_FILE" ]; then
        files_copied=$(wc -l < "$MANIFEST_FILE" 2>/dev/null || echo 0)
    fi
    
    # Display and save error summary
    if [ -s "$error_log" ]; then
        echo ""
        echo -e "${RED}Failed files summary:${NC}"
        cat "$error_log" | sort -u | tee "$dest/recovery_errors_${SESSION_TIMESTAMP}.txt"
        echo ""
        echo -e "${YELLOW}Error log saved to: recovery_errors_${SESSION_TIMESTAMP}.txt${NC}"
    elif [ $files_copied -eq 0 ] && [ $EXIT_CODE -ne 0 ]; then
        # No files copied and exit code indicates error
        cat > "$dest/recovery_errors_${SESSION_TIMESTAMP}.txt" << EOF
========================================
        ⚠️  NO FILES COPIED! ⚠️
========================================

Recovery attempted: $(date)
Exit code: $EXIT_CODE

No files were successfully transferred.
Possible causes:
- Empty or corrupted source
- Mount failed but appeared successful
- Permission issues
- Source drive failure

Please check:
1. Source is properly mounted and readable
2. Source contains expected files
3. Try mounting manually to verify
========================================
EOF
        echo ""
        echo -e "${RED}No files were copied! Check source mount.${NC}"
    else
        # Create a success message if no errors
        local copied_msg=""
        if [ $files_copied -gt 0 ]; then
            copied_msg="\nFiles copied: $files_copied"
        fi
        cat > "$dest/recovery_errors_${SESSION_TIMESTAMP}.txt" << EOF
========================================
       🎉 SUCCESS! NO ERRORS! 🎉
========================================

Recovery completed: $(date)
All requested files copied successfully!$copied_msg

No failed transfers detected.
========================================
EOF
        echo ""
        echo -e "${GREEN}No errors during recovery! Success log saved.${NC}"
        if [ $files_copied -gt 0 ]; then
            echo -e "${GREEN}Files successfully copied: $files_copied${NC}"
        fi
    fi
    
    # Display folder processing summary (for all modes now)
    if [ -s "$skipped_log" ]; then
        echo ""
        echo -e "${YELLOW}Folder processing summary (saved to folder_summary.txt):${NC}"
        cat "$skipped_log" | sort | tee "$dest/folder_summary.txt"
        
        # Show what was actually skipped
        echo ""
        echo -e "${YELLOW}Actually skipped:${NC}"
        grep "(skipped)\|(deferred to end)" "$skipped_log" | grep -v "will process" | sort
    fi
    
    # Display deferred files summary if any
    if [ $DEFERRED_COUNT -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Deferred large files: $DEFERRED_COUNT files ($(echo "scale=2; $DEFERRED_SIZE / 1073741824" | bc)GB)${NC}"
        if [ -f "$DEFERRED_FILES" ]; then
            echo "Deferred files list saved to: $DEFERRED_FILES"
        fi
    fi
    
    # Save symlinks mapping if any were found
    if [ -s "$symlinks_log" ]; then
        echo ""
        echo -e "${YELLOW}Symlinks found (saved to symlinks_map.txt):${NC}"
        cat "$symlinks_log" | sort | tee "$dest/symlinks_map.txt"
        echo ""
        echo -e "${YELLOW}Note: Symlinks were not copied. To recreate them, see symlinks_map.txt${NC}"
    fi
    
    # Copy manifest to destination if using manifest mode (only on successful completion)
    if [ "$USE_MANIFEST" = "yes" ] && [ -n "$temp_manifest" ] && [ -f "$temp_manifest" ] && [ $EXIT_CODE -eq 0 ]; then
        echo ""
        echo -e "${GREEN}Transfer completed successfully - finalizing manifest...${NC}"
        if cp "$temp_manifest" "$dest_manifest"; then
            echo "Manifest saved to: $dest_manifest"
            echo "Total files tracked: $(wc -l < "$temp_manifest")"
            # Remove from desktop only after successful completion
            rm -f "$temp_manifest"
            echo "Removed temporary manifest from desktop"
        else
            echo -e "${RED}Warning: Could not save manifest to destination${NC}"
            echo -e "${YELLOW}Manifest preserved on desktop at: $temp_manifest${NC}"
            echo "You can manually copy this file to the destination later"
        fi
    elif [ "$USE_MANIFEST" = "yes" ] && [ -n "$temp_manifest" ] && [ -f "$temp_manifest" ]; then
        # Transfer had errors - save to destination but keep on desktop
        echo ""
        echo -e "${YELLOW}Transfer completed with errors - saving manifest for resume...${NC}"
        if cp "$temp_manifest" "$dest_manifest" 2>/dev/null; then
            echo "Manifest backed up to destination: $dest_manifest"
        fi
        echo -e "${YELLOW}Manifest preserved on desktop for resume: $temp_manifest${NC}"
        echo "Contains $(wc -l < "$temp_manifest") files already copied"
    fi
    
    # Clean up temporary files
    rm -f "$error_log" "$skipped_log" "$steam_dirs" "$symlinks_log" "$filter_file"
    
    # Mark transfer as complete
    TRANSFER_IN_PROGRESS=false
    
    # Process deferred files if any
    if [ $DEFERRED_COUNT -gt 0 ]; then
        process_deferred_files "$dest" "$source"
    fi
    
    # Copy folder metadata files if we did file-type filtering and transfer was successful
    if [ $EXIT_CODE -eq 0 ] && [ "$file_type_filter" = "yes" ]; then
        copy_folder_metadata_files "$source" "$dest"
    fi
    
    # Don't reorganize yet - wait until after verification
    # Save reorganization preference for later
    if [ $EXIT_CODE -eq 0 ] && [ "$file_structure" = "easy" ]; then
        PENDING_REORGANIZATION="yes"
        REORGANIZATION_DEST="$dest"
        REORGANIZATION_SOURCE="$source"
    fi
    
    return $EXIT_CODE
}


# Function for quick partition-based estimation (no directory traversal)
quick_estimate_size() {
    local source="$1"
    local mode_choice="$2"
    local include_programs="${3:-no}"
    local include_steam="${4:-no}"
    local partition_total_space="${5:-}"
    local partition_used_percent="${6:-}"
    
    clear
    echo -e "${YELLOW}Size Estimation${NC}"
    echo "=============="
    echo ""
    
    # Calculate used space from passed partition data or fall back to df
    local partition_used=0
    local partition_human=""
    local total_human=""
    
    if [ -n "$partition_total_space" ] && [ -n "$partition_used_percent" ]; then
        # Use the partition data from source selection
        total_human="$partition_total_space"
        
        # Source the partition display utils to get calculate_used_space function
        if [ -f "$SCRIPT_DIR/partition_display_utils.sh" ]; then
            source "$SCRIPT_DIR/partition_display_utils.sh"
            local used_space_display=$(calculate_used_space "$partition_total_space" "$partition_used_percent")
            partition_human="${used_space_display:-Unknown}"
            
            # For calculations, convert the human readable back to bytes (approximate)
            # Extract number from format like "696GB"
            if [[ "$used_space_display" =~ ^([0-9]+)(GB|TB|MB)$ ]]; then
                local value="${BASH_REMATCH[1]}"
                local unit="${BASH_REMATCH[2]}"
                case "$unit" in
                    GB) partition_used=$((value * 1024 * 1024 * 1024)) ;;
                    TB) partition_used=$((value * 1024 * 1024 * 1024 * 1024)) ;;
                    MB) partition_used=$((value * 1024 * 1024)) ;;
                esac
            fi
        else
            partition_human="$partition_used_percent of $partition_total_space"
        fi
    else
        # Fall back to df
        local mount_info=$(df "$source" 2>/dev/null | tail -1)
        if [ -z "$mount_info" ]; then
            echo -e "${RED}Could not determine partition information${NC}"
            return 1
        fi
        
        local used_space=$(echo "$mount_info" | awk '{print $3}')
        partition_used=$((used_space * 1024))
        partition_human=$(numfmt --to=iec-i --suffix=B $partition_used)
        
        # Get total size for display
        local total_blocks=$(echo "$mount_info" | awk '{print $2}')
        total_human=$(numfmt --to=iec-i --suffix=B $((total_blocks * 1024)))
    fi
    
    # Estimate based on mode
    local estimated_copy=0
    local estimate_message=""
    
    if [ "$mode_choice" = "3" ] || [ "$mode_choice" = "4" ]; then
        # Copy everything mode OR Direct copy mode - exact partition size
        estimated_copy=$partition_used
        echo "Source partition: ${total_human:-Unknown total}"
        echo "Space used: $partition_human"
        echo ""
        if [ "$mode_choice" = "3" ]; then
            echo -e "${GREEN}Copy Everything Mode${NC}"
        else
            echo -e "${GREEN}Direct Copy Mode${NC}"
        fi
        echo "Will copy entire partition contents"
        estimate_message="Estimated size to copy: $partition_human"
        
    elif [ "$mode_choice" = "2" ]; then
        # Full drive recovery - subtract typical system sizes
        echo "Source partition: ${total_human:-Unknown total}"
        echo "Space used: $partition_human"
        echo ""
        echo -e "${GREEN}Full Drive Recovery Mode${NC}"
        echo "Estimating user data (typical OS drive)..."
        
        # Calculate deductions
        local windows_size=$((30 * 1024 * 1024 * 1024))  # 30GB
        local programs_size=0
        if [ "$include_programs" != "yes" ]; then
            programs_size=$((25 * 1024 * 1024 * 1024))  # 25GB
        fi
        local system_files=$((20 * 1024 * 1024 * 1024))  # 20GB
        local temp_size=$((10 * 1024 * 1024 * 1024))  # 10GB
        
        # Calculate estimate
        estimated_copy=$((partition_used - windows_size - programs_size - system_files - temp_size))
        
        # Ensure we don't go negative or exceed partition size
        if [ $estimated_copy -lt 0 ]; then
            estimated_copy=$((partition_used / 3))
        fi
        if [ $estimated_copy -gt $partition_used ]; then
            estimated_copy=$partition_used
        fi
        
        estimate_message="Typical user data estimate: $(numfmt --to=iec-i --suffix=B $estimated_copy)"
        
    else
        # Single folder mode
        echo "Source partition: ${total_human:-Unknown total}"
        echo "Partition used: $partition_human"
        echo ""
        echo -e "${GREEN}Single Folder Mode${NC}"
        estimate_message="Selected folder will be less than $partition_human"
        estimated_copy=$partition_used  # Use as upper bound
    fi
    
    echo ""
    echo -e "${GREEN}$estimate_message${NC}"
    echo ""
    
    # Export the calculated size for space checking
    ESTIMATED_SIZE_HUMAN="$partition_human"
    ESTIMATED_SIZE_BYTES="$estimated_copy"
}

# Function to estimate size with minimal drive stress
estimate_size() {
    local source="$1"
    local skip_temp="$2"
    local mode_choice="$3"
    local include_programs="${4:-no}"
    local include_steam="${5:-no}"
    local include_excluded="${6:-no}"
    
    echo -e "${YELLOW}Estimating size (this may take a few minutes for large drives)...${NC}"
    echo "Reading directory structure with minimal disk access..."
    echo ""
    
    # Build exclude patterns for du command
    local du_excludes=""
    
    if [ "$skip_temp" = "yes" ]; then
        # Core temp/cache patterns
        du_excludes="$du_excludes --exclude='*/Cache*' --exclude='*/cache*' --exclude='*/Caches*'"
        du_excludes="$du_excludes --exclude='*/tmp/*' --exclude='*/temp/*' --exclude='*/Temp/*'"
        du_excludes="$du_excludes --exclude='*.tmp' --exclude='~*' --exclude='*~'"
        
        # System files
        du_excludes="$du_excludes --exclude='pagefile.sys' --exclude='hiberfil.sys' --exclude='swapfile.sys'"
        du_excludes="$du_excludes --exclude='$RECYCLE.BIN' --exclude='System Volume Information'"
        
        # Browser caches
        du_excludes="$du_excludes --exclude='*/Chrome/User Data/*/Cache*'"
        du_excludes="$du_excludes --exclude='*/Firefox/Profiles/*/cache*'"
        
        # Cloud sync
        du_excludes="$du_excludes --exclude='*/OneDrive/*' --exclude='*/Dropbox/bin/*'"
        
        # Development
        du_excludes="$du_excludes --exclude='node_modules' --exclude='.git' --exclude='__pycache__'"
        
        # Large files if not included
        if [ "$include_excluded" != "yes" ]; then
            du_excludes="$du_excludes --exclude='*.vmdk' --exclude='*.vhd' --exclude='*.vhdx'"
            du_excludes="$du_excludes --exclude='*.iso' --exclude='*.dmg' --exclude='*.pkg'"
        fi
    fi
    
    # Handle full drive mode
    if [ "$mode_choice" = "2" ]; then
        # System folders to exclude
        local system_excludes="--exclude='Windows' --exclude='System' --exclude='Library'"
        system_excludes="$system_excludes --exclude='PerfLogs' --exclude='private' --exclude='var'"
        system_excludes="$system_excludes --exclude='bin' --exclude='sbin' --exclude='usr' --exclude='etc'"
        
        if [ "$include_programs" != "yes" ]; then
            system_excludes="$system_excludes --exclude='Program Files' --exclude='Program Files (x86)'"
            system_excludes="$system_excludes --exclude='ProgramData'"
        fi
        
        du_excludes="$du_excludes $system_excludes"
    fi
    
    # For minimal reads, use a single du command with max-depth
    # This reads the directory structure only once
    local temp_file=$(mktemp)
    local breakdown_file=$(mktemp)
    
    echo -e "${YELLOW}Performing single-pass size calculation...${NC}"
    
    # Single du command that gives us everything we need in one pass
    # --max-depth=1 gives us top-level folders without multiple passes
    if [ "$mode_choice" = "2" ]; then
        # For full drive mode, get breakdown of top-level directories
        eval "du -b --max-depth=1 $du_excludes '$source' 2>/dev/null" > "$breakdown_file" &
    else
        # For folder mode, just get the total
        eval "du -sb $du_excludes '$source' 2>/dev/null" > "$temp_file" &
    fi
    
    local du_pid=$!
    
    # Show progress dots while calculating
    while kill -0 $du_pid 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo ""
    
    # Process results
    if [ "$mode_choice" = "2" ] && [ -s "$breakdown_file" ]; then
        # Extract total from last line (which is the source itself)
        local total_size=$(tail -1 "$breakdown_file" | cut -f1)
        
        if [ -n "$total_size" ]; then
            local size_human=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "$total_size bytes")
            echo ""
            echo -e "${GREEN}Estimated size to copy: $size_human${NC}"
            
            # Show breakdown from the same data (no additional reads!)
            echo ""
            echo "Breakdown of major folders:"
            
            # Parse the breakdown file for specific folders
            while IFS=$'\t' read -r size path; do
                local folder_name=$(basename "$path")
                
                # Skip the total line
                [ "$path" = "$source" ] && continue
                
                # Show Users folder
                if [ "$folder_name" = "Users" ]; then
                    local folder_human=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "$size")
                    echo "  Users folder: $folder_human"
                fi
                
                # Show Steam/Games folders if requested
                if [ "$include_steam" = "yes" ]; then
                    if [[ "$folder_name" =~ ^[Ss]team || ("$folder_name" = "Games" && -d "$path/steamapps") ]]; then
                        local folder_human=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "$size")
                        echo "  $folder_name: $folder_human"
                    fi
                fi
                
                # Show Program Files if included
                if [ "$include_programs" = "yes" ] && [[ "$folder_name" =~ ^Program\ Files|^ProgramData$ ]]; then
                    local folder_human=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "$size")
                    echo "  $folder_name: $folder_human"
                fi
            done < "$breakdown_file"
        fi
        
        rm -f "$breakdown_file"
    elif [ -s "$temp_file" ]; then
        # Simple mode - just show total
        local total_size=$(cut -f1 "$temp_file")
        local size_human=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "$total_size bytes")
        echo ""
        echo -e "${GREEN}Estimated size to copy: $size_human${NC}"
        rm -f "$temp_file"
    else
        echo -e "${RED}Could not estimate size${NC}"
        rm -f "$temp_file" "$breakdown_file"
    fi
    
    echo ""
    echo -e "${YELLOW}Note: This is an estimate. Actual size may vary slightly.${NC}"
    
    # Help choose destination drive
    echo ""
    echo "Available drives with free space:"
    df -h | grep -E '^/dev/' | awk '{print "  " $1 " - Free: " $4 " (Mounted at: " $6 ")"}'
    
    echo ""
}

# Function to get customer info
get_customer_info() {
    local last_ticket_file="$RECOVERY_DIR/last_ticket_info"
    local ticket_number=""
    local customer_name=""
    local computer_model=""
    
    # Check for recent ticket info
    if [ -f "$last_ticket_file" ]; then
        local last_ticket=$(grep "TICKET:" "$last_ticket_file" 2>/dev/null | cut -d' ' -f2-)
        local last_customer=$(grep "CUSTOMER:" "$last_ticket_file" 2>/dev/null | cut -d' ' -f2-)
        local last_computer=$(grep "COMPUTER:" "$last_ticket_file" 2>/dev/null | cut -d' ' -f2-)
        local last_date=$(grep "DATE:" "$last_ticket_file" 2>/dev/null | cut -d' ' -f2-)
        
        if [ -n "$last_ticket" ] && [ -n "$last_customer" ]; then
            echo -e "${YELLOW}Recent ticket found:${NC}"
            echo "  Ticket: $last_ticket"
            echo "  Customer: $last_customer"
            [ -n "$last_computer" ] && echo "  Computer: $last_computer"
            echo "  Date: $last_date"
            echo ""
            echo -n "Use this ticket info? [Y/n]: "
            read -r use_last
            
            if [[ ! "$use_last" =~ ^[Nn]$ ]]; then
                TICKET_NUMBER="$last_ticket"
                CUSTOMER_NAME="$last_customer"
                COMPUTER_MODEL="$last_computer"
                return
            fi
        fi
    fi
    
    # Get new ticket info
    echo -e "${GREEN}Customer Information${NC}"
    echo "=================="
    echo -n "Ticket number (or press Enter to skip): "
    read -r ticket_number
    
    echo -n "Customer last name (or press Enter to skip): "
    read -r customer_name
    
    echo -n "Computer brand/model (or press Enter to skip): "
    read -r computer_model
    
    # Set global variables
    TICKET_NUMBER="$ticket_number"
    CUSTOMER_NAME="$customer_name"
    COMPUTER_MODEL="$computer_model"
    
    # Save for next time if ticket and customer provided
    if [ -n "$ticket_number" ] && [ -n "$customer_name" ]; then
        mkdir -p "$RECOVERY_DIR"
        cat > "$last_ticket_file" << EOF
TICKET: $ticket_number
CUSTOMER: $customer_name
COMPUTER: $computer_model
DATE: $(date)
EOF
    fi
    
    echo ""
}

# Function for interactive mode
interactive_mode() {
    debug_log "Starting interactive_mode"
    
    # Get customer info first
    get_customer_info
    
    # Generate session timestamp once at the beginning
    # This timestamp is used throughout the entire recovery session to:
    # 1. Name manifest files consistently (even if interrupted/resumed)
    # 2. Track when recovery actually started in DRIVE_INFO.txt
    # 3. Group all files from the same recovery attempt together
    # When resuming, we load the original timestamp from settings
    SESSION_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    # Main menu loop
    while true; do
        clear
        echo -e "${GREEN}Interactive Rsync Copy Mode${NC}"
        if [ -n "$TICKET_NUMBER" ] || [ -n "$CUSTOMER_NAME" ] || [ -n "$COMPUTER_MODEL" ]; then
            echo -e "${YELLOW}Ticket: ${TICKET_NUMBER:-N/A} | Customer: ${CUSTOMER_NAME:-N/A}${NC}"
            [ -n "$COMPUTER_MODEL" ] && echo -e "${YELLOW}Computer: $COMPUTER_MODEL${NC}"
        fi
        echo ""
        
        # Check for recent recoveries
        local recovery_dir="$RECOVERY_DIR"
        local has_recent=false
        if [ -d "$recovery_dir" ] && [ -n "$(ls -A "$recovery_dir"/recovery_* 2>/dev/null)" ]; then
            has_recent=true
        fi
        
        echo "What would you like to do?"
        echo "1. Copy specific folder/files"
        echo "2. Full drive recovery (extract user data from system drive)"
        echo "3. Copy everything (full sync, no exclusions, prioritize typical user files first)"
        echo "4. Direct copy (fastest, no prioritization)"
        if [ "$has_recent" = true ]; then
            echo "5. Resume a recent recovery"
        fi
        echo "P. Toggle progress monitoring window (currently: ${USE_PROGRESS_MONITOR})"
        echo "0. Exit"
        echo ""
        
        if [ "$has_recent" = true ]; then
            echo -n "Enter choice [0-5,P]: "
        else
            echo -n "Enter choice [0-4,P]: "
        fi
        read -r mode_choice
        
        # Handle progress monitoring toggle
        if [[ "$mode_choice" =~ ^[Pp]$ ]]; then
            if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
                USE_PROGRESS_MONITOR="no"
                echo -e "${YELLOW}Progress monitoring window disabled${NC}"
            else
                USE_PROGRESS_MONITOR="yes"
                echo -e "${GREEN}Progress monitoring window enabled${NC}"
            fi
            # Save preference for next time
            save_user_preferences
            echo -e "${BLUE}Preference saved${NC}"
            sleep 1.5
            continue
        fi
        
        # Handle exit
        if [ "$mode_choice" = "0" ]; then
            echo "Exiting..."
            exit 0
        fi
    
    # Handle recent recoveries menu
    if [ "$mode_choice" = "5" ] && [ "$has_recent" = true ]; then
        show_recent_recoveries
        continue  # Go back to main menu after showing recent recoveries
    fi
    
    # Validate menu choice
    if [ "$has_recent" = true ]; then
        if ! [[ "$mode_choice" =~ ^[1-5]$ ]]; then
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            echo ""
            sleep 1
            continue
        fi
    else
        if ! [[ "$mode_choice" =~ ^[1-4]$ ]]; then
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            echo ""
            sleep 1
            continue
        fi
    fi
    
    # Initialize variables for all modes
    local skip_temp="yes"
    local file_type_filter="no"
    local filter_pictures="no"
    local filter_videos="no"
    local filter_documents="no"
    local filter_audio="no"
    local include_programs="no"
    local include_steam="no"
    local include_excluded="no"
    
    # Initialize manifest and structure variables
    USE_MANIFEST="yes"  # Enable by default for fast resume capability
    FILE_STRUCTURE="keep"
    RECOVERY_PRESET="balanced"  # Default preset
    USE_PRIORITY="yes"  # Default to using priority copying
    
    # For modes 1 and 2, ask for preset first
    if [ "$mode_choice" = "1" ] || [ "$mode_choice" = "2" ]; then
        echo ""
        if command -v show_enhanced_preset_menu &> /dev/null; then
            show_enhanced_preset_menu
            read -r preset_choice
            
            # Handle back option
            if [[ "$preset_choice" =~ ^[bB]$ ]]; then
                echo ""
                continue  # Go back to main menu
            fi
            
            # Handle preset selection
            case "$preset_choice" in
                1) RECOVERY_PRESET="media" ;;
                2) RECOVERY_PRESET="family" ;;
                3) RECOVERY_PRESET="photographer" ;;
                4) RECOVERY_PRESET="photographer_raw" ;;
                5) RECOVERY_PRESET="business" ;;
                6) RECOVERY_PRESET="developer" ;;
                7) RECOVERY_PRESET="gamer" ;;
                8) RECOVERY_PRESET="student" ;;
                9) RECOVERY_PRESET="balanced" ;;
                10) RECOVERY_PRESET="custom" ;;
                *)
                    echo -e "${RED}Invalid preset choice. Using balanced preset.${NC}"
                    RECOVERY_PRESET="balanced"
                    ;;
            esac
            
            # Apply preset settings (unless custom)
            if [ "$RECOVERY_PRESET" != "custom" ]; then
                echo ""
                # Apply the preset settings
                if command -v apply_preset_settings &> /dev/null; then
                    apply_preset_settings "$RECOVERY_PRESET"
                    
                    # Copy settings from preset
                    skip_temp="$SKIP_TEMP"
                    file_type_filter="$FILE_TYPE_FILTER"
                    filter_pictures="$FILTER_PICTURES"
                    filter_videos="$FILTER_VIDEOS"
                    filter_documents="$FILTER_DOCUMENTS"
                    filter_audio="$FILTER_AUDIO"
                    include_programs="$INCLUDE_PROGRAMS"
                    include_steam="$INCLUDE_STEAM"
                    include_excluded="$INCLUDE_EXCLUDED"
                    FILE_STRUCTURE="$FILE_STRUCTURE"
                    
                    # Show summary
                    show_preset_summary
                fi
            fi
        fi
    fi
    
    # Handle copy everything preset
    if [ "$mode_choice" = "3" ]; then
        echo ""
        echo -e "${GREEN}Copy Everything Mode${NC}"
        echo "This will copy ALL files and folders from source to destination."
        echo "Perfect for backing up external drives or data drives."
        echo ""
        echo -e "${YELLOW}Note: This mode will:${NC}"
        echo "• Copy ALL files including temp files, caches, system files"
        echo "• Preserve exact folder structure (no reorganization)"
        echo "• Include hidden files and folders"
        echo "• Still prioritize important folders (Pictures, Documents, etc.)"
        echo ""
        # Set all options for full copy
        skip_temp="no"
        file_type_filter="no"
        include_programs="yes"
        include_steam="yes"
        include_excluded="yes"
        FILE_STRUCTURE="keep"  # Always keep structure for full copy
    fi
    
    # Handle direct copy mode (no prioritization)
    if [ "$mode_choice" = "4" ]; then
        echo ""
        echo -e "${GREEN}Direct Copy Mode${NC}"
        echo "This will copy files in the order rsync encounters them."
        echo "Fastest option when source drive is healthy."
        echo ""
        echo -e "${YELLOW}Note: This mode will:${NC}"
        echo "• Copy files without folder prioritization"
        echo "• Use single rsync process (fastest)"
        echo "• Still exclude temp files by default"
        echo "• Preserve exact folder structure"
        echo ""
        # Set options for direct copy
        skip_temp="yes"  # Still skip temp by default
        file_type_filter="no"
        include_programs="yes"
        include_steam="yes"
        include_excluded="yes"
        FILE_STRUCTURE="keep"
        USE_PRIORITY="no"  # New flag to disable prioritization
        
        # Ask if user wants to include temp files
        echo -n "Include temporary files and caches? [y/N]: "
        read -r include_temp
        if [[ "$include_temp" =~ ^[Yy]$ ]]; then
            skip_temp="no"
            echo -e "${YELLOW}Including all temporary files${NC}"
        else
            echo -e "${GREEN}Excluding temporary files (recommended)${NC}"
        fi
    fi
    
    # Only show detailed options if custom preset was selected
    if [ "$mode_choice" = "2" ] && [ "$RECOVERY_PRESET" = "custom" ]; then
        echo ""
        echo -e "${YELLOW}Full Drive Recovery Mode - Custom Configuration${NC}"
        echo "This will extract Users folders and non-system data from a drive"
        echo ""
        echo -e "${YELLOW}COPY ORDER & TIMING:${NC}"
        echo "1. FIRST: User folders (Pictures, Documents, Desktop, etc.)"
        echo "2. THEN: Other user data (custom folders)"
        echo "3. THEN: Windows Fonts & Media (automatically included)"
        echo "4. THEN: Non-system root folders (if any)"
        echo "5. LAST: User AppData folders (settings, configs)"
        echo ""
        echo -e "${YELLOW}EXCLUDED BY DEFAULT:${NC}"
        echo "• Windows/System folders (except Fonts)"
        echo "• Program Files and ProgramData"
        echo "• Temp files, caches, OneDrive versions"
        echo "• Virtual machines, ISOs, installers"
        echo ""
        echo "Examples of data that might be missed:"
        echo "- Old game saves (e.g., C:\\Program Files\\GameName\\Saves)"
        echo "- QuickBooks company files in ProgramData"
        echo "- Custom software configurations in Program Files"
        echo "- Development environments (XAMPP, WAMP, WSL2)"
        echo "- IIS websites in C:\\inetpub"
        echo "- Steam libraries on other drives"
        echo "- Virtual machine files (*.vmdk, *.vhd - excluded by default)"
        echo "- ISO files (excluded by default)"
        echo "- Installer files in Downloads (excluded by default)"
        echo ""
        echo "TIP: For special cases, use option 1 to copy specific folders"
        echo ""
        echo -e "${YELLOW}(Type 'b' to go back to main menu)${NC}"
        echo -n "Do you need to include Program Files/ProgramData? [y/N/b]: "
        read -r include_programs
        if [[ "$include_programs" =~ ^[bB]$ ]]; then
            echo ""
            continue  # Go back to main menu
        fi
        if [[ "$include_programs" =~ ^[Yy]$ ]]; then
            echo -e "  ${GREEN}→ Will copy after non-system folders (step 4)${NC}"
        fi
        
        echo ""
        echo "Steam/Game Libraries:"
        echo "• Game saves and mods can be hard to recreate"
        echo "• Some games don't cloud sync properly"
        echo "• Libraries can be 100s of GB"
        echo -n "Include Steam/game libraries? [y/N]: "
        read -r include_steam
        if [[ "$include_steam" =~ ^[Yy]$ ]]; then
            echo -e "  ${GREEN}→ Will copy after AppData (step 6)${NC}"
        fi
        
        echo ""
        echo "Recovery of excluded files:"
        echo "• VMs, ISOs, installers are excluded by default"
        echo "• These can be huge but might be needed"
        echo -n "Copy excluded large files at the very end? [y/N]: "
        read -r include_excluded
        if [[ "$include_excluded" =~ ^[Yy]$ ]]; then
            echo -e "  ${GREEN}→ Will copy at the very end (step 7)${NC}"
        fi
    fi
    
    # Only ask about file-type filtering if custom preset AND not copy everything mode
    if [ "$mode_choice" != "3" ] && [ "$RECOVERY_PRESET" = "custom" ]; then
        # Ask about file-type filtering
        echo ""
        echo -e "${RED}⚠️  WARNING: File-type filtering can be CPU-intensive!${NC}"
        echo -e "${RED}   • Initial scanning may take 10+ minutes on large drives${NC}"
        echo -e "${RED}   • Not recommended for failing/slow drives${NC}"
        echo -e "${RED}   • Consider copying whole folders instead${NC}"
        echo ""
        echo -n "Filter by file type? [y/N]: "
        read -r filter_by_type
        
        if [[ "$filter_by_type" =~ ^[Yy]$ ]]; then
            file_type_filter="yes"
            echo ""
            echo "Select file types to recover:"
            echo -n "  Pictures (jpg, png, raw, etc.)? [Y/n]: "
            read -r pic_response
            if [[ ! "$pic_response" =~ ^[Nn]$ ]]; then
                filter_pictures="yes"
            fi
            
            echo -n "  Videos (mp4, avi, mov, etc.)? [Y/n]: "
            read -r vid_response
            if [[ ! "$vid_response" =~ ^[Nn]$ ]]; then
                filter_videos="yes"
            fi
            
            echo -n "  Documents (pdf, docx, txt, etc.)? [Y/n]: "
            read -r doc_response
            if [[ ! "$doc_response" =~ ^[Nn]$ ]]; then
                filter_documents="yes"
            fi
            
            echo -n "  Music (mp3, flac, wav, etc.)? [Y/n]: "
            read -r audio_response
            if [[ ! "$audio_response" =~ ^[Nn]$ ]]; then
                filter_audio="yes"
            fi
            
            # Validate at least one type selected
            if [ "$filter_pictures" = "no" ] && [ "$filter_videos" = "no" ] && [ "$filter_documents" = "no" ] && [ "$filter_audio" = "no" ]; then
                echo -e "${RED}Error: No file types selected. Please select at least one type.${NC}"
                echo ""
                echo -n "Press Enter to continue..."
                read -r
                continue  # Continue main menu loop
            fi
        fi
    fi
    
    # No need to ask for preset again - already done above
    
    echo ""
    
    # Source/destination selection loop to handle going back
    local source_dest_complete=false
    local GO_BACK_TO_SOURCE=false
    local source_device=""  # Track the source device to exclude from destinations
    
    while [ "$source_dest_complete" = false ]; do
        # Reset GO_BACK flag for each iteration
        GO_BACK_TO_SOURCE=false
        
        # Get source - use menu if partition analyzer is available
        local source_path=""
        if command -v show_source_menu &> /dev/null; then
            echo -e "${GREEN}Select Source Location${NC}"
            echo ""
        
        # Show the menu and get partition info
        local partitions=()
        local menu_output=$(mktemp)
        
        # Capture menu output
        show_source_menu > "$menu_output"
        
        # Read the displayed partitions from the temp file
        local temp_file="/tmp/rsync_displayed_partitions_$$"
        if [ -f "$temp_file" ]; then
            while IFS= read -r partition; do
                [ -n "$partition" ] && partitions+=("$partition")
            done < "$temp_file"
            rm -f "$temp_file"
        else
            # Fallback to all partitions if temp file missing
            while IFS= read -r partition; do
                [ -n "$partition" ] && partitions+=("$partition")
            done < <(get_partition_info)
        fi
        
        # Display the menu
        cat "$menu_output"
        rm -f "$menu_output"
        
        echo -e "${YELLOW}[B] Go back to main menu${NC}"
        echo ""
        echo -n "Enter choice [1-${PARTITION_MENU_COUNT:-5}], or B to go back: "
        read -r source_choice
        
        # Check for back option
        if [[ "$source_choice" =~ ^[bB]$ ]]; then
            echo ""
            break  # Exit source/destination loop
        fi
        
        if [[ "$source_choice" =~ ^[0-9]+$ ]] && [ "$source_choice" -le "${#partitions[@]}" ] && [ "$source_choice" -gt 0 ]; then
            # User selected a partition
            local selected_partition="${partitions[$((source_choice - 1))]}"
            IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "$selected_partition"
            
            # Store the source device for later exclusion
            source_device="$device"
            # Store partition info for size estimation
            source_total_space="$total_space"
            source_used_percent="$used_percent"
            
            if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
                source_path="$mountpoint"
                echo ""
                echo -e "${GREEN}Selected: $source_path${NC}"
                
                # If it looks like a full drive, suggest Users folder
                if [ -d "$source_path/Users" ] && [ "$mode_choice" = "1" ]; then
                    echo ""
                    echo "This appears to be a full drive. Would you like to:"
                    echo "1. Copy specific folder from this drive"
                    echo "2. Copy all Users folders"
                    echo -n "Choice [1-2]: "
                    read -r folder_choice
                    
                    if [ "$folder_choice" = "2" ]; then
                        source_path="$source_path/Users"
                        echo -e "${GREEN}Updated source: $source_path${NC}"
                    else
                        echo ""
                        echo "Enter the specific folder path within $source_path"
                        echo -n "(or press Enter to copy entire drive): "
                        read -r subfolder
                        if [ -n "$subfolder" ]; then
                            # Handle relative and absolute paths
                            if [[ "$subfolder" = /* ]]; then
                                source_path="$subfolder"
                            else
                                source_path="$source_path/$subfolder"
                            fi
                        fi
                    fi
                fi
            else
                echo -e "${RED}Error: Selected partition is not mounted${NC}"
                echo "Please mount the partition first or select another source"
                echo ""
                echo -n "Press Enter to continue..."
                read -r
                continue
            fi
        else
            # Manual entry
            echo ""
            echo "You can drag and drop folders or type/paste paths"
            echo -n "Enter source path: "
            read -r source_path
            fi
        else
            # Fallback to original method
            echo "You can drag and drop folders or type/paste paths"
            echo ""
            echo -n "Enter source path (drag folder here): "
            read -r source_path
        fi
        
        # Remove quotes and escape characters that might come from drag and drop
        source_path=$(echo "$source_path" | sed "s/^'//" | sed "s/'$//" | sed 's/\\//g')
        
        # Verify source exists
        if [ ! -e "$source_path" ]; then
            echo -e "${RED}Error: Source path does not exist: $source_path${NC}"
            echo ""
            echo -n "Press Enter to continue..."
            read -r
            continue
        fi
        
        # Check if source is a disk image file
        if [ -f "$source_path" ]; then
            # Check if it's likely a disk image
            local file_ext="${source_path##*.}"
            local is_image=false
            
            # Check by extension
            case "${file_ext,,}" in
                img|bin|dd|raw|dmg|iso|vhd|vhdx|vmdk)
                    is_image=true
                    ;;
            esac
            
            # Also check with file command
            if [ "$is_image" = false ]; then
                local file_type=$(file -b "$source_path" 2>/dev/null)
                if [[ "$file_type" =~ "filesystem"|"boot sector"|"disk image" ]]; then
                    is_image=true
                fi
            fi
            
            if [ "$is_image" = true ]; then
                echo ""
                echo -e "${YELLOW}Detected disk image file: $(basename "$source_path")${NC}"
                
                # Check if already mounted
                local existing_loop=$(losetup -j "$source_path" 2>/dev/null | cut -d: -f1)
                
                if [ -n "$existing_loop" ]; then
                    echo "Image is already mounted on $existing_loop"
                    local loop_device="$existing_loop"
                else
                    # Need to mount it
                    if [ "$EUID" -ne 0 ]; then
                        echo -e "${RED}Error: Need sudo privileges to mount disk image${NC}"
                        echo "Please restart the script with sudo"
                        echo ""
                        echo -n "Press Enter to continue..."
                        read -r
                        continue
                    fi
                    
                    echo "Mounting disk image..."
                    local loop_device=$(losetup -f)
                    
                    if ! losetup "$loop_device" "$source_path" 2>/dev/null; then
                        echo -e "${RED}Error: Failed to create loop device${NC}"
                        echo ""
                        echo -n "Press Enter to continue..."
                        read -r
                        continue
                    fi
                    
                    # Scan for partitions
                    partprobe "$loop_device" 2>/dev/null
                    sleep 1
                fi
                
                # Check if the loop device has partitions
                local partitions=($(ls ${loop_device}p* 2>/dev/null || echo "$loop_device"))
                
                if [ ${#partitions[@]} -gt 1 ]; then
                    # Multiple partitions found
                    echo ""
                    echo "Found ${#partitions[@]} partitions in the image:"
                    echo ""
                    
                    # Show partition list
                    local idx=1
                    for part in "${partitions[@]}"; do
                        local part_info=$(lsblk -no FSTYPE,SIZE,LABEL "$part" 2>/dev/null | head -1)
                        echo "[$idx] $part - $part_info"
                        ((idx++))
                    done
                    
                    echo ""
                    echo -n "Select partition [1-${#partitions[@]}]: "
                    read -r part_choice
                    
                    if [[ "$part_choice" =~ ^[0-9]+$ ]] && [ "$part_choice" -ge 1 ] && [ "$part_choice" -le ${#partitions[@]} ]; then
                        local selected_partition="${partitions[$((part_choice-1))]}"
                    else
                        echo -e "${RED}Invalid selection${NC}"
                        # Clean up loop device if we created it
                        [ -z "$existing_loop" ] && losetup -d "$loop_device" 2>/dev/null
                        continue
                    fi
                else
                    # Single partition or whole disk
                    local selected_partition="${partitions[0]}"
                fi
                
                # Get filesystem type for the selected partition
                local fs_type=$(lsblk -no FSTYPE "$selected_partition" 2>/dev/null | head -1)
                echo "Detected filesystem: $fs_type"
                
                # Try to mount the selected partition
                local mount_point="/mnt/recovery_image_$$"
                mkdir -p "$mount_point"
                
                # Set mount options based on filesystem type
                local mount_opts="-o ro"
                local mount_success=false
                
                case "$fs_type" in
                    hfsplus)
                        # Try with force option for HFS+
                        echo "Attempting to mount HFS+ filesystem..."
                        
                        # First check if it's already mounted by the GUI
                        local existing_mount=$(mount | grep "$selected_partition" | awk '{print $3}')
                        if [ -n "$existing_mount" ]; then
                            echo -e "${GREEN}Partition is already mounted at: $existing_mount${NC}"
                            source_path="$existing_mount"
                            mount_success=true
                            # Don't track for cleanup since we didn't mount it
                            export RECOVERY_IMAGE_MOUNT=""
                        else
                            # Try various mount methods
                            echo "Trying mount with force option..."
                            local mount_output=$(mount -t hfsplus -o ro,force "$selected_partition" "$mount_point" 2>&1)
                            local mount_result=$?
                            echo "$mount_output" | grep -v "warning"
                            
                            if [ $mount_result -eq 0 ]; then
                                mount_success=true
                            else
                                echo "Trying mount without force option..."
                                mount_output=$(mount -t hfsplus -o ro "$selected_partition" "$mount_point" 2>&1)
                                mount_result=$?
                                echo "$mount_output" | grep -v "warning"
                                
                                if [ $mount_result -eq 0 ]; then
                                    mount_success=true
                                else
                                    echo "Trying udisksctl mount..."
                                    # Try using udisksctl (what the GUI uses)
                                    local udisk_result=$(udisksctl mount -b "$selected_partition" 2>&1)
                                    if [ $? -eq 0 ]; then
                                        # Extract mount point from udisksctl output
                                        local udisk_mount=$(echo "$udisk_result" | grep -o "at /.*" | sed 's/at //')
                                        if [ -n "$udisk_mount" ]; then
                                            echo -e "${GREEN}Mounted via udisksctl at: $udisk_mount${NC}"
                                            source_path="$udisk_mount"
                                            mount_success=true
                                            # Track for udisks unmount
                                            export RECOVERY_IMAGE_UDISK="$selected_partition"
                                            rmdir "$mount_point" 2>/dev/null
                                        fi
                                    fi
                                fi
                            fi
                        fi
                        ;;
                    ntfs)
                        # Try ntfs-3g first, then kernel ntfs
                        if mount -t ntfs-3g -o ro "$selected_partition" "$mount_point" 2>/dev/null; then
                            mount_success=true
                        elif mount -t ntfs -o ro "$selected_partition" "$mount_point" 2>/dev/null; then
                            mount_success=true
                        fi
                        ;;
                    exfat)
                        # Try different exfat drivers
                        if mount -t exfat-fuse -o ro "$selected_partition" "$mount_point" 2>/dev/null; then
                            mount_success=true
                        elif mount -t exfat -o ro "$selected_partition" "$mount_point" 2>/dev/null; then
                            mount_success=true
                        fi
                        ;;
                    *)
                        # Try auto-detection
                        if mount $mount_opts "$selected_partition" "$mount_point" 2>/dev/null; then
                            mount_success=true
                        fi
                        ;;
                esac
                
                if [ "$mount_success" = true ]; then
                    # Verify the mount point actually has content
                    if [ -z "$(ls -A "$mount_point" 2>/dev/null)" ]; then
                        echo -e "${RED}Error: Mount succeeded but directory is empty${NC}"
                        echo "This usually indicates a filesystem problem."
                        umount "$mount_point" 2>/dev/null
                        rmdir "$mount_point" 2>/dev/null
                        [ -z "$existing_loop" ] && losetup -d "$loop_device" 2>/dev/null
                        continue
                    fi
                    
                    echo -e "${GREEN}Successfully mounted image at: $mount_point${NC}"
                    # Show what's in the mount
                    echo "Contents: $(ls -1 "$mount_point" 2>/dev/null | head -5 | tr '\n' ' ')$([ $(ls -1 "$mount_point" 2>/dev/null | wc -l) -gt 5 ] && echo '...')"
                    
                    source_path="$mount_point"
                    # Track this mount for cleanup later
                    export RECOVERY_IMAGE_MOUNT="$mount_point"
                    export RECOVERY_IMAGE_LOOP="$loop_device"
                    export RECOVERY_IMAGE_CREATED_LOOP="$existing_loop"
                else
                    echo -e "${RED}Error: Failed to mount $fs_type partition${NC}"
                    
                    # Give specific advice based on filesystem
                    case "$fs_type" in
                        hfsplus)
                            echo "For HFS+ filesystems, you may need:"
                            echo "  - Install hfsplus tools: sudo apt-get install hfsplus hfsprogs"
                            echo "  - Disable journaling on the Mac before imaging"
                            echo "  - Or try: sudo fsck.hfsplus -f $selected_partition"
                            ;;
                        ntfs)
                            echo "For NTFS filesystems, you may need:"
                            echo "  - Install ntfs-3g: sudo apt-get install ntfs-3g"
                            ;;
                        exfat)
                            echo "For exFAT filesystems, you may need:"
                            echo "  - Install exfat-utils: sudo apt-get install exfat-fuse exfat-utils"
                            ;;
                    esac
                    
                    # Clean up
                    rmdir "$mount_point" 2>/dev/null
                    [ -z "$existing_loop" ] && losetup -d "$loop_device" 2>/dev/null
                    continue
                fi
            fi
        fi
        
        # Collect SMART data if running with sudo and we have a device
        if [ "$EUID" -eq 0 ] && command -v smartctl &> /dev/null && [ -n "$source_device" ]; then
            echo ""
            echo -e "${CYAN}Collecting SMART health data for source drive...${NC}"
            local smart_health=$(smartctl -H "$source_device" 2>/dev/null)
            local health_status=$(echo "$smart_health" | grep -E "SMART overall-health|result:" | awk -F': ' '{print $2}')
            
            if [ -n "$health_status" ]; then
                if [[ "$health_status" =~ "PASSED" ]]; then
                    echo -e "${GREEN}Drive Health: $health_status ✓${NC}"
                else
                    echo -e "${RED}⚠️  Drive Health: $health_status${NC}"
                    if [[ "$health_status" =~ "FAILED" ]] || [[ "$health_status" =~ "FAILING" ]]; then
                        echo -e "${RED}WARNING: This drive is reporting SMART failures!${NC}"
                        echo -e "${RED}The drive may fail completely at any moment.${NC}"
                        echo ""
                        echo -n "Continue with recovery anyway? [y/N]: "
                        read -r continue_failing
                        if [[ ! "$continue_failing" =~ ^[Yy]$ ]]; then
                            echo "Aborting recovery."
                            continue
                        fi
                    fi
                fi
                
                # Show additional critical attributes
                echo ""
                echo "Critical Attributes:"
                smartctl -A "$source_device" 2>/dev/null | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Runtime_Bad_Block|Reported_Uncorrect" | awk '{if($10 != "0" && $10 != "-") print "  ⚠️  "$2": "$10; else if($2 ~ /Reallocated|Pending|Uncorrectable|Bad_Block|Uncorrect/) print "  ✓ "$2": "$10}'
            else
                echo -e "${YELLOW}Could not retrieve SMART health status${NC}"
            fi
        elif [ "$EUID" -ne 0 ] && [ -n "$source_device" ]; then
            echo ""
            echo -e "${YELLOW}Note: Run with sudo to see drive health data${NC}"
        fi
    
    # Note: skip_temp already initialized above
    
    # For copy everything mode, skip_temp is already set to "no"
    if [ "$mode_choice" = "3" ]; then
        echo ""
        echo -e "${YELLOW}Copy Everything mode - no files will be excluded${NC}"
    elif [ "$file_type_filter" = "yes" ]; then
        # When filtering by file type, always skip temp files
        echo ""
        echo -e "${YELLOW}File-type filtering enabled - temporary files will be skipped${NC}"
        echo -e "${RED}Note: Initial file scanning may take several minutes...${NC}"
    elif [ "$RECOVERY_PRESET" = "custom" ]; then
        # Only ask for custom preset
        echo ""
        echo "Do you want to skip temporary/cache files? (recommended for slow drives)"
        echo "This will exclude browser caches, temp files, system files, etc."
        echo -n "Skip temporary files? [Y/n]: "
        read -r skip_response
        
        if [[ "$skip_response" =~ ^[Nn]$ ]]; then
            skip_temp="no"
        fi
    fi
    
    # Store the include options for later use
    local include_prog="no"
    local include_steam_param="no"
    local include_excluded_param="no"
    
    # When filtering by file type, force these to "no"
    if [ "$file_type_filter" = "yes" ]; then
        include_programs="n"
        include_steam="n"
        include_excluded="n"
    elif [ "$mode_choice" = "2" ]; then
        if [[ "$include_programs" =~ ^[Yy]$ ]]; then
            include_prog="yes"
        fi
        if [[ "$include_steam" =~ ^[Yy]$ ]]; then
            include_steam_param="yes"
        fi
        if [[ "$include_excluded" =~ ^[Yy]$ ]]; then
            include_excluded_param="yes"
        fi
    fi
    
    # Always do quick size estimation
    quick_estimate_size "$source_path" "$mode_choice" "$include_prog" "$include_steam_param" "$source_total_space" "$source_used_percent"
    
    # Track estimated size from previous estimation
    local estimated_size="See above"
    
    # Get destination - loop until valid path provided
    while true; do
        echo ""
        
        # Use menu if partition analyzer is available
        if command -v show_destination_menu &> /dev/null; then
            echo -e "${GREEN}Select Destination Location${NC}"
            echo ""
            
            # Show the menu, excluding the source device
            show_destination_menu "$estimated_size" "$source_device"
            
            # Read the displayed partitions from the temp file
            local partitions=()
            local temp_file="/tmp/rsync_displayed_dest_partitions_$$"
            if [ -f "$temp_file" ]; then
                while IFS= read -r partition; do
                    [ -n "$partition" ] && partitions+=("$partition")
                done < "$temp_file"
                rm -f "$temp_file"
            fi
            
            local num_partitions=${#partitions[@]}
            echo -e "${YELLOW}[B] Go back to source selection${NC}"
            echo ""
            echo -n "Enter choice [1-$((num_partitions + 2))], or B to go back: "
            read -r dest_choice
            
            # Check for back option
            if [[ "$dest_choice" =~ ^[bB]$ ]]; then
                echo ""
                echo "Going back to source selection..."
                echo ""
                # We need to go back to source selection
                GO_BACK_TO_SOURCE=true
                break
            fi
            
            if [[ "$dest_choice" =~ ^[0-9]+$ ]] && [ "$dest_choice" -le "$num_partitions" ] && [ "$dest_choice" -gt 0 ]; then
                # User selected a partition
                local selected_partition="${partitions[$((dest_choice - 1))]}"
                IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "$selected_partition"
                
                if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
                    # Ask for subfolder
                    echo ""
                    echo "Selected: $mountpoint"
                    echo ""
                    echo "Enter folder name for recovery (e.g., 'Recovered_Data', 'John_Backup')"
                    if [ -n "$TICKET_NUMBER" ] || [ -n "$CUSTOMER_NAME" ]; then
                        # Use computer model if available, otherwise drive ID
                        local identifier=""
                        if [ -n "$COMPUTER_MODEL" ]; then
                            # Sanitize computer model
                            identifier=$(echo "$COMPUTER_MODEL" | sed 's/[^a-zA-Z0-9-]//g' | cut -c1-15)
                        fi
                        
                        # Fall back to drive ID if no computer model or sanitization failed
                        if [ -z "$identifier" ] && [ -n "$source_device" ] && command -v get_drive_identifier &> /dev/null; then
                            identifier=$(get_drive_identifier "$source_device" "$source_path")
                        fi
                        [ -z "$identifier" ] && identifier="UNKWN"
                        
                        local suggested_name="${TICKET_NUMBER}_${CUSTOMER_NAME}_${identifier}"
                        # Clean up any double underscores or leading/trailing underscores
                        suggested_name=$(echo "$suggested_name" | sed 's/__/_/g' | sed 's/^_//;s/_$//')
                        echo -e "${YELLOW}Press Enter to auto-create: $suggested_name${NC}"
                    else
                        echo -e "${YELLOW}Press Enter for automatic naming if destination has files${NC}"
                    fi
                    echo -n "Folder name (or Enter for automatic): "
                    read -r folder_name
                    
                    if [ -n "$folder_name" ]; then
                        dest_path="$mountpoint/$folder_name"
                    else
                        dest_path="$mountpoint"
                    fi
                    
                    echo ""
                    echo -e "${GREEN}Destination: $dest_path${NC}"
                    # Store free space for later comparison
                    dest_free_space="$free_space"
                else
                    # Unmounted partition - try to mount it
                    echo ""
                    echo -e "${YELLOW}This partition is not mounted. Attempting to mount...${NC}"
                    echo ""
                    
                    # Try to mount using the mount_partition function
                    if command -v mount_partition &> /dev/null; then
                        if mount_partition "$device" "$fs_type" "$fs_label"; then
                            # Get the new mount point
                            local mount_name=""
                            if [ -n "$fs_label" ] && [ "$fs_label" != "<no label>" ]; then
                                mount_name=$(echo "$fs_label" | sed 's/[^a-zA-Z0-9_-]/_/g')
                            else
                                mount_name=$(basename "$device")
                            fi
                            mountpoint="/media/$USER/$mount_name"
                            
                            echo ""
                            echo "Enter folder name for recovery (e.g., 'Recovered_Data', 'John_Backup')"
                            echo -n "Folder name (or press Enter for root of drive): "
                            read -r folder_name
                            
                            if [ -n "$folder_name" ]; then
                                dest_path="$mountpoint/$folder_name"
                            else
                                dest_path="$mountpoint"
                            fi
                            
                            echo ""
                            echo -e "${GREEN}Destination: $dest_path${NC}"
                            # For newly mounted, we need to get free space
                            dest_free_space=$(df -h "$mountpoint" 2>/dev/null | tail -1 | awk '{print $4}')
                        else
                            echo ""
                            echo -e "${RED}Failed to mount partition. Please try another destination.${NC}"
                            echo -n "Press Enter to continue..."
                            read -r
                            continue
                        fi
                    else
                        echo -e "${RED}Mount function not available. Please mount manually and try again.${NC}"
                        echo -n "Press Enter to continue..."
                        read -r
                        continue
                    fi
                fi
            elif [ "$dest_choice" = "$((num_partitions + 1))" ]; then
                # Manual entry
                echo ""
                echo "You can drag and drop folders or type/paste paths"
                echo -n "Enter destination path: "
                read -r dest_path
            elif [ "$dest_choice" = "$((num_partitions + 2))" ]; then
                # Create new folder on existing partition
                echo ""
                echo "Select partition for new folder:"
                local idx=1
                for partition in "${partitions[@]}"; do
                    IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "$partition"
                    if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
                        echo "[$idx] $mountpoint (Free: ${free_space:-N/A})"
                        idx=$((idx + 1))
                    fi
                done
                
                echo -n "Select partition [1-$((idx-1))]: "
                read -r part_choice
                
                if [[ "$part_choice" =~ ^[0-9]+$ ]] && [ "$part_choice" -lt "$idx" ] && [ "$part_choice" -gt 0 ]; then
                    # Find the selected mountpoint
                    local selected_idx=1
                    for partition in "${partitions[@]}"; do
                        IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "$partition"
                        if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
                            if [ "$selected_idx" = "$part_choice" ]; then
                                echo ""
                                echo -n "Enter new folder name: "
                                read -r folder_name
                                if [ -n "$folder_name" ]; then
                                    dest_path="$mountpoint/$folder_name"
                                else
                                    echo -e "${RED}Error: No folder name provided${NC}"
                                    continue
                                fi
                                break
                            fi
                            selected_idx=$((selected_idx + 1))
                        fi
                    done
                fi
            else
                echo -e "${RED}Invalid choice, please try again${NC}"
                continue
            fi
        else
            # Fallback to original method
            echo -n "Enter destination path (drag folder here): "
            read -r dest_path
        fi
        
        # Check if empty
        if [ -z "$dest_path" ]; then
            echo -e "${RED}Error: No destination path provided. Please enter a path.${NC}"
            continue
        fi
        
        # Remove quotes and escape characters
        dest_path=$(echo "$dest_path" | sed "s/^'//" | sed "s/'$//" | sed 's/\\//g')
        
        # Check if it's just a relative path without parent directory
        if [[ ! "$dest_path" =~ ^/ ]] && [[ ! "$dest_path" =~ ^\. ]]; then
            echo -e "${RED}Error: '$dest_path' appears to be a relative path.${NC}"
            echo "Please provide a full path (e.g., /home/user/backup or ./backup)"
            continue
        fi
        
        # Verify destination directory exists or can be created
        if [ -d "$dest_path" ]; then
            echo -e "${GREEN}Destination directory exists: $dest_path${NC}"
            break
        else
            # Check if parent directory exists
            dest_parent=$(dirname "$dest_path")
            if [ ! -d "$dest_parent" ]; then
                echo -e "${RED}Error: Parent directory does not exist: $dest_parent${NC}"
                echo "Please ensure the parent directory exists."
                continue
            else
                # Offer to create the destination
                echo -e "${YELLOW}Destination does not exist: $dest_path${NC}"
                echo -n "Create this directory? [Y/n]: "
                read -r create_response
                if [[ ! "$create_response" =~ ^[Nn]$ ]]; then
                    if mkdir -p "$dest_path" 2>/dev/null; then
                        echo -e "${GREEN}Created destination directory: $dest_path${NC}"
                        break
                    else
                        echo -e "${RED}Error: Could not create directory: $dest_path${NC}"
                        echo "Please check permissions or choose another location."
                        continue
                    fi
                fi
            fi
        fi
    done
    
    # Check if we need to go back to source selection
    if [ "$GO_BACK_TO_SOURCE" = true ]; then
        continue  # Go back to source/destination loop
    fi
    
    # Check if destination has enough free space before finalizing
    if [ -n "$dest_free_space" ] && [ -n "$ESTIMATED_SIZE_HUMAN" ] && [ -n "$dest_path" ]; then
        # Convert human readable sizes to GB for comparison
        local free_gb=0
        local needed_gb=0
        
        # Convert free space (e.g., "607G", "1.2T", "500M")
        if [[ "$dest_free_space" =~ ^([0-9.]+)([KMGT])i?$ ]]; then
            local value="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            case "$unit" in
                G) free_gb="$value" ;;
                T) free_gb=$(echo "$value * 1024" | bc) ;;
                M) free_gb=$(echo "$value / 1024" | bc) ;;
                K) free_gb=$(echo "$value / 1048576" | bc) ;;
            esac
        fi
        
        # Convert needed space (e.g., "696GB", "1.3TiB")
        if [[ "$ESTIMATED_SIZE_HUMAN" =~ ^([0-9.]+)(GB|TB|MB|GiB|TiB|MiB)$ ]]; then
            local value="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            case "$unit" in
                GB|GiB) needed_gb="$value" ;;
                TB|TiB) needed_gb=$(echo "$value * 1024" | bc) ;;
                MB|MiB) needed_gb=$(echo "$value / 1024" | bc) ;;
            esac
        fi
        
        # Compare with 10% buffer
        local needed_with_buffer=$(echo "$needed_gb * 1.1" | bc)
        
        if command -v bc &> /dev/null && [ "$free_gb" != "0" ] && [ "$needed_gb" != "0" ]; then
            if (( $(echo "$needed_with_buffer > $free_gb" | bc -l) )); then
                echo ""
                echo -e "${RED}⚠️  WARNING: Insufficient space on destination!${NC}"
                echo "Estimated size: $ESTIMATED_SIZE_HUMAN"
                echo "Free space: $dest_free_space"
                echo "Recommended: At least $(printf "%.0f" "$needed_with_buffer")GB free (includes 10% buffer)"
                echo ""
                echo "What would you like to do?"
                echo "1. Continue anyway (I know what I'm doing)"
                echo "2. Choose a different destination"
                echo "3. Cancel operation"
                echo ""
                echo -n "Choice [1-3]: "
                read -r space_choice
                
                case "$space_choice" in
                    1)
                        echo -e "${YELLOW}Continuing despite low space warning...${NC}"
                        ;;
                    2)
                        echo "Please choose a different destination..."
                        echo ""
                        # Clear destination path to restart selection
                        dest_path=""
                        dest_free_space=""
                        continue  # Go back to destination selection loop
                        ;;
                    3)
                        echo "Operation cancelled."
                        exit 0
                        ;;
                    *)
                        echo "Invalid choice. Cancelling operation."
                        exit 1
                        ;;
                esac
            fi
        fi
    fi
    
    # Check if destination was cleared (user wants to reselect)
    if [ -z "$dest_path" ]; then
        continue  # Go back to destination while loop
    fi
    
    # If we get here, source and destination are complete
    source_dest_complete=true
    done  # End of source/destination selection loop
    
    # Check if user backed out without selecting source/destination
    if [ -z "$source_path" ] || [ "$source_path" = "" ]; then
        continue  # Go back to main menu
    fi
    
    # Manifest mode is now enabled by default
    echo ""
    echo -e "${GREEN}Fast resume mode enabled (tracks copied files)${NC}"
    
    # Ask about file structure preference for custom preset only
    if [ "$mode_choice" = "3" ]; then
        # Already set to "keep" above
        echo ""
        echo -e "${YELLOW}Copy Everything mode - maintaining exact folder structure${NC}"
    elif [ "$RECOVERY_PRESET" = "custom" ]; then
        echo ""
        echo "File organization after recovery:"
        echo "1. Easy mode (recommended) - Reorganize for easier access"
        echo "2. Keep original structure - Maintain exact folder hierarchy"
        echo ""
        echo "Easy mode will:"
        echo "  • Move single user's folders to root for direct access"
        echo "  • Group system/program folders in 'Other files'"
        echo ""
        echo -n "Choose organization mode [1/2, default=1]: "
        read -r structure_choice
        
        if [ "${structure_choice:-1}" = "1" ]; then
            FILE_STRUCTURE="easy"
            echo -e "${GREEN}Will reorganize files for easier access after recovery${NC}"
        else
            FILE_STRUCTURE="keep"
            echo -e "${GREEN}Will maintain original folder structure${NC}"
        fi
    else
        # Use preset's file structure setting
        if [ "$FILE_STRUCTURE" = "easy" ]; then
            echo ""
            echo -e "${GREEN}Will reorganize files for easier access (preset default)${NC}"
        else
            echo ""
            echo -e "${GREEN}Will maintain original folder structure (preset default)${NC}"
        fi
    fi
    
    # Save initial settings for easy resume (will update with final dest later)
    save_recovery_settings "$source_path" "$dest_path" "$skip_temp" "$mode_choice" \
        "${include_programs:-n}" "${include_steam:-n}" "${include_excluded:-n}" \
        "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$USE_MANIFEST" "$FILE_STRUCTURE" "$RECOVERY_PRESET" "" "$SESSION_TIMESTAMP" "$USE_PRIORITY"
    
    # Show copy order summary for full drive recovery
    if [ "$mode_choice" = "2" ]; then
        echo ""
        echo -e "${GREEN}COPY ORDER SUMMARY:${NC}"
        echo "1. User priority folders (Pictures, Documents, etc.)"
        echo "2. Other user folders"
        echo "3. Windows Fonts & Media"
        echo "4. Non-system root folders"
        if [[ "$include_programs" =~ ^[Yy]$ ]]; then
            echo "5. Program Files/ProgramData"
        fi
        echo "$([ "$include_programs" = "y" ] && echo "6" || echo "5"). User AppData (settings)"
        if [[ "$include_steam" =~ ^[Yy]$ ]]; then
            echo "$([ "$include_programs" = "y" ] && echo "7" || echo "6"). Steam/Game libraries"
        fi
        if [[ "$include_excluded" =~ ^[Yy]$ ]]; then
            local step=5
            [ "$include_programs" = "y" ] && ((step++))
            [ "$include_steam" = "y" ] && ((step++))
            echo "$((step+1)). VMs, ISOs, installers"
        fi
        echo ""
        sleep 2
    fi
    
    # Determine final destination path (may add subfolder)
    if command -v determine_destination_path &> /dev/null; then
        # Get source device for drive info
        local source_device=""
        if [ -n "$source_device" ]; then
            # source_device was set during partition selection
            true
        else
            # Try to determine device from mount point
            source_device=$(df "$source_path" 2>/dev/null | tail -1 | awk '{print $1}')
        fi
        
        local final_dest=$(determine_destination_path "$dest_path" "$source_path" "$source_device" "$TICKET_NUMBER" "$CUSTOMER_NAME" "$COMPUTER_MODEL")
        
        # Create drive info file
        if command -v create_drive_info_file &> /dev/null; then
            create_drive_info_file "$final_dest" "$source_path" "$source_device" "$TICKET_NUMBER" "$CUSTOMER_NAME"
        fi
    else
        local final_dest="$dest_path"
    fi
    
    # Update recovery settings with final destination path if it changed
    if [ "$final_dest" != "$dest_path" ] && [ -n "$LATEST_SETTINGS_FILE" ]; then
        # Update the DEST_PATH and add FINAL_DEST_PATH in the settings file
        sed -i "s|^DEST_PATH=.*|DEST_PATH=\"$dest_path\"|" "$LATEST_SETTINGS_FILE"
        sed -i "s|^FINAL_DEST_PATH=.*|FINAL_DEST_PATH=\"$final_dest\"|" "$LATEST_SETTINGS_FILE"
        # Also update the latest file
        local recovery_dir="$RECOVERY_DIR"
        cp "$LATEST_SETTINGS_FILE" "$recovery_dir/latest"
    fi
    
    # Setup progress monitoring if enabled
    if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
        # Capture initial disk usage
        local initial_used=$(df -B1 "$final_dest" 2>/dev/null | tail -1 | awk '{print $3}')
        if [ -z "$initial_used" ]; then
            # If destination doesn't exist yet, use parent directory
            local parent_dir=$(dirname "$final_dest")
            initial_used=$(df -B1 "$parent_dir" 2>/dev/null | tail -1 | awk '{print $3}')
        fi
        
        # Get source size
        local source_size_bytes=0
        # Try to get source used space in bytes
        local source_used=$(df -B1 "$source_path" 2>/dev/null | tail -1 | awk '{print $3}')
        if [ -n "$source_used" ]; then
            source_size_bytes="$source_used"
        else
            # Fallback: estimate based on source path
            source_size_bytes=$(du -sb "$source_path" 2>/dev/null | awk '{print $1}' || echo "0")
        fi
        
        # Create progress data file
        local progress_file="/tmp/rsync_progress_$$.info"
        cat > "$progress_file" << EOF
SOURCE_SIZE=$source_size_bytes
DEST_PATH=$final_dest
INITIAL_USED=$initial_used
START_TIME=$(date +%s)
CUSTOMER_NAME=$CUSTOMER_NAME
TICKET_NUMBER=$TICKET_NUMBER
MANIFEST_FILE=$MANIFEST_FILE
EOF
        
        # Launch progress monitor in new terminal
        echo -e "${GREEN}Launching progress monitor window...${NC}"
        if command -v gnome-terminal &> /dev/null; then
            gnome-terminal --title="Recovery Progress - ${CUSTOMER_NAME:-Unknown}" \
                          --geometry=60x20 \
                          -- "$SCRIPT_DIR/progress_monitor.sh" "$$" &
        elif command -v xterm &> /dev/null; then
            xterm -title "Recovery Progress" -geometry 60x20 \
                  -e "$SCRIPT_DIR/progress_monitor.sh" "$$" &
        else
            echo -e "${YELLOW}No terminal found for progress window. Continuing without visual progress.${NC}"
        fi
        
        # Give monitor time to start
        sleep 2
    fi
    
    perform_rsync "$source_path" "$final_dest" "$skip_temp" "$include_prog" "$include_steam_param" "$include_excluded_param" \
        "$file_type_filter" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio" "$FILE_STRUCTURE" "$RECOVERY_PRESET" "$USE_PRIORITY"
    
    # Cleanup progress file
    if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
        rm -f "/tmp/rsync_progress_$$.info" 2>/dev/null
    fi
    
    # Exit after successful completion
    debug_log "Exiting interactive_mode - transfer complete"
    break
    done  # End of main menu loop
    
    debug_log "interactive_mode function returning"
}

# Function to show recent recoveries menu
show_recent_recoveries() {
    local recovery_dir="$RECOVERY_DIR"
    echo ""
    echo -e "${GREEN}Recent Recoveries:${NC}"
    echo ""
    
    # List recent recoveries with numbers
    local count=1
    local -a recovery_files=()
    
    # Get recovery files sorted by modification time (newest first)
    while IFS= read -r file; do
        recovery_files+=("$file")
        
        # Load and display recovery info
        if load_recovery_settings "$file"; then
            echo "$count) $TIMESTAMP"
            echo "   From: $SOURCE_PATH"
            # Show final destination if different from base destination
            if [ -n "$FINAL_DEST_PATH" ] && [ "$FINAL_DEST_PATH" != "$DEST_PATH" ]; then
                echo "   To:   $FINAL_DEST_PATH (on $DEST_PATH)"
            else
                echo "   To:   $DEST_PATH"
            fi
            echo ""
        fi
        ((count++))
    done < <(ls -t "$recovery_dir"/recovery_* 2>/dev/null | head -10)
    
    echo "0) Start new recovery"
    echo ""
    echo -n "Select recovery to resume [0-$((count-1))]: "
    read -r selection
    
    if [ "$selection" = "0" ]; then
        mode_choice=""  # Reset to show main menu again
        interactive_mode
    elif [ "$selection" -ge 1 ] && [ "$selection" -lt "$count" ]; then
        local selected_file="${recovery_files[$((selection-1))]}"
        if load_recovery_settings "$selected_file"; then
            echo ""
            echo -e "${GREEN}Resuming recovery from $TIMESTAMP${NC}"
            # Use final destination if available, otherwise use base destination
            local resume_dest="${FINAL_DEST_PATH:-$DEST_PATH}"
            
            # Setup progress monitoring if enabled
            if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
                # Capture initial disk usage
                local initial_used=$(df -B1 "$resume_dest" 2>/dev/null | tail -1 | awk '{print $3}')
                if [ -z "$initial_used" ]; then
                    # If destination doesn't exist yet, use parent directory
                    local parent_dir=$(dirname "$resume_dest")
                    initial_used=$(df -B1 "$parent_dir" 2>/dev/null | tail -1 | awk '{print $3}')
                fi
                
                # Get source size
                local source_size_bytes=0
                # Try to get source used space in bytes
                local source_used=$(df -B1 "$SOURCE_PATH" 2>/dev/null | tail -1 | awk '{print $3}')
                if [ -n "$source_used" ]; then
                    source_size_bytes="$source_used"
                else
                    # Fallback: estimate based on source path
                    source_size_bytes=$(du -sb "$SOURCE_PATH" 2>/dev/null | awk '{print $1}' || echo "0")
                fi
                
                # Create progress data file
                local progress_file="/tmp/rsync_progress_$$.info"
                cat > "$progress_file" << EOF
SOURCE_SIZE=$source_size_bytes
DEST_PATH=$resume_dest
INITIAL_USED=$initial_used
START_TIME=$(date +%s)
CUSTOMER_NAME=$CUSTOMER_NAME
TICKET_NUMBER=$TICKET_NUMBER
MANIFEST_FILE=$MANIFEST_FILE
EOF
                
                # Launch progress monitor in new terminal
                echo -e "${GREEN}Launching progress monitor window...${NC}"
                if command -v gnome-terminal &> /dev/null; then
                    gnome-terminal --title="Recovery Progress - ${CUSTOMER_NAME:-Unknown}" \
                                  --geometry=60x20 \
                                  -- "$SCRIPT_DIR/progress_monitor.sh" "$$" &
                elif command -v xterm &> /dev/null; then
                    xterm -title "Recovery Progress" -geometry 60x20 \
                          -e "$SCRIPT_DIR/progress_monitor.sh" "$$" &
                else
                    echo -e "${YELLOW}No terminal found for progress window. Continuing without visual progress.${NC}"
                fi
                
                # Give monitor time to start
                sleep 2
            fi
            
            perform_rsync "$SOURCE_PATH" "$resume_dest" "$SKIP_TEMP" \
                "${INCLUDE_PROGRAMS:-no}" "${INCLUDE_STEAM:-no}" "${INCLUDE_EXCLUDED:-no}" \
                "${FILE_TYPE_FILTER:-no}" "${FILTER_PICTURES:-no}" "${FILTER_VIDEOS:-no}" "${FILTER_DOCUMENTS:-no}" "${FILTER_AUDIO:-no}" "${FILE_STRUCTURE:-keep}" "${RECOVERY_PRESET:-balanced}" "${USE_PRIORITY:-yes}"
            
            # Cleanup progress file
            if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
                rm -f "/tmp/rsync_progress_$$.info" 2>/dev/null
            fi
        fi
    else
        echo -e "${RED}Invalid selection${NC}"
        show_recent_recoveries
    fi
}

# Function for resume mode
resume_mode() {
    debug_log "Starting resume_mode"
    
    local recovery_dir="$RECOVERY_DIR"
    local latest_file="$recovery_dir/latest"
    # Save the manifest mode that was set by command line
    local command_line_manifest="$USE_MANIFEST"
    
    if [ -f "$latest_file" ]; then
        if load_recovery_settings "$latest_file"; then
            # Override the loaded USE_MANIFEST with command line setting
            # If --fast-resume was used, command_line_manifest is "yes"
            # If --resume was used, command_line_manifest is "no"
            USE_MANIFEST="$command_line_manifest"
            
            echo -e "${GREEN}Resuming latest recovery...${NC}"
            echo ""
            
            # Check if local paths exist, otherwise try portable resolution
            local resolved_source="$SOURCE_PATH"
            local resolved_dest="$DEST_PATH"
            
            if [ ! -d "$SOURCE_PATH" ] && [ -n "$SOURCE_LABEL" ] && [ "$SOURCE_LABEL" != "unknown" ]; then
                echo -e "${YELLOW}Source path not found on this workstation, searching for drive label: $SOURCE_LABEL${NC}"
                if new_source=$(find_drive_by_label "$SOURCE_LABEL"); then
                    resolved_source="$new_source"
                    echo -e "${GREEN}Found source at: $resolved_source${NC}"
                    # Verify it's the correct drive
                    if ! verify_drive_match "$resolved_source" "$SOURCE_SIZE" "$SOURCE_FSTYPE" "$SOURCE_UUID" "source"; then
                        echo -e "${RED}Drive verification failed. Aborting resume.${NC}"
                        return 1
                    fi
                else
                    echo -e "${RED}Could not find source drive with label: $SOURCE_LABEL${NC}"
                    echo "Please ensure the source drive is connected and mounted."
                    return 1
                fi
            fi
            
            if [ ! -d "$DEST_PATH" ] && [ -n "$DEST_LABEL" ] && [ "$DEST_LABEL" != "unknown" ]; then
                echo -e "${YELLOW}Destination path not found on this workstation, searching for drive label: $DEST_LABEL${NC}"
                if new_dest=$(find_drive_by_label "$DEST_LABEL"); then
                    resolved_dest="$new_dest"
                    # Update final destination path if needed
                    if [ -n "$FINAL_DEST_PATH" ]; then
                        FINAL_DEST_PATH="${new_dest}/$(basename "$FINAL_DEST_PATH")"
                    fi
                    echo -e "${GREEN}Found destination at: $resolved_dest${NC}"
                    # Verify it's the correct drive
                    if ! verify_drive_match "$resolved_dest" "$DEST_SIZE" "$DEST_FSTYPE" "$DEST_UUID" "destination"; then
                        echo -e "${RED}Drive verification failed. Aborting resume.${NC}"
                        return 1
                    fi
                    # Also check if the expected recovery folder exists
                    if [ -n "$TICKET_NUMBER" ] && [ "$TICKET_NUMBER" != "" ]; then
                        local expected_folder="${new_dest}/${TICKET_NUMBER}_"
                        if ! ls -d ${expected_folder}* >/dev/null 2>&1; then
                            echo -e "${YELLOW}Warning: Expected recovery folder starting with '${TICKET_NUMBER}_' not found${NC}"
                            echo -n "Continue anyway? [y/N]: "
                            read -r continue_choice
                            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                                return 1
                            fi
                        fi
                    fi
                else
                    echo -e "${RED}Could not find destination drive with label: $DEST_LABEL${NC}"
                    echo "Please ensure the destination drive is connected and mounted."
                    return 1
                fi
            fi
            
            # Update paths for display and execution
            SOURCE_PATH="$resolved_source"
            DEST_PATH="$resolved_dest"
            
            echo "Recovery settings:"
            echo "  Source: $SOURCE_PATH"
            # Show final destination if available
            if [ -n "$FINAL_DEST_PATH" ] && [ "$FINAL_DEST_PATH" != "$DEST_PATH" ]; then
                echo "  Destination: $FINAL_DEST_PATH"
                echo "  Base drive: $DEST_PATH"
            else
                echo "  Destination: $DEST_PATH"
            fi
            echo "  Skip temp files: $SKIP_TEMP"
            echo "  Timestamp: $TIMESTAMP"
            if [ "$USE_MANIFEST" = "yes" ]; then
                echo "  Mode: Fast resume (manifest mode)"
            else
                echo "  Mode: Normal resume"
            fi
            
            # Check if destination has been reorganized
            local check_dest="${FINAL_DEST_PATH:-$DEST_PATH}"
            if [ -f "$check_dest/REORGANIZATION_INFO.txt" ]; then
                echo ""
                echo -e "${RED}Warning: This recovery has been reorganized for easy access.${NC}"
                echo "Files have been moved from their original locations."
                echo ""
                echo "Resuming is not recommended on reorganized recoveries as it may:"
                echo "- Create duplicate files in wrong locations"
                echo "- Overwrite the reorganized structure"
                echo ""
                echo "Please complete any remaining transfers manually."
                echo ""
                echo -n "Press Enter to exit..."
                read -r
                exit 0
            fi
            
            echo ""
            echo -n "Resume this recovery? [Y/n]: "
            read -r resume_confirm
            
            if [[ ! "$resume_confirm" =~ ^[Nn]$ ]]; then
                # Use final destination if available, otherwise use base destination
                local resume_dest="${FINAL_DEST_PATH:-$DEST_PATH}"
                
                # Setup progress monitoring if enabled
                if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
                    # Capture initial disk usage
                    local initial_used=$(df -B1 "$resume_dest" 2>/dev/null | tail -1 | awk '{print $3}')
                    if [ -z "$initial_used" ]; then
                        # If destination doesn't exist yet, use parent directory
                        local parent_dir=$(dirname "$resume_dest")
                        initial_used=$(df -B1 "$parent_dir" 2>/dev/null | tail -1 | awk '{print $3}')
                    fi
                    
                    # Get source size
                    local source_size_bytes=0
                    # Try to get source used space in bytes
                    local source_used=$(df -B1 "$SOURCE_PATH" 2>/dev/null | tail -1 | awk '{print $3}')
                    if [ -n "$source_used" ]; then
                        source_size_bytes="$source_used"
                    else
                        # Fallback: estimate based on source path
                        source_size_bytes=$(du -sb "$SOURCE_PATH" 2>/dev/null | awk '{print $1}' || echo "0")
                    fi
                    
                    # Find or predict manifest file path if using manifest mode
                    local predicted_manifest=""
                    if [ "$USE_MANIFEST" = "yes" ]; then
                        # Create source name from SOURCE_PATH
                        local source_name=$(basename "$SOURCE_PATH")
                        source_name="${source_name//[^a-zA-Z0-9-_]/_}"
                        
                        # For fast resume, look for existing manifest files
                        # Check destination for existing manifests
                        local latest_manifest=""
                        if [ -d "$resume_dest" ]; then
                            latest_manifest=$(ls -t "$resume_dest"/recovery_manifest_${source_name}_*.txt 2>/dev/null | head -1)
                        fi
                        
                        # If not found at destination, check desktop
                        if [ -z "$latest_manifest" ] || [ ! -f "$latest_manifest" ]; then
                            latest_manifest=$(ls -t "$HOME/Desktop"/rsync_recovery_manifest_${source_name}_*.txt 2>/dev/null | head -1)
                        fi
                        
                        # Use found manifest or predict new one
                        if [ -n "$latest_manifest" ] && [ -f "$latest_manifest" ]; then
                            predicted_manifest="$latest_manifest"
                        else
                            # No existing manifest, predict new filename
                            if [ -z "$SESSION_TIMESTAMP" ]; then
                                SESSION_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                            fi
                            predicted_manifest="$HOME/Desktop/rsync_recovery_manifest_${source_name}_${SESSION_TIMESTAMP}.txt"
                        fi
                    fi
                    
                    # Create progress data file
                    local progress_file="/tmp/rsync_progress_$$.info"
                    cat > "$progress_file" << EOF
SOURCE_SIZE=$source_size_bytes
DEST_PATH=$resume_dest
INITIAL_USED=$initial_used
START_TIME=$(date +%s)
CUSTOMER_NAME=$CUSTOMER_NAME
TICKET_NUMBER=$TICKET_NUMBER
MANIFEST_FILE=${predicted_manifest:-$MANIFEST_FILE}
EOF
                    
                    # Launch progress monitor in new terminal
                    echo -e "${GREEN}Launching progress monitor window...${NC}"
                    if command -v gnome-terminal &> /dev/null; then
                        gnome-terminal --title="Recovery Progress - ${CUSTOMER_NAME:-Unknown}" \
                                      --geometry=60x20 \
                                      -- "$SCRIPT_DIR/progress_monitor.sh" "$$" &
                    elif command -v xterm &> /dev/null; then
                        xterm -title "Recovery Progress" -geometry 60x20 \
                              -e "$SCRIPT_DIR/progress_monitor.sh" "$$" &
                    else
                        echo -e "${YELLOW}No terminal found for progress window. Continuing without visual progress.${NC}"
                    fi
                    
                    # Give monitor time to start
                    sleep 2
                fi
                
                perform_rsync "$SOURCE_PATH" "$resume_dest" "$SKIP_TEMP" \
                    "${INCLUDE_PROGRAMS:-no}" "${INCLUDE_STEAM:-no}" "${INCLUDE_EXCLUDED:-no}" \
                    "${FILE_TYPE_FILTER:-no}" "${FILTER_PICTURES:-no}" "${FILTER_VIDEOS:-no}" "${FILTER_DOCUMENTS:-no}" "${FILTER_AUDIO:-no}" "${FILE_STRUCTURE:-keep}" "${RECOVERY_PRESET:-balanced}" "${USE_PRIORITY:-yes}"
                
                # Cleanup progress file
                if [ "$USE_PROGRESS_MONITOR" = "yes" ]; then
                    rm -f "/tmp/rsync_progress_$$.info" 2>/dev/null
                fi
            else
                echo "Showing all recent recoveries..."
                show_recent_recoveries
            fi
        fi
    else
        debug_log "No recovery settings file found at $latest_file"
        echo -e "${YELLOW}No previous recovery settings found.${NC}"
        echo "Starting new recovery..."
        interactive_mode
    fi
    
    debug_log "resume_mode returning"
}

# Function to reorganize files for easier user access
reorganize_for_easy_access() {
    local dest="$1"
    local source="$2"
    
    echo ""
    echo -e "${GREEN}Reorganizing files for easier access...${NC}"
    
    # Check if there's a Users folder in the destination
    if [ ! -d "$dest/Users" ]; then
        echo "No Users folder found, skipping reorganization"
        return
    fi
    
    # Count real users (exclude Public, All Users, Shared, Default, Default User)
    local user_count=0
    local single_user=""
    local system_users=("Public" "All Users" "Shared" "Default" "Default User")
    
    for user_dir in "$dest/Users"/*/; do
        if [ -d "$user_dir" ]; then
            local username=$(basename "$user_dir")
            local is_system=false
            
            # Check if this is a system user
            for sys_user in "${system_users[@]}"; do
                if [ "$username" = "$sys_user" ]; then
                    is_system=true
                    break
                fi
            done
            
            if [ "$is_system" = false ]; then
                user_count=$((user_count + 1))
                single_user="$username"
            fi
        fi
    done
    
    echo "Found $user_count real user(s)"
    
    # FIRST: Move non-Users folders to "Other files" (before moving user folders)
    local other_files_created=false
    for item in "$dest"/*/; do
        if [ -d "$item" ]; then
            local folder_name=$(basename "$item")
            
            # Skip Users folder and our special folders
            if [ "$folder_name" != "Users" ] && 
               [ "$folder_name" != "Other files" ] && 
               [ "$folder_name" != "Windows_Extracted" ] && 
               [ "$folder_name" != "Library_Extracted" ]; then
                
                # Create "Other files" if needed
                if [ "$other_files_created" = false ]; then
                    mkdir -p "$dest/Other files"
                    other_files_created=true
                    echo ""
                    echo "Moving system/program folders to 'Other files'..."
                fi
                
                echo "  Moving $folder_name"
                mv "$item" "$dest/Other files/"
                # Log the move
                echo "MOVED|$item|$dest/Other files/$folder_name" >> "$dest/REORGANIZATION_MOVES.log"
            fi
        fi
    done
    
    # THEN: If single user, promote their folders to root
    if [ $user_count -eq 1 ] && [ -n "$single_user" ]; then
        echo -e "${YELLOW}Single user detected: $single_user${NC}"
        echo "Moving user folders to root of recovery destination..."
        
        # Move each folder from the user directory to root
        for item in "$dest/Users/$single_user"/*/; do
            if [ -d "$item" ]; then
                local folder_name=$(basename "$item")
                
                # Skip if destination already exists
                if [ -e "$dest/$folder_name" ]; then
                    echo "  Skipping $folder_name (already exists at destination)"
                else
                    echo "  Moving $folder_name to root"
                    mv "$item" "$dest/"
                    # Log the move
                    echo "MOVED|$item|$dest/$folder_name" >> "$dest/REORGANIZATION_MOVES.log"
                fi
            fi
        done
        
        # Also move files in user root (if any)
        for item in "$dest/Users/$single_user"/*; do
            if [ -f "$item" ]; then
                local file_name=$(basename "$item")
                if [ ! -e "$dest/$file_name" ]; then
                    mv "$item" "$dest/"
                    # Log the move
                    echo "MOVED|$item|$dest/$file_name" >> "$dest/REORGANIZATION_MOVES.log"
                fi
            fi
        done
        
        # Remove the now-empty user folder
        rmdir "$dest/Users/$single_user" 2>/dev/null
    fi
    
    # Clean up empty Users folder if all users were moved
    if [ -d "$dest/Users" ] && [ -z "$(ls -A "$dest/Users")" ]; then
        rmdir "$dest/Users"
    fi
    
    # Get drive label for privacy
    local source_label=""
    if [[ "$source" =~ ^/dev/ ]]; then
        source_label=$(lsblk -no LABEL "$source" 2>/dev/null | head -1)
    else
        # Extract last component of path as label
        source_label=$(basename "$source")
    fi
    
    # Create a reorganization summary and detailed log
    cat > "$dest/REORGANIZATION_INFO.txt" << EOF
Files Reorganized for Easy Access
================================
Date: $(date)
Source Drive: ${source_label:-Original drive}

What was done:
EOF
    
    # Create detailed move log for reversal
    cat > "$dest/REORGANIZATION_MOVES.log" << EOF
# Reorganization Move Log
# Format: MOVED|source_path|destination_path
# This file can be used to reverse the reorganization
# Generated: $(date)

EOF
    
    if [ $user_count -eq 1 ]; then
        cat >> "$dest/REORGANIZATION_INFO.txt" << EOF
- Single user ($single_user) folders moved to root directory
- User files are now directly accessible
EOF
    fi
    
    if [ "$other_files_created" = true ]; then
        cat >> "$dest/REORGANIZATION_INFO.txt" << EOF
- System and program folders moved to "Other files" folder
- This includes any recovered program data, system files, etc.
EOF
    fi
    
    cat >> "$dest/REORGANIZATION_INFO.txt" << EOF

To restore original structure:
- Move folders from root back to Users/$single_user/
- Move folders from "Other files" back to root

Detailed move log saved to: REORGANIZATION_MOVES.log
This log contains exact source and destination paths for reversal.
EOF
    
    echo ""
    echo -e "${GREEN}Reorganization complete!${NC}"
    echo "Summary saved to: REORGANIZATION_INFO.txt"
    echo "Move log saved to: REORGANIZATION_MOVES.log"
}

# Main script logic
debug_log "rsync_recovery.sh starting with argument: '$1'"
case "$1" in
    --resume)
        resume_mode
        ;;
    --fast-resume)
        USE_MANIFEST="yes"
        resume_mode
        ;;
    -h|--help)
        usage
        ;;
    "")
        # No arguments - run interactive mode
        interactive_mode
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        usage
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Operation complete!${NC}"
play_completion_sound

# Cleanup progress monitoring
cleanup_progress_monitor

# Offer to verify the recovery if it was successful
if [ $EXIT_CODE -eq 0 ] && [ -n "$CURRENT_DEST" ]; then
    debug_log "About to ask for verification in rsync_recovery.sh"
    echo ""
    # Signal progress monitor that we're waiting for user input
    write_progress_state "WAITING_FOR_USER"
    echo -n "Would you like to verify the recovery? [Y/n]: "
    read -r verify_choice
    if [[ ! "$verify_choice" =~ ^[Nn]$ ]]; then
        # Determine verification options based on recovery mode
        verify_opts="--exclude-system"
        if [ "$skip_temp" = "no" ]; then
            # Copy Everything mode - don't exclude system
            verify_opts=""
        fi
        
        # Run verification
        if [ -f "$SCRIPT_DIR/verify_recovery.sh" ]; then
            # Export filter settings for verification script
            export FILE_TYPE_FILTER FILTER_PICTURES FILTER_VIDEOS FILTER_DOCUMENTS FILTER_AUDIO
            "$SCRIPT_DIR/verify_recovery.sh" "$CURRENT_SOURCE" "$CURRENT_DEST" --size $verify_opts
            VERIFICATION_EXIT_CODE=$?
            
            # If verification passed and we have pending reorganization
            if [ $VERIFICATION_EXIT_CODE -eq 0 ] && [ "${PENDING_REORGANIZATION:-no}" = "yes" ]; then
                echo ""
                echo -n "Verification successful! Would you like to reorganize files for easy access? [Y/n]: "
                read -r reorg_choice
                if [[ ! "$reorg_choice" =~ ^[Nn]$ ]]; then
                    reorganize_for_easy_access "$REORGANIZATION_DEST" "$REORGANIZATION_SOURCE"
                fi
            fi
        else
            echo -e "${YELLOW}Verification script not found in $SCRIPT_DIR${NC}"
        fi
    else
        # User skipped verification - ask about reorganization if pending
        if [ "${PENDING_REORGANIZATION:-no}" = "yes" ]; then
            echo ""
            echo -e "${YELLOW}Warning: Skipping verification means we cannot confirm all files were recovered.${NC}"
            echo -n "Would you still like to reorganize files for easy access? [y/N]: "
            read -r reorg_choice
            if [[ "$reorg_choice" =~ ^[Yy]$ ]]; then
                reorganize_for_easy_access "$REORGANIZATION_DEST" "$REORGANIZATION_SOURCE"
            fi
        fi
    fi
fi

echo ""
echo "Press Enter to exit..."
read -r

debug_log "rsync_recovery.sh exiting"