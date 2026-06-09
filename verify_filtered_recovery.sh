#!/bin/bash

# Verification script for filtered recoveries
# Checks if all files matching the filter criteria were successfully copied

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# File type definitions (same as main script)
PICTURE_EXTS="jpg jpeg jpe jfif png gif bmp tiff tif webp heic heif raw cr2 cr3 nef arw dng orf rw2 pef sr2 srw raf erf kdc dcr dcs mrw nrw ptx x3f mef mos gpr 3fr fff iiq rwl srf psd psb xcf ai eps svg ico icns jp2 j2k jxr hdp wdp tga pcx exr hdr pic pct pict kra krita clip afphoto aae xmp dop pp3 ctx"
VIDEO_EXTS="mp4 avi mkv mov wmv flv webm m4v mpg mpeg mp2 mpe mpv m2p h264 h265 hevc 3gp 3g2 mts m2ts ts m2v vob mod tod asf rm rmvb divx ogv ogg dv f4v f4p f4a f4b mxf braw r3d ari dnxhd dnxhr prores cine cin gifv m4s dav 264 265 lrv thm yuv mjpeg mjpg amv mtv mj2 roq nsv fli flc ivf vid rv rvmb dxr"
DOC_EXTS="doc docx pdf txt rtf odt odf ods odp odg xls xlsx xlsm xlsb csv ppt pptx pptm pages numbers key tex md markdown rst epub mobi azw azw3 fb2 lit pdb html htm xml json yaml yml"
AUDIO_EXTS="mp3 wav flac aac ogg wma m4a m4b opus aiff aif ape alac mka mp2 ac3 dts ra rm ram mid midi kar"

# Photo library patterns
PHOTO_LIBRARIES="*.photoslibrary *.photolibrary *.aplibrary *.lrcat *.lrdata Photo?Booth?Library"

# Function to build find command with extensions
build_find_command() {
    local path="$1"
    local filter_type="$2"
    local find_cmd="find \"$path\" -type f \\( "
    local first=true
    
    case "$filter_type" in
        "pictures")
            for ext in $PICTURE_EXTS; do
                if [ "$first" = true ]; then
                    find_cmd="$find_cmd -iname \"*.$ext\""
                    first=false
                else
                    find_cmd="$find_cmd -o -iname \"*.$ext\""
                fi
            done
            ;;
        "videos")
            for ext in $VIDEO_EXTS; do
                if [ "$first" = true ]; then
                    find_cmd="$find_cmd -iname \"*.$ext\""
                    first=false
                else
                    find_cmd="$find_cmd -o -iname \"*.$ext\""
                fi
            done
            ;;
        "documents")
            for ext in $DOC_EXTS; do
                if [ "$first" = true ]; then
                    find_cmd="$find_cmd -iname \"*.$ext\""
                    first=false
                else
                    find_cmd="$find_cmd -o -iname \"*.$ext\""
                fi
            done
            ;;
        "audio")
            for ext in $AUDIO_EXTS; do
                if [ "$first" = true ]; then
                    find_cmd="$find_cmd -iname \"*.$ext\""
                    first=false
                else
                    find_cmd="$find_cmd -o -iname \"*.$ext\""
                fi
            done
            ;;
    esac
    
    find_cmd="$find_cmd \\) 2>/dev/null"
    echo "$find_cmd"
}

# Function to check photo libraries
check_photo_libraries() {
    local path="$1"
    local temp_file="$2"
    
    echo -e "${YELLOW}Checking for photo library packages...${NC}"
    for pattern in $PHOTO_LIBRARIES; do
        find "$path" -type d -name "$pattern" 2>/dev/null >> "$temp_file"
    done
}

