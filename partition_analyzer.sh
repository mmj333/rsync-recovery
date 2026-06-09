#!/bin/bash

# Partition Analyzer for Rsync Recovery Script
# Provides smart detection and recommendations for source/destination selection
#
# NOTE: Directory scanning is currently disabled to avoid stressing failing drives.
# Analysis is based only on filesystem type, partition labels, and space usage.
# Future enhancement: Add a "healthy drive" mode that enables directory checks.

# Source display utilities if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/partition_display_utils.sh" ]; then
    source "$SCRIPT_DIR/partition_display_utils.sh"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Try to mount a partition
mount_partition() {
    local device="$1"
    local fs_type="$2"
    local fs_label="$3"
    
    # Create a mount point based on label or device name
    local mount_name=""
    if [ -n "$fs_label" ] && [ "$fs_label" != "<no label>" ]; then
        # Use label but sanitize it
        mount_name=$(echo "$fs_label" | sed 's/[^a-zA-Z0-9_-]/_/g')
    else
        # Use device name (e.g., sdb1)
        mount_name=$(basename "$device")
    fi
    
    local mount_point="/media/$USER/$mount_name"
    
    # Create mount point if it doesn't exist
    if [ ! -d "$mount_point" ]; then
        sudo mkdir -p "$mount_point"
    fi
    
    echo "Attempting to mount $device at $mount_point..."
    
    # Try to mount based on filesystem type
    case "$fs_type" in
        ntfs)
            # Use ntfs-3g for NTFS
            sudo mount -t ntfs-3g "$device" "$mount_point" 2>/dev/null || \
            sudo mount -t ntfs "$device" "$mount_point" 2>/dev/null
            ;;
        vfat|fat32|exfat)
            # FAT variants
            sudo mount -t "$fs_type" "$device" "$mount_point" 2>/dev/null
            ;;
        ext[234]|xfs|btrfs)
            # Linux filesystems
            sudo mount -t "$fs_type" "$device" "$mount_point" 2>/dev/null
            ;;
        *)
            # Try auto-detect
            sudo mount "$device" "$mount_point" 2>/dev/null
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Successfully mounted $device at $mount_point${NC}"
        return 0
    else
        echo -e "${RED}Failed to mount $device${NC}"
        # Clean up mount point if empty
        sudo rmdir "$mount_point" 2>/dev/null
        return 1
    fi
}

