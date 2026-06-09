#!/bin/bash

# Unified Recovery Verification Script
# Automatically detects filtered vs full recovery and verifies accordingly
# Supports both manual execution and integration with recovery workflow

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# File type definitions - Updated with new extensions
PICTURE_EXTS="jpg jpeg jpe jfif png gif bmp tiff tif webp heic heif raw cr2 cr3 nef arw dng orf rw2 pef sr2 srw raf erf kdc dcr dcs mrw nrw ptx x3f mef mos gpr 3fr fff iiq rwl srf psd psb xcf ai eps svg ico icns jp2 j2k jxr hdp wdp tga pcx exr hdr pic pct pict kra krita clip afphoto aae xmp dop pp3 ctx arq rw1"
VIDEO_EXTS="mp4 avi mkv mov wmv flv webm m4v mpg mpeg mp2 mpe mpv m2p h264 h265 hevc 3gp 3g2 mts m2ts ts m2v vob mod tod asf rm rmvb divx ogv ogg dv f4v f4p f4a f4b mxf braw r3d ari dnxhd dnxhr prores cine cin gifv m4s dav 264 265 lrv thm yuv mjpeg mjpg amv mtv mj2 roq nsv fli flc ivf vid rv rvmb dxr mpg4 m4p qt"
DOC_EXTS="doc docx pdf txt rtf odt odf ods odp odg xls xlsx xlsm xlsb csv ppt pptx pptm pages numbers key tex md markdown rst epub mobi azw azw3 fb2 lit pdb html htm xml json yaml yml docm xlam one wpd"
AUDIO_EXTS="mp3 wav flac aac ogg wma m4a m4b opus aiff aif ape alac mka mp2 ac3 dts ra rm ram mid midi kar"

# Photo library and management software patterns
PHOTO_LIBRARIES="*.photoslibrary *.photolibrary *.aplibrary *.lrcat *.lrdata Photo?Booth?Library"
PHOTO_SOFTWARE_PATTERNS="*.lmnr *.luminar *.on1 *.on1pho *.dop *.dopdata"

# Exclude patterns (same as rsync recovery)
TEMP_EXCLUDE_PATTERNS=(
    "Temporary Internet Files"
    "*/Cache/*"
    "*/cache/*"
    "*/Caches/*"
    "*/tmp/*"
    "*/temp/*"
    "*/Temp/*"
    "*/Library/Caches/*"
    "*/Library/Logs/*"
    "*/Library/Application Support/*/Cache*"
    "*/AppData/Local/Temp/*"
    "*/AppData/Local/Microsoft/Windows/WebCache/*"
    "*/AppData/Local/Microsoft/Windows/INetCache/*"
    "*/Google/Chrome/User Data/*/Cache*"
    "*/Mozilla/Firefox/Profiles/*/cache*"
    "*/Microsoft/Edge/User Data/*/Cache*"
    ".Spotlight-V100"
    ".Trashes"
    ".fseventsd"
    "\$RECYCLE.BIN"
    "System Volume Information"
)

# System folders to potentially exclude
SYSTEM_FOLDERS=(
    "Windows"
    "Program Files"
    "Program Files (x86)"
    "ProgramData"
    "PerfLogs"
    "\$Recycle.Bin"
    "\$RECYCLE.BIN"
    "RECYCLER"
    "System Volume Information"
    "Recovery"
    "Documents and Settings"
    "\$Windows.~BT"
    "\$Windows.~WS"
    "Windows.old"
    "Intel"
    "AMD"
)

