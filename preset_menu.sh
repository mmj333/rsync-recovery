#!/bin/bash

# Preset menu functions for rsync_recovery.sh

# Function to show preset menu with custom option
show_enhanced_preset_menu() {
    echo -e "${GREEN}Select Recovery Preset${NC}"
    echo "This will configure the recovery for your specific needs:"
    echo ""
    echo "1. Photos & Videos Only - All media files, photo libraries"
    echo "2. Family/Personal - Photos, videos, personal documents"
    echo "3. Photographer (Exports) - Edited photos first, then RAW"
    echo "4. Photographer (RAW) - Original RAW files first"
    echo "5. Business/Office - Documents, spreadsheets, databases"
    echo "6. Developer - Source code, projects, configs"
    echo "7. Gamer/Streamer - Game saves, recordings, clips"
    echo "8. Student/Academic - Homework, research, notes"
    echo "9. Balanced - General purpose (default)"
    echo "10. Custom - Configure all options manually"
    echo "B. Go back to main menu"
    echo ""
    echo -e "${RED}⚠️  Note: Options 1-2, 4-8 use file-type filtering${NC}"
    echo -e "${RED}   which may take 10+ minutes to scan large drives${NC}"
    echo ""
    echo -n "Select preset [1-10, B]: "
}

# Function to apply preset settings
apply_preset_settings() {
    local preset="$1"
    
    # Default settings
    SKIP_TEMP="yes"
    FILE_TYPE_FILTER="no"
    FILTER_PICTURES="no"
    FILTER_VIDEOS="no"
    FILTER_DOCUMENTS="no"
    FILTER_AUDIO="no"
    INCLUDE_PROGRAMS="no"
    INCLUDE_STEAM="no"
    INCLUDE_EXCLUDED="no"
    FILE_STRUCTURE="easy"
    
    case "$preset" in
        "media")
            echo -e "${YELLOW}Photos & Videos Only preset selected${NC}"
            echo "• All photo and video formats included"
            echo "• iPhoto/Photos libraries and databases included"
            echo "• No documents or other file types"
            echo "• Easy folder organization for media browsing"
            FILE_TYPE_FILTER="yes"
            FILTER_PICTURES="yes"
            FILTER_VIDEOS="yes"
            FILTER_DOCUMENTS="no"
            FILTER_AUDIO="no"
            # Note: Photo library files like .photoslibrary are directories
            # They'll be included because we filter by contents, not extension
            ;;
            
        "family")
            echo -e "${YELLOW}Family/Personal preset selected${NC}"
            echo "• Prioritizing photos, videos, and personal documents"
            echo "• iPhoto/Photos libraries included"
            echo "• Skipping temporary files and caches"
            echo "• Easy folder organization enabled"
            FILE_TYPE_FILTER="yes"
            FILTER_PICTURES="yes"
            FILTER_VIDEOS="yes"
            FILTER_DOCUMENTS="yes"
            ;;
            
        "photographer"|"photographer_raw")
            echo -e "${YELLOW}Photographer preset selected${NC}"
            echo "• Prioritizing photo files and project files"
            echo "• Including RAW formats and editing projects"
            echo "• Keeping original folder structure"
            FILE_TYPE_FILTER="yes"
            FILTER_PICTURES="yes"
            FILE_STRUCTURE="keep"
            ;;
            
        "business")
            echo -e "${YELLOW}Business/Office preset selected${NC}"
            echo "• Prioritizing documents and databases"
            echo "• Including email archives and QuickBooks"
            echo "• Including Program Files for business software"
            FILE_TYPE_FILTER="yes"
            FILTER_DOCUMENTS="yes"
            INCLUDE_PROGRAMS="yes"
            ;;
            
        "developer")
            echo -e "${YELLOW}Developer preset selected${NC}"
            echo "• Including all file types (source code)"
            echo "• Skipping build artifacts and caches"
            echo "• Keeping original structure"
            FILE_TYPE_FILTER="no"
            FILE_STRUCTURE="keep"
            ;;
            
        "gamer")
            echo -e "${YELLOW}Gamer/Streamer preset selected${NC}"
            echo "• Prioritizing game saves and recordings"
            echo "• Including Steam libraries"
            echo "• Videos and screenshots included"
            FILE_TYPE_FILTER="yes"
            FILTER_VIDEOS="yes"
            FILTER_PICTURES="yes"
            INCLUDE_STEAM="yes"
            ;;
            
        "student")
            echo -e "${YELLOW}Student/Academic preset selected${NC}"
            echo "• Prioritizing documents and research"
            echo "• Including notes and presentations"
            echo "• Easy folder organization"
            FILE_TYPE_FILTER="yes"
            FILTER_DOCUMENTS="yes"
            ;;
            
        "balanced"|*)
            echo -e "${YELLOW}Balanced preset selected${NC}"
            echo "• Standard recovery settings"
            echo "• All important data types"
            echo "• Moderate exclusions"
            ;;
    esac
    
    echo ""
}

# Function to show preset summary
show_preset_summary() {
    echo -e "${GREEN}Current Settings:${NC}"
    echo "• Skip temporary files: $SKIP_TEMP"
    if [ "$FILE_TYPE_FILTER" = "yes" ]; then
        echo "• File type filtering: ENABLED"
        [ "$FILTER_PICTURES" = "yes" ] && echo "  - Pictures: YES"
        [ "$FILTER_VIDEOS" = "yes" ] && echo "  - Videos: YES"
        [ "$FILTER_DOCUMENTS" = "yes" ] && echo "  - Documents: YES"
        [ "$FILTER_AUDIO" = "yes" ] && echo "  - Music: YES"
    else
        echo "• File type filtering: DISABLED (all files)"
    fi
    echo "• Include Program Files: $INCLUDE_PROGRAMS"
    echo "• Include Steam libraries: $INCLUDE_STEAM"
    echo "• Include excluded files: $INCLUDE_EXCLUDED"
    echo "• Folder organization: $FILE_STRUCTURE"
    echo ""
}

# Export functions
export -f show_enhanced_preset_menu
export -f apply_preset_settings
export -f show_preset_summary