# Get partition information with usage stats
get_partition_info() {
    local show_all="${1:-no}"  # Whether to show all partitions
    
    # Note: We use lsblk exclusively to avoid blkid's caching issues with hot-swapped drives
    # lsblk reads directly from kernel's current view of devices
    
    # Get all block devices and their mount points
    local partitions=()
    local partition_info=""
    
    # Use lsblk to get partition info
    while IFS= read -r line; do
        # Skip header line
        [[ "$line" =~ ^NAME ]] && continue
        
        # Parse lsblk output
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local type=$(echo "$line" | awk '{print $3}')
        local mountpoint=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | sed 's/^ *//' | sed 's/\\x20/ /g')
        
        # Skip if not a partition, disk, or loop device
        [[ ! "$type" =~ ^(part|disk|loop)$ ]] && continue
        
        # Skip loop devices that are snap packages (they contain /snap/ in mountpoint)
        if [[ "$name" =~ ^loop ]] && [[ "$mountpoint" =~ /snap/ ]]; then
            continue
        fi
        
        # Get filesystem info - using lsblk exclusively to avoid blkid caching issues
        local device="/dev/${name//[├─│└]/}"
        
        # Get filesystem type and label from lsblk (more reliable for hot-swapped drives)
        # Note: lsblk reads from kernel's view which is more up-to-date than blkid's cache
        local fs_info=$(lsblk -no FSTYPE,LABEL "$device" 2>/dev/null | head -1)
        local fs_type=$(echo "$fs_info" | awk '{print $1}')
        local fs_label=$(echo "$fs_info" | awk '{$1=""; print $0}' | sed 's/^ *//')
        
        # For loop devices, lsblk might not show filesystem - check with findmnt
        if [[ "$name" =~ ^loop ]] && [ -z "$fs_type" ] && [ -n "$mountpoint" ]; then
            fs_type=$(findmnt -no FSTYPE "$mountpoint" 2>/dev/null)
            # If we get fuseblk, try to determine actual filesystem type
            if [ "$fs_type" = "fuseblk" ]; then
                # Check if mounted with ntfs-3g by looking at mount process
                if ps aux | grep -q "[m]ount.ntfs.*$device"; then
                    fs_type="ntfs"
                # Check mount source for .bin/.img files (likely NTFS images)
                elif mount | grep "$device" | grep -qE "\.(bin|img|dd|raw)"; then
                    fs_type="ntfs"
                else
                    # Keep as fuseblk but it will work for recovery
                    fs_type="fuseblk"
                fi
            fi
        fi
        
        # If no label from lsblk, we could try other methods but avoid blkid
        if [ -z "$fs_label" ] || [ "$fs_label" = " " ]; then
            fs_label="<no label>"
        fi
        
        # Skip if no filesystem
        [ -z "$fs_type" ] && continue
        
        # Calculate usage if mounted
        local used_percent="N/A"
        local free_space="N/A"
        local total_space="$size"
        
        if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ] && [ "$mountpoint" != "" ]; then
            # Use device instead of mountpoint for df to avoid space issues
            local df_info=$(df -h "$device" 2>/dev/null | tail -1)
            if [ -n "$df_info" ]; then
                used_percent=$(echo "$df_info" | awk '{print $5}')
                free_space=$(echo "$df_info" | awk '{print $4}')
                total_space=$(echo "$df_info" | awk '{print $2}')
            fi
        fi
        
        # Store partition info
        partition_info="${device}|${mountpoint}|${fs_type}|${fs_label}|${total_space}|${free_space}|${used_percent}"
        partitions+=("$partition_info")
        
    done < <(lsblk -rno NAME,SIZE,TYPE,MOUNTPOINT)
    
    # Return partition array
    printf '%s\n' "${partitions[@]}"
}