usage() {
    echo "Usage: $0 <source> <destination> [options]"
    echo ""
    echo "Verification Options:"
    echo "  --quick              Quick mode - only check existence (default)"
    echo "  --size               Check file sizes match"
    echo "  --checksum           Full checksum verification (slowest)"
    echo "  --exclude-system     Exclude system folders from report"
    echo "  --summary            Only show summary, not individual files"
    echo ""
    echo "Filter Options (auto-detected from recovery settings if available):"
    echo "  --filter-pictures    Verify only picture files"
    echo "  --filter-videos      Verify only video files"
    echo "  --filter-documents   Verify only document files"
    echo "  --filter-audio       Verify only audio files"
    echo "  --no-filter          Force full verification (ignore saved filters)"
    echo ""
    echo "Settings:"
    echo "  --settings <file>    Load filter settings from recovery file"
    echo ""
    echo "Examples:"
    echo "  $0 /media/source /media/dest --size --exclude-system"
    echo "  $0 /media/source /media/dest --filter-pictures --filter-videos"
    echo "  $0 /media/source /media/dest --settings ~/.rsync_recovery/recovery_20240101_120000"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

SOURCE="$1"
DEST="$2"
shift 2

# Default options
CHECK_MODE="quick"
EXCLUDE_SYSTEM=false
SUMMARY_ONLY=false
FILTER_MODE=""
# Only set filter defaults if not already set (e.g., from environment)
FILTER_PICTURES="${FILTER_PICTURES:-no}"
FILTER_VIDEOS="${FILTER_VIDEOS:-no}"
FILTER_DOCUMENTS="${FILTER_DOCUMENTS:-no}"
FILTER_AUDIO="${FILTER_AUDIO:-no}"
SETTINGS_FILE=""
FORCE_NO_FILTER=false

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        --quick)
            CHECK_MODE="quick"
            ;;
        --size)
            CHECK_MODE="size"
            ;;
        --checksum)
            CHECK_MODE="checksum"
            ;;
        --exclude-system)
            EXCLUDE_SYSTEM=true
            ;;
        --summary)
            SUMMARY_ONLY=true
            ;;
        --filter-pictures)
            FILTER_PICTURES="yes"
            FILTER_MODE="filtered"
            ;;
        --filter-videos)
            FILTER_VIDEOS="yes"
            FILTER_MODE="filtered"
            ;;
        --filter-documents)
            FILTER_DOCUMENTS="yes"
            FILTER_MODE="filtered"
            ;;
        --filter-audio)
            FILTER_AUDIO="yes"
            FILTER_MODE="filtered"
            ;;
        --no-filter)
            FORCE_NO_FILTER=true
            ;;
        --settings)
            shift
            SETTINGS_FILE="$1"
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# Function to find recovery settings for source/dest pair
find_recovery_settings() {
    local source="$1"
    local dest="$2"
    local recovery_dir="$HOME/.rsync_recovery"
    
    # Search for matching recovery in recent files
    if [ -d "$recovery_dir" ]; then
        for settings_file in $(ls -t "$recovery_dir"/recovery_* 2>/dev/null | head -20); do
            if [ -f "$settings_file" ]; then
                # Source the file in a subshell to avoid polluting current environment
                local matched="$(
                    source "$settings_file" 2>/dev/null
                    if [[ "$SOURCE_PATH" == "$source" ]] && [[ "$DEST_PATH" == "$dest" || "$FINAL_DEST_PATH" == "$dest" ]]; then
                        echo "$settings_file"
                    fi
                )"
                if [ -n "$matched" ]; then
                    echo "$matched"
                    return 0
                fi
            fi
        done
    fi
    return 1
}

# Auto-detection logic
if [ "$FORCE_NO_FILTER" != true ] && [ -z "$FILTER_MODE" ]; then
    # First check if settings file was provided
    if [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ]; then
        source "$SETTINGS_FILE" 2>/dev/null
    # Then check environment variables (set by rsync_recovery.sh)
    elif [ "$FILE_TYPE_FILTER" = "yes" ]; then
        # Filter variables should already be in environment from recovery menu
        # Don't override them if they're already set
        : # Variables should already be exported from recovery menu
    # Finally try to auto-detect from recovery settings
    else
        if settings_file="$(find_recovery_settings "$SOURCE" "$DEST")"; then
            echo -e "${YELLOW}Found recovery settings: $(basename "$settings_file")${NC}"
            source "$settings_file"
        fi
    fi
    
    # Set filter mode if filters were used
    if [ "$FILE_TYPE_FILTER" = "yes" ]; then
        FILTER_MODE="filtered"
        # Filter variables should already be set from environment or sourced file
    fi