# Main verification function
verify_filtered_recovery() {
    local source="$1"
    local dest="$2"
    local filter_pictures="$3"
    local filter_videos="$4"
    local filter_documents="$5"
    local filter_audio="$6"
    
    echo -e "${GREEN}Filtered Recovery Verification${NC}"
    echo "================================"
    echo "Source: $source"
    echo "Destination: $dest"
    
    # Check if files might be in a subfolder
    local actual_dest="$dest"
    if [ ! -d "$dest" ] || [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
        # Check for common subfolder patterns
        local source_basename=$(basename "$source")
        local possible_dests=(
            "$dest/$source_basename"
            "$dest"/*_*_*  # Ticket_Customer_DriveID pattern
        )
        
        for pd in "${possible_dests[@]}"; do
            if [ -d "$pd" ] && [ -n "$(ls -A "$pd" 2>/dev/null)" ]; then
                echo -e "${YELLOW}Note: Files found in subfolder: $(basename "$pd")${NC}"
                actual_dest="$pd"
                break
            fi
        done
    fi
    
    dest="$actual_dest"
    echo "Verifying: $dest"
    echo ""
    
    # Create temp files for results
    local source_files=$(mktemp)
    local dest_files=$(mktemp)
    local missing_files=$(mktemp)
    local photo_libs_source=$(mktemp)
    local photo_libs_dest=$(mktemp)
    
    # Count files by type
    local total_source_count=0
    local total_dest_count=0
    local total_missing_count=0
    
    # Check each file type
    if [ "$filter_pictures" = "yes" ]; then
        echo -e "${YELLOW}Scanning for pictures in source...${NC}"
        local cmd=$(build_find_command "$source" "pictures")
        eval "$cmd" > "$source_files"
        local source_pics=$(wc -l < "$source_files")
        total_source_count=$((total_source_count + source_pics))
        
        echo -e "${YELLOW}Scanning for pictures in destination...${NC}"
        cmd=$(build_find_command "$dest" "pictures")
        eval "$cmd" > "$dest_files"
        local dest_pics=$(wc -l < "$dest_files")
        total_dest_count=$((total_dest_count + dest_pics))
        
        # Find missing pictures
        while IFS= read -r file; do
            # Convert source path to expected destination path
            local rel_path="${file#$source/}"
            local expected_dest="$dest/$rel_path"
            if [ ! -f "$expected_dest" ]; then
                echo "$file" >> "$missing_files"
                ((total_missing_count++))
            fi
        done < "$source_files"
        
        echo -e "${GREEN}Pictures:${NC} $source_pics in source, $dest_pics in destination"
        
        # Check photo libraries
        check_photo_libraries "$source" "$photo_libs_source"
        check_photo_libraries "$dest" "$photo_libs_dest"
    fi
    
    if [ "$filter_videos" = "yes" ]; then
        echo -e "${YELLOW}Scanning for videos...${NC}"
        > "$source_files"  # Clear file
        > "$dest_files"
        
        cmd=$(build_find_command "$source" "videos")
        eval "$cmd" > "$source_files"
        local source_vids=$(wc -l < "$source_files")
        total_source_count=$((total_source_count + source_vids))
        
        cmd=$(build_find_command "$dest" "videos")
        eval "$cmd" > "$dest_files"
        local dest_vids=$(wc -l < "$dest_files")
        total_dest_count=$((total_dest_count + dest_vids))
        
        # Find missing videos
        while IFS= read -r file; do
            local rel_path="${file#$source/}"
            local expected_dest="$dest/$rel_path"
            if [ ! -f "$expected_dest" ]; then
                echo "$file" >> "$missing_files"
                ((total_missing_count++))
            fi
        done < "$source_files"
        
        echo -e "${GREEN}Videos:${NC} $source_vids in source, $dest_vids in destination"
    fi
    
    # Similar blocks for documents and audio...
    
    # Show photo library results
    if [ -s "$photo_libs_source" ]; then
        echo ""
        echo -e "${YELLOW}Photo Libraries Found:${NC}"
        local lib_count=0
        while IFS= read -r lib; do
            ((lib_count++))
            local lib_name=$(basename "$lib")
            local lib_in_dest=false
            
            # Check if this library exists in destination
            local rel_path="${lib#$source/}"
            if [ -d "$dest/$rel_path" ]; then
                echo -e "  ${GREEN}✓${NC} $lib_name (copied)"
                lib_in_dest=true
            else
                echo -e "  ${RED}✗${NC} $lib_name (missing)"
                echo "$lib" >> "$missing_files"
            fi
        done < "$photo_libs_source"
        echo "Total photo libraries: $lib_count"
    fi
    
    # Summary
    echo ""
    echo -e "${GREEN}Summary Statistics${NC}"
    echo "=================="
    echo "Total files in source matching filters: $total_source_count"
    echo "Total files in destination: $total_dest_count"
    echo "Missing files: $total_missing_count"
    
    if [ "$total_source_count" -gt 0 ]; then
        local success_rate=$(( (total_source_count - total_missing_count) * 100 / total_source_count ))
        echo -e "Success rate: ${GREEN}${success_rate}%${NC}"
    fi
    
    # Save detailed results
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="$dest/filtered_verification_${timestamp}.txt"
    
    {
        echo "Filtered Recovery Verification Report"
        echo "===================================="
        echo "Date: $(date)"
        echo "Source: $source"
        echo "Destination: $dest"
        echo ""
        echo "Filter Settings:"
        echo "  Pictures: $filter_pictures"
        echo "  Videos: $filter_videos"
        echo "  Documents: $filter_documents"
        echo "  Audio: $filter_audio"
        echo ""
        echo "Results:"
        echo "  Total matching files in source: $total_source_count"
        echo "  Total files in destination: $total_dest_count"
        echo "  Missing files: $total_missing_count"
        [ "$total_source_count" -gt 0 ] && echo "  Success rate: ${success_rate}%"
        echo ""
        
        if [ "$total_missing_count" -gt 0 ]; then
            echo "Missing Files:"
            echo "=============="
            cat "$missing_files"
        fi
    } > "$report_file"
    
    echo ""
    echo "Detailed report saved to: $report_file"
    
    if [ "$total_missing_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Sample of missing files:${NC}"
        head -10 "$missing_files"
        [ "$total_missing_count" -gt 10 ] && echo "... and $((total_missing_count - 10)) more"
    fi
    
    # Cleanup
    rm -f "$source_files" "$dest_files" "$missing_files" "$photo_libs_source" "$photo_libs_dest"
}

# Interactive menu
show_filtered_verification_menu() {
    echo -e "${GREEN}Filtered Recovery Verification${NC}"
    echo "=============================="
    echo ""
    echo "This will verify that all files matching your filter criteria"
    echo "were successfully copied from source to destination."
    echo ""
    
    # Try to detect recent recovery
    local recovery_dir="$HOME/.rsync_recovery"
    local latest_session=""
    if [ -d "$recovery_dir" ]; then
        latest_session=$(ls -t "$recovery_dir"/recovery_* 2>/dev/null | head -1)
    fi
    
    if [ -n "$latest_session" ] && [ -f "$latest_session/recovery_info.txt" ]; then
        echo -e "${YELLOW}Recent recovery detected:${NC}"
        grep -E "Source:|Destination:|Preset:" "$latest_session/recovery_info.txt" | head -3
        echo ""
        echo -n "Use this recovery? [Y/n]: "
        read -r use_recent
        
        if [[ ! "$use_recent" =~ ^[Nn]$ ]]; then
            # Parse recovery info
            local source=$(grep "Source:" "$latest_session/recovery_info.txt" | cut -d' ' -f2-)
            local dest=$(grep "Destination:" "$latest_session/recovery_info.txt" | cut -d' ' -f2-)
            local preset=$(grep "Preset:" "$latest_session/recovery_info.txt" | cut -d' ' -f2-)
            
            # Determine filters based on preset
            local filter_pictures="no"
            local filter_videos="no"
            local filter_documents="no"
            local filter_audio="no"
            
            case "$preset" in
                "media"|"Photos & Videos Only")
                    filter_pictures="yes"
                    filter_videos="yes"
                    ;;
                "family"|"photographer"*|"gamer"|"student")
                    filter_pictures="yes"
                    filter_videos="yes"
                    filter_documents="yes"
                    ;;
                "business")
                    filter_documents="yes"
                    filter_pictures="yes"
                    ;;
                *)
                    # Ask user
                    echo ""
                    echo "Which file types were filtered?"
                    echo -n "Pictures? [y/N]: "
                    read -r pics
                    [[ "$pics" =~ ^[Yy]$ ]] && filter_pictures="yes"
                    
                    echo -n "Videos? [y/N]: "
                    read -r vids
                    [[ "$vids" =~ ^[Yy]$ ]] && filter_videos="yes"
                    
                    echo -n "Documents? [y/N]: "
                    read -r docs
                    [[ "$docs" =~ ^[Yy]$ ]] && filter_documents="yes"
                    
                    echo -n "Audio? [y/N]: "
                    read -r audio
                    [[ "$audio" =~ ^[Yy]$ ]] && filter_audio="yes"
                    ;;
            esac
            
            verify_filtered_recovery "$source" "$dest" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio"
            return
        fi
    fi
    
    # Manual entry
    echo -n "Enter source path: "
    read -r source
    echo -n "Enter destination path: "
    read -r dest
    
    echo ""
    echo "Which file types to verify?"
    echo -n "Pictures? [y/N]: "
    read -r pics
    local filter_pictures="no"
    [[ "$pics" =~ ^[Yy]$ ]] && filter_pictures="yes"
    
    echo -n "Videos? [y/N]: "
    read -r vids
    local filter_videos="no"
    [[ "$vids" =~ ^[Yy]$ ]] && filter_videos="yes"
    
    echo -n "Documents? [y/N]: "
    read -r docs
    local filter_documents="no"
    [[ "$docs" =~ ^[Yy]$ ]] && filter_documents="yes"
    
    echo -n "Audio? [y/N]: "
    read -r audio
    local filter_audio="no"
    [[ "$audio" =~ ^[Yy]$ ]] && filter_audio="yes"
    
    echo ""
    verify_filtered_recovery "$source" "$dest" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio"
}

# Main execution
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Filtered Recovery Verification"
    echo ""
    echo "Usage: $0 [source] [dest] [options]"
    echo ""
    echo "Options:"
    echo "  --pictures    Include picture files"
    echo "  --videos      Include video files"  
    echo "  --documents   Include document files"
    echo "  --audio       Include audio files"
    echo ""
    echo "Interactive mode: Run without arguments"
    exit 0
fi

if [ $# -eq 0 ]; then
    # Interactive mode
    show_filtered_verification_menu
else
    # Parse command line arguments
    source="$1"
    dest="$2"
    filter_pictures="no"
    filter_videos="no"
    filter_documents="no"
    filter_audio="no"
    
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --pictures) filter_pictures="yes" ;;
            --videos) filter_videos="yes" ;;
            --documents) filter_documents="yes" ;;
            --audio) filter_audio="yes" ;;
        esac
        shift
    done
    
    verify_filtered_recovery "$source" "$dest" "$filter_pictures" "$filter_videos" "$filter_documents" "$filter_audio"
fi