# Analyze partition for source suitability
analyze_source_partition() {
    local device="$1"
    local mountpoint="$2"
    local fs_type="$3"
    local fs_label="$4"
    local total_space="$5"
    local free_space="$6"
    local used_percent="$7"
    
    local score=0
    local reasons=()
    
    # Check filesystem type
    case "$fs_type" in
        ntfs|exfat|vfat|fat32)
            score=$((score + 20))
            reasons+=("Windows filesystem")
            ;;
        ext4|ext3|ext2|btrfs|xfs)
            score=$((score - 10))
            reasons+=("Linux filesystem")
            ;;
        hfs+|apfs)
            score=$((score + 15))
            reasons+=("Mac filesystem")
            ;;
    esac
    
    # Check if mounted
    if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
        score=$((score + 10))
        
        # TODO: Enable directory scanning when we have a "healthy drive" mode
        # For now, skip directory checks to avoid stressing failing drives
        # 
        # # Check for user data indicators
        # if [ -d "$mountpoint/Users" ] || [ -d "$mountpoint/home" ]; then
        #     score=$((score + 30))
        #     reasons+=("Contains user folders")
        # fi
        # 
        # if [ -d "$mountpoint/Documents" ] || [ -d "$mountpoint/Pictures" ]; then
        #     score=$((score + 20))
        #     reasons+=("Contains data folders")
        # fi
        
        # Check if it's a system partition based on mount point
        if [[ "$mountpoint" == "/" ]] || [[ "$mountpoint" == "/boot" ]] || [[ "$mountpoint" == "/boot/efi" ]]; then
            score=$((score - 50))
            reasons+=("System partition")
        fi
    fi
    
    # Check usage - prefer partitions with data
    if [[ "$used_percent" != "N/A" ]] && [[ "$used_percent" =~ ^[0-9]+% ]]; then
        local used_num=${used_percent%\%}
        # Ensure used_num is numeric
        if [[ "$used_num" =~ ^[0-9]+$ ]]; then
            # Calculate actual used space for better assessment
            local size_in_gb=0
            if [[ "$total_space" =~ ^([0-9.]+)G$ ]]; then
                # Extract just the integer part for bash arithmetic
                local gb_value=${BASH_REMATCH[1]}
                size_in_gb=${gb_value%.*}
                # If no decimal point, use as-is
                [ "$size_in_gb" = "$gb_value" ] && size_in_gb=$gb_value
            elif [[ "$total_space" =~ ^([0-9.]+)T$ ]]; then
                local tb_value=${BASH_REMATCH[1]}
                # Convert TB to GB, using integer math
                local tb_int=${tb_value%.*}
                [ "$tb_int" = "$tb_value" ] && tb_int=$tb_value
                size_in_gb=$((tb_int * 1024))
            elif [[ "$total_space" =~ ^([0-9]+)M$ ]]; then
                # For MB, just use 0 GB
                size_in_gb=0
            fi
            
            local used_gb=0
            if [ "$size_in_gb" -gt 0 ]; then
                used_gb=$((size_in_gb * used_num / 100))
            fi
            
            # Better scoring based on actual data amount
            if [ "$used_gb" -gt 20 ]; then
                score=$((score + 20))
                reasons+=("Contains significant data (${used_percent} = ~${used_gb}GB)")
            elif [ "$used_gb" -gt 5 ]; then
                score=$((score + 10))
                reasons+=("Has some data (${used_percent} = ~${used_gb}GB)")
            elif [ "$used_num" -le 5 ]; then
                score=$((score - 10))
                reasons+=("Minimal data (${used_percent})")
            fi
            
            # Over 95% full might be problematic
            if [ "$used_num" -gt 95 ]; then
                score=$((score - 10))
                reasons+=("Nearly full")
            fi
        fi
    fi
    
    # Check label for hints
    if [[ "$fs_label" =~ ^CPR_Backup$ ]]; then
        # CPR_Backup drives are specifically for destinations
        score=$((score - 50))
        reasons+=("CPR backup destination drive")
        # Extra penalty if mostly empty
        if [[ "$used_num" =~ ^[0-9]+$ ]] && [ "$used_num" -lt 20 ]; then
            score=$((score - 20))
            reasons+=("Empty backup drive")
        fi
    elif [[ "${fs_label,,}" =~ (backup.drive|recovery.drive|backup.hdd|backup.disk) ]]; then
        score=$((score - 30))
        reasons+=("Backup destination drive")
    elif [[ "$fs_label" =~ ^OS$ ]] || [[ "$fs_label" =~ ^(Windows|Win[0-9]+)$ ]]; then
        score=$((score + 15))
        reasons+=("OS/System drive")
    elif [[ "$fs_label" =~ (data|storage|documents|media) ]]; then
        score=$((score + 10))
        reasons+=("Data-related label")
    elif [[ "${fs_label,,}" =~ backup ]]; then
        # Generic backup label - might be source or dest
        score=$((score + 0))
        reasons+=("Has backup label")
    fi
    
    # System partition labels - strong negative score for exact matches
    if [[ "$fs_label" =~ ^(ESP|EFI|DIAGS|WINRETOOLS|System.Volume|SYSTEM.VOLUME|Recovery|RECOVERY|DELLUTILITY|DellUtility|HP_TOOLS|HP_RECOVERY|LENOVO_PART|SYSTEM_DRV)$ ]]; then
        score=$((score - 100))
        reasons+=("Known system partition")
    # Common patterns in system partition names (case insensitive)
    elif [[ "${fs_label,,}" =~ (winre|win.?re|system.*volume|efi.*system|diagnostics|diags) ]]; then
        score=$((score - 80))
        reasons+=("Likely system partition")
    # General system-related keywords
    elif [[ "${fs_label,,}" =~ (system|boot|recovery|esp|restore) ]]; then
        score=$((score - 30))
        reasons+=("System-related label")
    fi
    
    # Special handling for small partitions with "recovery-like" names
    if [[ "$total_space" =~ ^[0-9]+[MG]$ ]] && [[ "${fs_label,,}" =~ (image|tools|utility|service) ]]; then
        local size_value="${total_space%[MG]}"
        local size_unit="${total_space: -1}"
        if [[ "$size_unit" == "M" ]] || [[ "$size_unit" == "G" && "$size_value" -lt 20 ]]; then
            score=$((score - 40))
            reasons+=("Small partition with utility name")
        fi
    fi
    
    # Check size - very small partitions are likely system
    if [[ "$total_space" =~ ^[0-9]+M$ ]]; then
        local size_mb=${total_space%M}
        if [ "$size_mb" -lt 1000 ]; then  # Less than 1GB
            score=$((score - 50))
            reasons+=("Too small for user data (<1GB)")
        fi
    elif [[ "$total_space" =~ ^[0-9.]+G$ ]]; then
        local size_gb=${total_space%G}
        # Use bc for float comparison or convert to integer
        if [ "${size_gb%.*}" -lt 10 ]; then  # Less than 10GB
            score=$((score - 20))
            reasons+=("Small partition (<10GB)")
        fi
    fi
    
    # Ensure score is numeric before returning
    [[ ! "$score" =~ ^-?[0-9]+$ ]] && score=0
    echo "$score|$(IFS=', '; echo "${reasons[*]}")"
}