fi

# Verify source and destination exist
if [ ! -d "$SOURCE" ]; then
    echo -e "${RED}Error: Source directory does not exist: $SOURCE${NC}"
    exit 1
fi

if [ ! -d "$DEST" ]; then
    echo -e "${RED}Error: Destination directory does not exist: $DEST${NC}"
    exit 1
fi

# Check if files might be in a subfolder (for filtered recoveries)
ACTUAL_DEST="$DEST"
if [ "$FILTER_MODE" = "filtered" ]; then
    if [ ! -d "$DEST" ] || [ -z "$(ls -A "$DEST" 2>/dev/null)" ]; then
        # Check for common subfolder patterns
        source_basename="$(basename "$SOURCE")"
        possible_dests=(
            "$DEST/$source_basename"
            "$DEST"/*_*_*  # Ticket_Customer_DriveID pattern
        )
        
        for pd in "${possible_dests[@]}"; do
            if [ -d "$pd" ] && [ -n "$(ls -A "$pd" 2>/dev/null)" ]; then
                echo -e "${YELLOW}Note: Files found in subfolder: $(basename "$pd")${NC}"
                ACTUAL_DEST="$pd"
                break
            fi
        done
    fi
fi

# Check if files have been reorganized
REORGANIZED=false
if [ -f "$ACTUAL_DEST/REORGANIZATION_INFO.txt" ]; then
    REORGANIZED=true
    echo -e "${YELLOW}Note: Files have been reorganized for easy access${NC}"
fi

# Create output files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Extract recovery folder name from destination path
RECOVERY_FOLDER_NAME=$(basename "$ACTUAL_DEST")
# Check if it looks like a recovery folder (contains ticket number and customer name)
if [[ "$RECOVERY_FOLDER_NAME" =~ ^[0-9]+_.*$ ]]; then
    # Use recovery folder name as prefix
    FILE_PREFIX="${RECOVERY_FOLDER_NAME}_"
else
    # Not a recovery folder, use no prefix
    FILE_PREFIX=""
fi

MISSING_LOG="$ACTUAL_DEST/verification_missing_${FILE_PREFIX}${TIMESTAMP}.txt"
DIFFERENT_LOG="$ACTUAL_DEST/verification_different_${FILE_PREFIX}${TIMESTAMP}.txt"
SUMMARY_LOG="$ACTUAL_DEST/verification_summary_${FILE_PREFIX}${TIMESTAMP}.txt"

# Initialize counters
TOTAL_SOURCE_FILES=0
TOTAL_SOURCE_DIRS=0
MISSING_FILES=0
MISSING_DIRS=0
DIFFERENT_FILES=0
VERIFIED_FILES=0
PHOTO_LIBS_SOURCE=0
PHOTO_LIBS_MISSING=0

# Display header
echo "Recovery Verification Report"
echo "Recovery Verification Report" > "$SUMMARY_LOG"
echo "==========================="
echo "===========================" >> "$SUMMARY_LOG"
echo "Date: $(date)"
echo "Date: $(date)" >> "$SUMMARY_LOG"
echo ""
echo "" >> "$SUMMARY_LOG"
echo -e "${YELLOW}Verification Settings:${NC}"
echo "Verification Settings:" >> "$SUMMARY_LOG"
echo "  Source: $(basename "$SOURCE")"
echo "  Source: $(basename "$SOURCE")" >> "$SUMMARY_LOG"
echo "  Destination: $(basename "$ACTUAL_DEST")"
echo "  Destination: $(basename "$ACTUAL_DEST")" >> "$SUMMARY_LOG"

if [ "$FILTER_MODE" = "filtered" ]; then
    # Display with color on terminal, save without color to file
    echo -n "  File types: "
    echo -n "  File types: " >> "$SUMMARY_LOG"
    
    # Count active filters to check if any are displayed
    filter_count=0
    filter_list=""
    
    [ "$FILTER_PICTURES" = "yes" ] && { filter_list="${filter_list}Pictures "; ((filter_count++)); }
    [ "$FILTER_VIDEOS" = "yes" ] && { filter_list="${filter_list}Videos "; ((filter_count++)); }
    [ "$FILTER_DOCUMENTS" = "yes" ] && { filter_list="${filter_list}Documents "; ((filter_count++)); }
    [ "$FILTER_AUDIO" = "yes" ] && { filter_list="${filter_list}Audio "; ((filter_count++)); }
    
    if [ $filter_count -gt 0 ]; then
        # Remove trailing space
        filter_list="${filter_list% }"
        echo "$filter_list"
        echo "$filter_list" >> "$SUMMARY_LOG"
    else
        echo "(No active filters detected)"
        echo "(No active filters detected)" >> "$SUMMARY_LOG"
    fi
else
    echo "  File types: All"
    echo "  File types: All" >> "$SUMMARY_LOG"
fi

# Always show system folder setting
echo -n "  System folders: "
echo -n "  System folders: " >> "$SUMMARY_LOG"
if [ "$EXCLUDE_SYSTEM" = true ]; then
    echo "Excluded"
    echo "Excluded" >> "$SUMMARY_LOG"
else
    echo "Included"
    echo "Included" >> "$SUMMARY_LOG"
fi
echo "  Check mode: $CHECK_MODE"
echo "  Check mode: $CHECK_MODE" >> "$SUMMARY_LOG"
echo ""
echo "" >> "$SUMMARY_LOG"

# Function to check if path contains system folder
is_system_path() {
    local path="$1"
    if [ "$EXCLUDE_SYSTEM" = true ]; then
        for sys_folder in "${SYSTEM_FOLDERS[@]}"; do
            if [[ "$path" =~ /$sys_folder/ ]] || [[ "$path" =~ /$sys_folder$ ]]; then
                return 0
            fi
        done
    fi
    return 1
}

# Function to check if path should be excluded (temp/cache)
is_excluded_path() {
    local path="$1"
    
    # Check against exclude patterns
    for pattern in "${TEMP_EXCLUDE_PATTERNS[@]}"; do
        # Handle different pattern types
        case "$pattern" in
            */*)
                # Pattern with wildcards
                if [[ "$path" == *${pattern//\*/}* ]]; then
                    return 0
                fi
                ;;
            *)
                # Direct folder name
                if [[ "$path" =~ /$pattern/ ]] || [[ "$path" =~ /$pattern$ ]]; then
                    return 0
                fi
                ;;
        esac
    done
    
    return 1
}

# Function to get relative path
get_relative_path() {
    local full_path="$1"
    local base_path="$2"
    echo "${full_path#$base_path/}"
}

# Function to check if file matches filter
matches_filter() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"  # Convert to lowercase
    
    # If no filters are active in filtered mode, skip all files
    if [ "$FILTER_MODE" = "filtered" ]; then
        if [ "$FILTER_PICTURES" != "yes" ] && [ "$FILTER_VIDEOS" != "yes" ] && 
           [ "$FILTER_DOCUMENTS" != "yes" ] && [ "$FILTER_AUDIO" != "yes" ]; then
            return 1
        fi
    else
        # In full mode, all files match
        return 0
    fi
    
    # Check each filter type
    if [ "$FILTER_PICTURES" = "yes" ]; then
        for pic_ext in $PICTURE_EXTS; do
            [ "$ext" = "$pic_ext" ] && return 0
        done
    fi
    
    if [ "$FILTER_VIDEOS" = "yes" ]; then
        for vid_ext in $VIDEO_EXTS; do
            [ "$ext" = "$vid_ext" ] && return 0
        done
    fi
    
    if [ "$FILTER_DOCUMENTS" = "yes" ]; then
        for doc_ext in $DOC_EXTS; do
            [ "$ext" = "$doc_ext" ] && return 0
        done
    fi
    
    if [ "$FILTER_AUDIO" = "yes" ]; then
        for aud_ext in $AUDIO_EXTS; do
            [ "$ext" = "$aud_ext" ] && return 0
        done
    fi
    
    return 1
}

