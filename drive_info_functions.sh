#!/bin/bash

# Drive information and subfolder naming functions for rsync_recovery

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to get drive identifier (5 chars)
get_drive_identifier() {
    local device="$1"
    local mount_point="$2"
    local identifier=""
    
    # Try label first
    local label=$(lsblk -no LABEL "$device" 2>/dev/null | head -1)
    if [ -n "$label" ] && [ "$label" != " " ]; then
        # Take first 5 chars of label, remove spaces
        identifier=$(echo "$label" | tr -d ' ' | cut -c1-5)
    fi
    
    # If no label, try size
    if [ -z "$identifier" ]; then
        local size=$(lsblk -no SIZE "$device" 2>/dev/null | head -1)
        if [ -n "$size" ]; then
            # Remove spaces and take up to 5 chars
            identifier=$(echo "$size" | tr -d ' ')
        fi
    fi
    
    # If still nothing, use last 5 chars of mount point
    if [ -z "$identifier" ]; then
        local mount_name=$(basename "$mount_point")
        if [ ${#mount_name} -ge 5 ]; then
            identifier="${mount_name: -5}"
        else
            identifier="$mount_name"
        fi
    fi
    
    # Ensure it's filesystem safe
    identifier=$(echo "$identifier" | sed 's/[^a-zA-Z0-9]//g' | cut -c1-5)
    
    # Default if still empty
    [ -z "$identifier" ] && identifier="UNKWN"
    
    echo "$identifier"
}

# Function to get full drive label (sanitized for filesystem use)
get_drive_label() {
    local device="$1"
    local mount_point="$2"
    local label=""
    
    # Try label first
    label=$(lsblk -no LABEL "$device" 2>/dev/null | head -1)
    
    # If no label, use mount point name
    if [ -z "$label" ] || [ "$label" = " " ]; then
        label=$(basename "$mount_point")
    fi
    
    # Sanitize for filesystem use - keep more chars than ID version
    # Remove problematic chars but keep spaces, dashes, underscores
    label=$(echo "$label" | sed 's/[<>:"|?*\/\\]//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    
    # Limit to reasonable length (40 chars)
    if [ ${#label} -gt 40 ]; then
        label="${label:0:40}"
    fi
    
    # Default if still empty
    [ -z "$label" ] && label="UnknownVolume"
    
    echo "$label"
}

# Function to generate recovery folder name
generate_recovery_folder_name() {
    local ticket="$1"
    local customer="$2"
    local source_device="$3"
    local source_mount="$4"
    local computer_model="${5:-}"  # Optional computer model
    
    local folder_name=""
    
    # Add ticket number if provided
    if [ -n "$ticket" ]; then
        folder_name="${ticket}"
    fi
    
    # Add customer name if provided
    if [ -n "$customer" ]; then
        # Take first 10 chars of last name, remove spaces
        local customer_short=$(echo "$customer" | tr -d ' ' | cut -c1-10)
        if [ -n "$folder_name" ]; then
            folder_name="${folder_name}_${customer_short}"
        else
            folder_name="${customer_short}"
        fi
    fi
    
    # Add computer model if provided, otherwise use full volume label
    if [ -n "$computer_model" ]; then
        # Sanitize computer model for filesystem use
        # Keep more meaningful chars but ensure filesystem safety
        local computer_safe=$(echo "$computer_model" | sed 's/[<>:"|?*\/\\]//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
        # Replace spaces with underscores for better readability
        computer_safe=$(echo "$computer_safe" | tr ' ' '_')
        
        # Limit to reasonable length (50 chars) to avoid path issues
        if [ ${#computer_safe} -gt 50 ]; then
            computer_safe="${computer_safe:0:50}"
        fi
        
        if [ -n "$computer_safe" ]; then
            if [ -n "$folder_name" ]; then
                folder_name="${folder_name}_${computer_safe}"
            else
                folder_name="Recovery_$(date +%Y%m%d)_${computer_safe}"
            fi
        else
            # Fallback to drive label if sanitization results in empty string
            local drive_label=$(get_drive_label "$source_device" "$source_mount")
            drive_label=$(echo "$drive_label" | tr ' ' '_')
            if [ -n "$folder_name" ]; then
                folder_name="${folder_name}_${drive_label}"
            else
                folder_name="Recovery_$(date +%Y%m%d)_${drive_label}"
            fi
        fi
    else
        # No computer model, use full drive label
        local drive_label=$(get_drive_label "$source_device" "$source_mount")
        drive_label=$(echo "$drive_label" | tr ' ' '_')
        if [ -n "$folder_name" ]; then
            folder_name="${folder_name}_${drive_label}"
        else
            folder_name="Recovery_$(date +%Y%m%d)_${drive_label}"
        fi
    fi
    
    echo "$folder_name"
}

# Function to check if destination should use subfolder
should_use_subfolder() {
    local dest_path="$1"
    
    # If destination doesn't exist, no subfolder needed
    [ ! -d "$dest_path" ] && echo "no" && return
    
    # Check if destination is empty (ignoring system files)
    local file_count=0
    
    for item in "$dest_path"/*; do
        [ ! -e "$item" ] && continue  # Handle empty directory
        
        local basename=$(basename "$item")
        
        # Skip system files/folders
        case "$basename" in
            "System Volume Information"|".Trash"|".Trashes"|".DS_Store"|"desktop.ini"|"Thumbs.db"|"$RECYCLE.BIN")
                continue
                ;;
        esac
        
        # Found a real file/folder
        ((file_count++))
    done
    
    # If only system files, treat as empty
    if [ $file_count -eq 0 ]; then
        echo "no"
    else
        echo "yes"
    fi
}

# Function to create drive info documentation
create_drive_info_file() {
    local dest_path="$1"
    local source_path="$2"
    local source_device="$3"
    local ticket="$4"
    local customer="$5"
    
    local info_file="$dest_path/DRIVE_INFO.txt"
    
    # Get drive details
    local device_name=$(basename "$source_device")
    local label=$(lsblk -no LABEL "$source_device" 2>/dev/null | head -1)
    local fs_type=$(lsblk -no FSTYPE "$source_device" 2>/dev/null | head -1)
    local size=$(lsblk -no SIZE "$source_device" 2>/dev/null | head -1)
    local model=$(lsblk -no MODEL "$source_device" 2>/dev/null | head -1 | sed 's/ *$//')
    local serial=$(lsblk -no SERIAL "$source_device" 2>/dev/null | head -1)
    
    # Try to get more details with smartctl if available
    local smart_info=""
    if command -v smartctl &> /dev/null; then
        # First try without sudo (some systems allow it)
        smart_info=$(smartctl -i "$source_device" 2>/dev/null)
        
        # If empty or permission denied, skip sudo to avoid interrupting recovery flow
        if [ -z "$smart_info" ] || [[ "$smart_info" =~ "Permission denied" ]]; then
            smart_info=""  # We'll note in the file that sudo is required
        fi
    fi
    
    # Extract just the destination folder name (privacy mode)
    local dest_folder_name=$(basename "$dest_path")
    
    # Get drive identifier for documentation
    local drive_id=$(get_drive_identifier "$source_device" "$source_path")
    
    # Get a display version of the identifier (with periods preserved)
    local drive_id_display=""
    if [ -n "$label" ] && [ "$label" != " " ]; then
        # If we have a label, show the full label
        drive_id_display="$label"
    else
        # If no label, show the actual size value
        drive_id_display="${size:-Unknown}"
    fi
    
    # Create the info file
    cat > "$info_file" << EOF
=====================================
DATA RECOVERY INFORMATION
=====================================
Date: $(date)
Ticket: ${ticket:-Not specified}
Customer: ${customer:-Not specified}
Computer: ${COMPUTER_MODEL:-Not specified}

SOURCE DRIVE INFORMATION
========================
Device: $source_device
Drive Label: ${label:-<no label>}
Drive ID (from label/size): $drive_id_display
Filesystem: ${fs_type:-Unknown}
Size: ${size:-Unknown}
Model: ${model:-Unknown}
Serial: ${serial:-Unknown}

RECOVERY DETAILS
================
Recovery Script Version: 1.9.3
Recovery Mode: $([ "$FILE_TYPE_FILTER" = "yes" ] && echo "File-type filtered" || echo "Full recovery")
$([ "$FILE_TYPE_FILTER" = "yes" ] && echo "File Types: $([ "$FILTER_PICTURES" = "yes" ] && echo "Pictures ")$([ "$FILTER_VIDEOS" = "yes" ] && echo "Videos ")$([ "$FILTER_DOCUMENTS" = "yes" ] && echo "Documents ")$([ "$FILTER_AUDIO" = "yes" ] && echo "Audio")")
Destination Folder: $dest_folder_name
Started: ${SESSION_TIMESTAMP:-$(date)}

SMART INFORMATION (if available)
================================
EOF
    
    # Check if device is a loop device
    if [[ "$source_device" =~ ^/dev/loop ]]; then
        echo "SMART data not available (loop device/mounted image)" >> "$info_file"
    elif [ -n "$smart_info" ]; then
        echo "$smart_info" | grep -E "Model Family:|Device Model:|Serial Number:|User Capacity:|Rotation Rate:|SMART overall-health" >> "$info_file"
    else
        if [ "$EUID" -ne 0 ]; then
            echo "SMART data not available (run recovery with sudo for drive health data)" >> "$info_file"
        else
            echo "SMART data not available" >> "$info_file"
        fi
    fi
    
    cat >> "$info_file" << EOF

NOTES
=====
- Original folder structure preserved
- Check recovery_manifest_*.txt for list of copied files
- Check verification_*.txt for recovery verification results
- Use rsync_recovery.sh --resume to continue if interrupted

EOF
    
    echo -e "${GREEN}Drive information saved to: $info_file${NC}"
}

# Function to determine final destination path
determine_destination_path() {
    local base_dest="$1"
    local source_path="$2"
    local source_device="$3"
    local ticket="$4"
    local customer="$5"
    local computer_model="${6:-}"  # Optional computer model
    
    # Check if we should use a subfolder
    if [ "$(should_use_subfolder "$base_dest")" = "yes" ]; then
        # Generate subfolder name
        local folder_name=$(generate_recovery_folder_name "$ticket" "$customer" "$source_device" "$source_path" "$computer_model")
        local final_dest="$base_dest/$folder_name"
        
        echo -e "${YELLOW}Destination contains files. Creating subfolder: $folder_name${NC}" >&2
        
        # Handle if folder already exists
        if [ -d "$final_dest" ]; then
            echo -e "${YELLOW}Folder already exists. Appending timestamp...${NC}" >&2
            final_dest="${final_dest}_$(date +%H%M%S)"
        fi
        
        mkdir -p "$final_dest"
        echo "$final_dest"
    else
        # Use destination directly
        echo "$base_dest"
    fi
}

# Export functions
export -f get_drive_identifier
export -f get_drive_label
export -f generate_recovery_folder_name
export -f should_use_subfolder
export -f create_drive_info_file
export -f determine_destination_path