# Analyze partition for destination suitability
analyze_destination_partition() {
    local device="$1"
    local mountpoint="$2"
    local fs_type="$3"
    local fs_label="$4"
    local total_space="$5"
    local free_space="$6"
    local used_percent="$7"
    
    local score=0
    local reasons=()
    
    # Check filesystem type - prefer cross-platform filesystems
    case "$fs_type" in
        ntfs|exfat)
            score=$((score + 20))
            reasons+=("Cross-platform filesystem")
            ;;
        ext4|ext3|btrfs|xfs)
            score=$((score + 10))
            reasons+=("Native Linux filesystem")
            ;;
        vfat|fat32)
            score=$((score - 10))
            reasons+=("Limited filesystem (4GB file limit)")
            ;;
        hfsplus|hfs)
            score=$((score - 30))
            reasons+=("⚠️ Mac HFS+ - Linux write unreliable")
            ;;
        apfs)
            score=$((score - 50))
            reasons+=("❌ Mac APFS - No Linux write support")
            ;;
    esac
    
    # Must be mounted to be a destination
    if [ -z "$mountpoint" ] || [ "$mountpoint" = " " ]; then
        score=$((score - 100))
        reasons+=("Not mounted")
    else
        # Check if it's a system partition
        if [[ "$mountpoint" == "/" ]] || [[ "$mountpoint" == "/boot" ]] || [[ "$mountpoint" == "/boot/efi" ]]; then
            score=$((score - 50))
            reasons+=("System partition")
        fi
        
        # Check free space
        if [[ "$used_percent" != "N/A" ]] && [[ "$used_percent" =~ ^[0-9]+% ]]; then
            local used_num=${used_percent%\%}
            # Ensure used_num is numeric
            if [[ "$used_num" =~ ^[0-9]+$ ]]; then
                if [ "$used_num" -lt 50 ]; then
                    score=$((score + 30))
                    reasons+=("Plenty of space (${used_percent} used)")
                elif [ "$used_num" -lt 80 ]; then
                    score=$((score + 10))
                    reasons+=("Some space available")
                else
                    score=$((score - 20))
                    reasons+=("Limited space (${used_percent} used)")
                fi
            fi
        fi
    fi
    
    # Check label for hints
    if [[ "$fs_label" =~ ^CPR_Backup$ ]]; then
        score=$((score + 50))
        reasons+=("CPR backup drive")
    elif [[ "$fs_label" =~ (backup|data|storage) ]] && ! [[ "$fs_label" =~ (PBR.Image|WINRETOOLS|Recovery) ]]; then
        score=$((score + 30))
        reasons+=("Backup/storage label")
    fi
    
    # System partition labels - strong negative score for exact matches
    if [[ "$fs_label" =~ ^(ESP|EFI|DIAGS|WINRETOOLS|System.Volume|SYSTEM.VOLUME|Recovery|RECOVERY|DELLUTILITY|DellUtility|HP_TOOLS|HP_RECOVERY|LENOVO_PART|SYSTEM_DRV)$ ]]; then
        score=$((score - 100))
        reasons+=("Known system partition")
    # Common patterns in system partition names
    elif [[ "${fs_label,,}" =~ (winre|win.?re|system.*volume|efi.*system|diagnostics|diags) ]]; then
        score=$((score - 80))
        reasons+=("Likely system partition")
    elif [[ "${fs_label,,}" =~ (system|boot|esp|restore) ]]; then
        score=$((score - 30))
        reasons+=("System label")
    fi
    
    # Don't use small utility partitions for destination
    if [[ "$total_space" =~ ^[0-9]+[MG]$ ]] && [[ "${fs_label,,}" =~ (image|tools|utility|service) ]]; then
        local size_value="${total_space%[MG]}"
        local size_unit="${total_space: -1}"
        if [[ "$size_unit" == "M" ]] || [[ "$size_unit" == "G" && "$size_value" -lt 20 ]]; then
            score=$((score - 40))
            reasons+=("Small utility partition")
        fi
    fi
    
    # Check size for destinations too
    if [[ "$total_space" =~ ^[0-9]+M$ ]]; then
        local size_mb=${total_space%M}
        if [ "$size_mb" -lt 1000 ]; then  # Less than 1GB
            score=$((score - 50))
            reasons+=("Too small (<1GB)")
        fi
    fi
    
    # TODO: Enable directory scanning when we have a "healthy drive" mode
    # # Check for existing recovery folders
    # if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
    #     if [ -d "$mountpoint/Recovery" ] || [ -d "$mountpoint/Recovered_Data" ]; then
    #         score=$((score + 10))
    #         reasons+=("Has recovery folders")
    #     fi
    # fi
    
    # Ensure score is numeric before returning
    [[ ! "$score" =~ ^-?[0-9]+$ ]] && score=0
    echo "$score|$(IFS=', '; echo "${reasons[*]}")"
}