# Function to check individual file
check_file() {
    local src_file="$1"
    local rel_path="$(get_relative_path "$src_file" "$SOURCE")"
    local dest_file="$ACTUAL_DEST/$rel_path"
    
    TOTAL_SOURCE_FILES=$((TOTAL_SOURCE_FILES + 1))
    
    # Skip system files if requested
    if is_system_path "$rel_path"; then
        return
    fi
    
    # Skip excluded paths (temp/cache)
    if is_excluded_path "$rel_path"; then
        return
    fi
    
    # Check if file matches filter (if in filter mode)
    if ! matches_filter "$src_file"; then
        return
    fi
    
    # If reorganized, check alternative locations
    if [ "$REORGANIZED" = true ] && [ ! -f "$dest_file" ]; then
        # Try different reorganized paths
        if [[ "$rel_path" =~ ^Users/[^/]+/(.+)$ ]]; then
            # User file might be moved to root
            local alt_path="${BASH_REMATCH[1]}"
            dest_file="$ACTUAL_DEST/$alt_path"
        elif [[ ! "$rel_path" =~ ^Users/ ]]; then
            # System file might be in "Other files"
            dest_file="$ACTUAL_DEST/Other files/$rel_path"
        fi
    fi
    
    if [ ! -f "$dest_file" ]; then
        MISSING_FILES=$((MISSING_FILES + 1))
        if [ "$SUMMARY_ONLY" = false ]; then
            echo "$rel_path" >> "$MISSING_LOG"
        fi
        return
    fi
    
    # Check based on mode
    case "$CHECK_MODE" in
        size)
            local src_size="$(stat -c%s "$src_file" 2>/dev/null || stat -f%z "$src_file" 2>/dev/null)"
            local dest_size="$(stat -c%s "$dest_file" 2>/dev/null || stat -f%z "$dest_file" 2>/dev/null)"
            if [ "$src_size" != "$dest_size" ]; then
                DIFFERENT_FILES=$((DIFFERENT_FILES + 1))
                if [ "$SUMMARY_ONLY" = false ]; then
                    echo "$rel_path (size: $src_size vs $dest_size)" >> "$DIFFERENT_LOG"
                fi
            else
                VERIFIED_FILES=$((VERIFIED_FILES + 1))
            fi
            ;;
        checksum)
            local src_sum="$(md5sum "$src_file" 2>/dev/null | cut -d' ' -f1)"
            local dest_sum="$(md5sum "$dest_file" 2>/dev/null | cut -d' ' -f1)"
            if [ "$src_sum" != "$dest_sum" ]; then
                DIFFERENT_FILES=$((DIFFERENT_FILES + 1))
                if [ "$SUMMARY_ONLY" = false ]; then
                    echo "$rel_path (checksum mismatch)" >> "$DIFFERENT_LOG"
                fi
            else
                VERIFIED_FILES=$((VERIFIED_FILES + 1))
            fi
            ;;
        *)
            VERIFIED_FILES=$((VERIFIED_FILES + 1))
            ;;
    esac
}

# Function to check directory
check_directory() {
    local src_dir="$1"
    local rel_path="$(get_relative_path "$src_dir" "$SOURCE")"
    local dest_dir="$ACTUAL_DEST/$rel_path"
    
    # Skip if it's a symlink
    if [ -L "$src_dir" ]; then
        return
    fi
    
    TOTAL_SOURCE_DIRS=$((TOTAL_SOURCE_DIRS + 1))
    
    # Skip system directories if requested
    if is_system_path "$rel_path"; then
        return
    fi
    
    # In filter mode, we don't track missing directories unless they're photo libraries
    if [ "$FILTER_MODE" != "filtered" ]; then
        if [ ! -d "$dest_dir" ]; then
            MISSING_DIRS=$((MISSING_DIRS + 1))
            if [ "$SUMMARY_ONLY" = false ]; then
                echo "DIR: $rel_path/" >> "$MISSING_LOG"
            fi
        fi
    fi
}

# Function to check photo libraries (for filtered mode)
check_photo_libraries() {
    if [ "$FILTER_MODE" = "filtered" ] && [ "$FILTER_PICTURES" = "yes" ]; then
        echo -e "${YELLOW}Checking for photo library packages...${NC}"
        
        for pattern in $PHOTO_LIBRARIES $PHOTO_SOFTWARE_PATTERNS; do
            while IFS= read -r -d '' lib; do
                PHOTO_LIBS_SOURCE=$((PHOTO_LIBS_SOURCE + 1))
                local rel_path="$(get_relative_path "$lib" "$SOURCE")"
                local expected_dest="$ACTUAL_DEST/$rel_path"
                
                if [ ! -e "$expected_dest" ]; then
                    PHOTO_LIBS_MISSING=$((PHOTO_LIBS_MISSING + 1))
                    if [ "$SUMMARY_ONLY" = false ]; then
                        echo "PHOTO_LIB: $rel_path" >> "$MISSING_LOG"
                    fi
                fi
            done < <(find "$SOURCE" -name "$pattern" -print0 2>/dev/null)
        done
        
        if [ $PHOTO_LIBS_SOURCE -gt 0 ]; then
            echo "Found $PHOTO_LIBS_SOURCE photo libraries/packages"
        fi
    fi
}