# Show source selection menu
show_source_menu() {
    echo -e "${GREEN}Available Source Locations${NC}"
    echo "=" | sed 's/.*/===============================================/'
    
    # Check if we have sudo for SMART data
    if [ "$EUID" -eq 0 ] && command -v smartctl &> /dev/null; then
        echo -e "${CYAN}SMART health data will be collected for selected drive${NC}"
        echo ""
    fi
    
    local partitions=()
    local scores=()
    local index=0
    
    # Get and analyze all partitions
    while IFS= read -r partition_info; do
        [ -z "$partition_info" ] && continue
        
        IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "$partition_info"
        
        # Analyze source suitability
        local analysis=$(analyze_source_partition "$device" "$mountpoint" "$fs_type" "$fs_label" "$total_space" "$free_space" "$used_percent")
        IFS='|' read -r score reasons <<< "$analysis"
        
        partitions+=("$partition_info")
        scores+=("$score|$reasons")
        index=$((index + 1))
    done < <(get_partition_info)
    
    # Sort by score (highest first)
    local sorted_indices=()
    for i in "${!scores[@]}"; do
        sorted_indices+=("$i")
    done
    
    # Bubble sort by score
    local n=${#sorted_indices[@]}
    for ((i = 0; i < n - 1; i++)); do
        for ((j = 0; j < n - i - 1; j++)); do
            local idx1=${sorted_indices[j]}
            local idx2=${sorted_indices[j+1]}
            local score1=$(echo "${scores[idx1]}" | cut -d'|' -f1)
            local score2=$(echo "${scores[idx2]}" | cut -d'|' -f1)
            
            # Validate scores are numeric
            [[ ! "$score1" =~ ^-?[0-9]+$ ]] && score1=0
            [[ ! "$score2" =~ ^-?[0-9]+$ ]] && score2=0
            
            if [ "$score1" -lt "$score2" ]; then
                sorted_indices[j]=$idx2
                sorted_indices[j+1]=$idx1
            fi
        done
    done
    
    # Display sorted partitions
    local display_index=1
    local recommended_shown=false
    local DISPLAYED_PARTITIONS=()
    
    for idx in "${sorted_indices[@]}"; do
        IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "${partitions[idx]}"
        IFS='|' read -r score reasons <<< "${scores[idx]}"
        
        # Validate score is numeric
        [[ ! "$score" =~ ^-?[0-9]+$ ]] && score=0
        
        # Skip system partitions and very low scoring partitions
        if [ "$score" -lt -50 ]; then
            continue  # Definitely skip system partitions
        elif [ "$score" -lt -20 ] && [[ "$used_percent" == "N/A" || "${used_percent%\%}" -lt 5 ]]; then
            continue  # Skip other low-scoring empty partitions
        fi
        
        # Show recommendation for highest scoring partition
        if [ "$recommended_shown" = false ] && [ "$score" -gt 20 ]; then
            echo -e "${CYAN}RECOMMENDED:${NC}"
            recommended_shown=true
        fi
        
        # Format display
        echo -e "${YELLOW}[$display_index]${NC} $device"
        echo "    Label: ${fs_label:-<no label>}"
        # Use enhanced formatting if available
        if command -v format_size_display &> /dev/null; then
            echo "    Type: $fs_type | $(format_size_display "$total_space" "$used_percent" "$free_space")"
        else
            echo "    Type: $fs_type | Size: $total_space | Used: ${used_percent:-N/A}"
        fi
        if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
            echo "    Mount: $mountpoint"
        else
            echo "    Mount: <not mounted>"
        fi
        
        # Show analysis reasons
        if [ "$score" -gt 20 ]; then
            echo -e "    ${GREEN}✓ $reasons${NC}"
        elif [ "$score" -lt -20 ]; then
            echo -e "    ${RED}✗ $reasons${NC}"
        else
            echo "    → $reasons"
        fi
        echo ""
        
        # Track this partition for selection
        DISPLAYED_PARTITIONS+=("${partitions[idx]}")
        
        display_index=$((display_index + 1))
    done
    
    # Add manual entry option
    echo -e "${YELLOW}[$display_index]${NC} Enter path manually"
    echo ""
    
    # Export the display count for the caller
    export PARTITION_MENU_COUNT=$display_index
    
    # Export the displayed partitions array
    # We'll write them to a temp file since arrays can't be exported
    local temp_file="/tmp/rsync_displayed_partitions_$$"
    printf '%s\n' "${DISPLAYED_PARTITIONS[@]}" > "$temp_file"
}

# Show destination selection menu
show_destination_menu() {
    local estimated_size="${1:-Unknown}"
    local source_device="${2:-}"  # Device to exclude from destination list
    
    echo -e "${GREEN}Available Destination Locations${NC}"
    echo "Estimated data size: $estimated_size"
    echo "=" | sed 's/.*/===============================================/'
    
    local partitions=()
    local scores=()
    local index=0
    
    # Get and analyze all partitions
    while IFS= read -r partition_info; do
        [ -z "$partition_info" ] && continue
        
        IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "$partition_info"
        
        # Skip if this is the source device
        if [ -n "$source_device" ] && [ "$device" = "$source_device" ]; then
            continue
        fi
        
        # Analyze destination suitability
        local analysis=$(analyze_destination_partition "$device" "$mountpoint" "$fs_type" "$fs_label" "$total_space" "$free_space" "$used_percent")
        IFS='|' read -r score reasons <<< "$analysis"
        
        partitions+=("$partition_info")
        scores+=("$score|$reasons")
        index=$((index + 1))
    done < <(get_partition_info)
    
    # Sort by score (highest first)
    local sorted_indices=()
    for i in "${!scores[@]}"; do
        sorted_indices+=("$i")
    done
    
    # Bubble sort by score
    local n=${#sorted_indices[@]}
    for ((i = 0; i < n - 1; i++)); do
        for ((j = 0; j < n - i - 1; j++)); do
            local idx1=${sorted_indices[j]}
            local idx2=${sorted_indices[j+1]}
            local score1=$(echo "${scores[idx1]}" | cut -d'|' -f1)
            local score2=$(echo "${scores[idx2]}" | cut -d'|' -f1)
            
            # Validate scores are numeric
            [[ ! "$score1" =~ ^-?[0-9]+$ ]] && score1=0
            [[ ! "$score2" =~ ^-?[0-9]+$ ]] && score2=0
            
            if [ "$score1" -lt "$score2" ]; then
                sorted_indices[j]=$idx2
                sorted_indices[j+1]=$idx1
            fi
        done
    done
    
    # Display sorted partitions
    local display_index=1
    local recommended_shown=false
    local DISPLAYED_PARTITIONS=()
    local unmounted_backup_shown=false
    
    # First pass: show mounted partitions
    for idx in "${sorted_indices[@]}"; do
        IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "${partitions[idx]}"
        IFS='|' read -r score reasons <<< "${scores[idx]}"
        
        # Skip unmounted partitions in first pass
        if [ -z "$mountpoint" ] || [ "$mountpoint" = " " ]; then
            continue
        fi
        
        # Skip very low scores (system partitions, etc.)
        if [ "$score" -lt -50 ]; then
            continue
        fi
        
        # Show recommendation for highest scoring partition
        if [ "$recommended_shown" = false ] && [ "$score" -gt 30 ]; then
            echo -e "${CYAN}RECOMMENDED:${NC}"
            recommended_shown=true
        fi
        
        # Format display
        echo -e "${YELLOW}[$display_index]${NC} $device → $mountpoint"
        echo "    Label: ${fs_label:-<no label>}"
        # Use enhanced formatting if available
        if command -v format_size_display &> /dev/null; then
            echo "    Type: $fs_type | $(format_size_display "$total_space" "$used_percent" "$free_space")"
        else
            echo "    Type: $fs_type | Size: $total_space | Free: ${free_space:-N/A}"
        fi
        
        # Show analysis reasons
        if [ "$score" -gt 30 ]; then
            echo -e "    ${GREEN}✓ $reasons${NC}"
        elif [ "$score" -lt -20 ]; then
            echo -e "    ${RED}✗ $reasons${NC}"
        else
            echo "    → $reasons"
        fi
        echo ""
        
        # Track this partition for selection
        DISPLAYED_PARTITIONS+=("${partitions[idx]}")
        
        display_index=$((display_index + 1))
    done
    
    # Second pass: show unmounted partitions that look like backup drives
    if [ "$unmounted_backup_shown" = false ]; then
        local unmounted_found=false
        for idx in "${sorted_indices[@]}"; do
            IFS='|' read -r device mountpoint fs_type fs_label total_space free_space used_percent <<< "${partitions[idx]}"
            IFS='|' read -r score reasons <<< "${scores[idx]}"
            
            # Only process unmounted partitions
            if [ -n "$mountpoint" ] && [ "$mountpoint" != " " ]; then
                continue
            fi
            
            # Check if this looks like a backup drive
            if [[ "$fs_label" =~ (CPR_Backup|backup|Backup|BACKUP|recovery|Recovery|data|Data|storage|Storage) ]] && 
               [[ "$fs_type" =~ (ntfs|exfat|ext[234]|btrfs|xfs) ]]; then
                
                if [ "$unmounted_found" = false ]; then
                    echo -e "${CYAN}UNMOUNTED BACKUP DRIVES (can be mounted):${NC}"
                    unmounted_found=true
                fi
                
                echo -e "${YELLOW}[$display_index]${NC} $device [UNMOUNTED - Mount and use]"
                echo "    Label: ${fs_label:-<no label>}"
                # Unmounted drives don't have usage info
                if command -v format_size_display &> /dev/null; then
                    echo "    Type: $fs_type | $(format_size_display "$total_space" "N/A" "N/A")"
                else
                    echo "    Type: $fs_type | Size: $total_space"
                fi
                echo -e "    ${BLUE}→ Will mount to /media/$USER/${NC}"
                echo ""
                
                # Track this partition for selection
                DISPLAYED_PARTITIONS+=("${partitions[idx]}")
                display_index=$((display_index + 1))
            fi
        done
    fi
    
    # Add manual entry option
    echo -e "${YELLOW}[$display_index]${NC} Enter path manually"
    echo -e "${YELLOW}[$((display_index + 1))]${NC} Create new folder on existing partition"
    echo ""
    
    # Export the display count for the caller (including the two extra options)
    export PARTITION_MENU_COUNT=$((display_index + 1))
    
    # Export the displayed partitions array for destination
    local temp_file="/tmp/rsync_displayed_dest_partitions_$$"
    printf '%s\n' "${DISPLAYED_PARTITIONS[@]}" > "$temp_file"
}

# Export functions for use in main script
export -f get_partition_info
export -f analyze_source_partition
export -f analyze_destination_partition
export -f show_source_menu
export -f show_destination_menu
export -f mount_partition