# Progress indicator
PROGRESS_COUNT=0
show_progress() {
    PROGRESS_COUNT=$((PROGRESS_COUNT + 1))
    if [ $((PROGRESS_COUNT % 100)) -eq 0 ]; then
        echo -ne "\rProcessed $PROGRESS_COUNT items..."
    fi
}

# Main verification loop
echo -e "${YELLOW}Starting verification...${NC}"

# First check photo libraries if in filter mode
check_photo_libraries

# Use find to traverse all files and directories
while IFS= read -r -d '' item; do
    if [ -f "$item" ]; then
        check_file "$item"
    elif [ -d "$item" ]; then
        check_directory "$item"
    fi
    show_progress
done < <(find "$SOURCE" -mindepth 1 -print0 2>/dev/null)

echo -e "\r${GREEN}Verification complete!${NC}"
echo ""

# Calculate statistics
if [ "$FILTER_MODE" = "filtered" ]; then
    # For filtered mode, we only count files that match the filter
    TOTAL_ITEMS=$VERIFIED_FILES
    MISSING_ITEMS=$MISSING_FILES
    if [ $PHOTO_LIBS_SOURCE -gt 0 ]; then
        TOTAL_ITEMS=$((TOTAL_ITEMS + PHOTO_LIBS_SOURCE))
        MISSING_ITEMS=$((MISSING_ITEMS + PHOTO_LIBS_MISSING))
    fi
else
    # For full mode, count everything
    TOTAL_ITEMS=$((TOTAL_SOURCE_FILES + TOTAL_SOURCE_DIRS))
    MISSING_ITEMS=$((MISSING_FILES + MISSING_DIRS))
fi

SUCCESS_RATE=0
if [ $TOTAL_ITEMS -gt 0 ]; then
    SUCCESS_RATE="$(echo "scale=2; ($TOTAL_ITEMS - $MISSING_ITEMS - $DIFFERENT_FILES) * 100 / $TOTAL_ITEMS" | bc)"
fi

# Generate summary - separate color output from file output
echo ""
echo "" >> "$SUMMARY_LOG"
echo "Summary Statistics"
echo "Summary Statistics" >> "$SUMMARY_LOG"
echo "=================="
echo "==================" >> "$SUMMARY_LOG"

if [ "$FILTER_MODE" = "filtered" ]; then
    echo "Files matching filters: $TOTAL_ITEMS"
    echo "Files matching filters: $TOTAL_ITEMS" >> "$SUMMARY_LOG"
    echo "Missing files: $MISSING_FILES"
    echo "Missing files: $MISSING_FILES" >> "$SUMMARY_LOG"
    if [ $PHOTO_LIBS_SOURCE -gt 0 ]; then
        echo "Photo libraries: $PHOTO_LIBS_SOURCE"
        echo "Photo libraries: $PHOTO_LIBS_SOURCE" >> "$SUMMARY_LOG"
        echo "Missing libraries: $PHOTO_LIBS_MISSING"
        echo "Missing libraries: $PHOTO_LIBS_MISSING" >> "$SUMMARY_LOG"
    fi
else
    echo "Total source items: $TOTAL_ITEMS"
    echo "Total source items: $TOTAL_ITEMS" >> "$SUMMARY_LOG"
    echo "  Files: $TOTAL_SOURCE_FILES"
    echo "  Files: $TOTAL_SOURCE_FILES" >> "$SUMMARY_LOG"
    echo "  Directories: $TOTAL_SOURCE_DIRS"
    echo "  Directories: $TOTAL_SOURCE_DIRS" >> "$SUMMARY_LOG"
    echo ""
    echo "" >> "$SUMMARY_LOG"
    echo "Missing items: $MISSING_ITEMS"
    echo "Missing items: $MISSING_ITEMS" >> "$SUMMARY_LOG"
    echo "  Files: $MISSING_FILES"
    echo "  Files: $MISSING_FILES" >> "$SUMMARY_LOG"
    echo "  Directories: $MISSING_DIRS"
    echo "  Directories: $MISSING_DIRS" >> "$SUMMARY_LOG"
fi

if [ "$CHECK_MODE" != "quick" ]; then
    echo ""
    echo "" >> "$SUMMARY_LOG"
    echo "Different files: $DIFFERENT_FILES"
    echo "Different files: $DIFFERENT_FILES" >> "$SUMMARY_LOG"
    echo "Verified files: $VERIFIED_FILES"
    echo "Verified files: $VERIFIED_FILES" >> "$SUMMARY_LOG"
fi

echo ""
echo "" >> "$SUMMARY_LOG"
echo "Success rate: ${SUCCESS_RATE}%"
echo "Success rate: ${SUCCESS_RATE}%" >> "$SUMMARY_LOG"

if [ "$EXCLUDE_SYSTEM" = true ] && [ "$FILTER_MODE" != "filtered" ]; then
    echo ""
    echo "" >> "$SUMMARY_LOG"
    echo "Note: System folders were excluded from this report"
    echo "Note: System folders were excluded from this report" >> "$SUMMARY_LOG"
fi

echo ""
echo "" >> "$SUMMARY_LOG"
echo "Note: Temporary and cache files are automatically excluded from verification"
echo "Note: Temporary and cache files are automatically excluded from verification" >> "$SUMMARY_LOG"
echo "      (matching the recovery script's exclusion patterns)"
echo "      (matching the recovery script's exclusion patterns)" >> "$SUMMARY_LOG"

# Show file locations
echo ""
echo "Report files saved to:"
echo "  Summary: $SUMMARY_LOG"
if [ -s "$MISSING_LOG" ]; then
    echo "  Missing items: $MISSING_LOG"
fi
if [ -s "$DIFFERENT_LOG" ]; then
    echo "  Different files: $DIFFERENT_LOG"
fi

# Provide recommendations
if [ $MISSING_FILES -gt 0 ] || [ $MISSING_DIRS -gt 0 ] || [ $PHOTO_LIBS_MISSING -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recommendations:${NC}"
    echo "- Review $MISSING_LOG to see what wasn't copied"
    if [ "$FILTER_MODE" = "filtered" ]; then
        echo "- Note: Only files matching your filters were checked"
    fi
    echo "- Run rsync_recovery.sh again with --resume to copy missing items"
    echo "- Check folder_summary.txt in destination for excluded folders"
fi

# Clean up empty log files
[ ! -s "$MISSING_LOG" ] && rm -f "$MISSING_LOG"
[ ! -s "$DIFFERENT_LOG" ] && rm -f "$DIFFERENT_LOG"

exit 0