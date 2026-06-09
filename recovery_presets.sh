#!/bin/bash

# Recovery Presets Configuration
# Defines priority rules for different customer types

# Function to get preset configuration
get_preset_config() {
    local preset_name="$1"
    
    case "$preset_name" in
        "family")
            echo "PRESET_NAME='Family/Personal Photos & Videos'"
            echo "PRESET_DESCRIPTION='Optimized for family photos, videos, and personal documents'"
            echo "PRIORITY_EXTENSIONS=('jpg' 'jpeg' 'png' 'heic' 'mp4' 'mov' 'avi' 'doc' 'docx' 'pdf')"
            echo "PRIORITY_FOLDERS=('Pictures' 'Photos' 'Videos' 'Documents' 'Desktop' 'Downloads')"
            echo "PRIORITY_PATTERNS=('[0-9]{4}' 'Christmas' 'Birthday' 'Wedding' 'Vacation' 'Holiday')"
            echo "INCLUDE_FOLDERS=('DCIM' 'Camera' 'WhatsApp' 'Screenshots')"
            echo "DEPRIORITIZE_FOLDERS=('Games' 'Steam' 'Program Files')"
            echo "SPECIAL_HANDLING='date_folders_high'"
            ;;
            
        "photographer")
            echo "PRESET_NAME='Photographer/Creative Professional'"
            echo "PRESET_DESCRIPTION='Prioritizes edited exports, project files, then RAW files'"
            echo "PRIORITY_EXTENSIONS=('jpg' 'jpeg' 'png' 'tiff' 'psd' 'lrcat' 'xmp')"
            echo "SECONDARY_EXTENSIONS=('cr2' 'cr3' 'nef' 'arw' 'dng' 'raw')"
            echo "PRIORITY_FOLDERS=('Exports' 'Finals' 'Delivered' 'Clients' 'Portfolio' 'Selects')"
            echo "SECONDARY_FOLDERS=('RAW' 'Originals' 'Shoots' 'Capture')"
            echo "PRIORITY_PATTERNS=('Final' 'Export' 'Output' 'Deliver' 'Print' 'Web')"
            echo "INCLUDE_FOLDERS=('Lightroom' 'CaptureOne' 'Pictures')"
            echo "DEPRIORITIZE_FOLDERS=('Cache' 'Previews' 'Thumbnails' 'Backup')"
            echo "SPECIAL_HANDLING='exports_over_raw'"
            echo "CRITICAL_FILES=('*.lrcat' '*.lrdata' '*.c1catalog' '*.xmp')"
            echo "NOTES='Prioritizes deliverables over source files for faster recovery'"
            ;;
            
        "photographer_raw")
            echo "PRESET_NAME='Photographer - RAW Priority'"
            echo "PRESET_DESCRIPTION='For pros who need original RAW files above all else'"
            echo "PRIORITY_EXTENSIONS=('cr2' 'cr3' 'nef' 'arw' 'dng' 'raw' 'raf' 'orf' 'rw2')"
            echo "SECONDARY_EXTENSIONS=('lrcat' 'xmp' 'psd' 'jpg' 'jpeg')"
            echo "PRIORITY_FOLDERS=('RAW' 'Originals' 'Cards' 'Import' 'Capture')"
            echo "SECONDARY_FOLDERS=('Exports' 'Lightroom' 'Selects')"
            echo "PRIORITY_PATTERNS=('[0-9]{4}' 'RAW' 'Original' 'Master' 'Negative')"
            echo "INCLUDE_FOLDERS=('DCIM' 'EOS_DIGITAL' 'NIKON')"
            echo "DEPRIORITIZE_FOLDERS=('Exports' 'Web' 'Social' 'Low Res')"
            echo "SPECIAL_HANDLING='raw_files_first'"
            echo "CRITICAL_FILES=('*.lrcat' '*.xmp')"
            echo "WARNING='Large files - slower recovery but preserves originals'"
            ;;
            
        "business")
            echo "PRESET_NAME='Business/Office User'"
            echo "PRESET_DESCRIPTION='Focuses on documents, spreadsheets, emails, and business data'"
            echo "PRIORITY_EXTENSIONS=('doc' 'docx' 'xls' 'xlsx' 'pdf' 'pst' 'ost' 'qbw' 'qbb')"
            echo "PRIORITY_FOLDERS=('Documents' 'Desktop' 'QuickBooks' 'Outlook' 'Financial')"
            echo "PRIORITY_PATTERNS=('Invoice' 'Contract' 'Report' 'Financial' 'Tax')"
            echo "INCLUDE_FOLDERS=('ProgramData/Intuit' 'AppData/Local/Microsoft/Outlook')"
            echo "DEPRIORITIZE_FOLDERS=('OneDrive' 'Dropbox' 'Google Drive')"
            echo "SPECIAL_HANDLING='business_databases'"
            echo "CRITICAL_FILES=('*.qbw' '*.pst' '*.accdb' '*.mdb')"
            ;;
            
        "developer")
            echo "PRESET_NAME='Developer/Programmer'"
            echo "PRESET_DESCRIPTION='Prioritizes source code, projects, and development assets'"
            echo "PRIORITY_EXTENSIONS=('js' 'py' 'java' 'cpp' 'cs' 'go' 'rs' 'sql' 'sh')"
            echo "PRIORITY_FOLDERS=('src' 'repos' 'projects' 'workspace' 'git' 'code')"
            echo "PRIORITY_PATTERNS=('proj' 'dev' 'repo' 'source' 'api' 'app')"
            echo "INCLUDE_FOLDERS=('.ssh' '.aws' '.config' 'docker' 'vagrant')"
            echo "DEPRIORITIZE_FOLDERS=('node_modules' 'target' 'build' 'dist' '__pycache__')"
            echo "SPECIAL_HANDLING='include_dotfiles'"
            echo "CRITICAL_FILES=('*.pem' '*.key' '.env' 'id_rsa*')"
            ;;
            
        "gamer")
            echo "PRESET_NAME='Gamer/Content Creator'"
            echo "PRESET_DESCRIPTION='Focuses on game saves, recordings, and streaming content'"
            echo "PRIORITY_EXTENSIONS=('sav' 'save' 'mp4' 'mkv' 'png' 'jpg')"
            echo "PRIORITY_FOLDERS=('Saves' 'SavedGames' 'Recordings' 'Videos' 'Clips')"
            echo "PRIORITY_PATTERNS=('save' 'world' 'character' 'profile' 'replay')"
            echo "INCLUDE_FOLDERS=('Steam/userdata' 'Documents/My Games' 'AppData/LocalLow')"
            echo "DEPRIORITIZE_FOLDERS=('Steam/steamapps/common' 'Downloads')"
            echo "SPECIAL_HANDLING='game_saves'"
            echo "CRITICAL_FOLDERS=('Minecraft/saves' 'Terraria/Worlds')"
            ;;
            
        "student")
            echo "PRESET_NAME='Student/Academic'"
            echo "PRESET_DESCRIPTION='Prioritizes homework, research, and academic materials'"
            echo "PRIORITY_EXTENSIONS=('doc' 'docx' 'pdf' 'ppt' 'pptx' 'txt' 'md' 'tex')"
            echo "PRIORITY_FOLDERS=('Documents' 'Desktop' 'School' 'University' 'Research')"
            echo "PRIORITY_PATTERNS=('hw' 'homework' 'assignment' 'thesis' 'paper' 'notes')"
            echo "INCLUDE_FOLDERS=('Zotero' 'Mendeley' 'OneNote' 'Obsidian')"
            echo "DEPRIORITIZE_FOLDERS=('Games' 'Downloads/torrents')"
            echo "SPECIAL_HANDLING='academic_data'"
            echo "CRITICAL_PATTERNS=('thesis' 'dissertation' 'research')"
            ;;
            
        *)
            # Default balanced preset
            echo "PRESET_NAME='Balanced Recovery'"
            echo "PRESET_DESCRIPTION='General purpose recovery with balanced priorities'"
            echo "PRIORITY_EXTENSIONS=()"
            echo "PRIORITY_FOLDERS=('Documents' 'Pictures' 'Desktop' 'Downloads')"
            echo "PRIORITY_PATTERNS=()"
            echo "INCLUDE_FOLDERS=()"
            echo "DEPRIORITIZE_FOLDERS=()"
            echo "SPECIAL_HANDLING='none'"
            ;;
    esac
}

# Function to apply preset to folder scoring
score_folder_with_preset() {
    local folder="$1"
    local preset="$2"
    local folder_name=$(basename "$folder")
    local score=50  # Base score
    
    # Load preset configuration
    eval "$(get_preset_config "$preset")"
    
    # Score based on folder name matching priority folders
    for priority_folder in "${PRIORITY_FOLDERS[@]}"; do
        if [[ "$folder_name" =~ $priority_folder ]]; then
            score=$((score + 100))
            break
        fi
    done
    
    # Score based on pattern matching
    for pattern in "${PRIORITY_PATTERNS[@]}"; do
        if [[ "$folder_name" =~ $pattern ]]; then
            score=$((score + 50))
            break
        fi
    done
    
    # Check for deprioritized folders
    for depri_folder in "${DEPRIORITIZE_FOLDERS[@]}"; do
        if [[ "$folder_name" =~ $depri_folder ]]; then
            score=$((score - 50))
            break
        fi
    done
    
    # Special handling adjustments
    case "$SPECIAL_HANDLING" in
        "date_folders_high")
            if [[ "$folder_name" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || 
               [[ "$folder_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                score=$((score + 75))
            fi
            ;;
        "catalog_files_critical")
            if [ -f "$folder"/*.lrcat ] || [ -f "$folder"/*.c1catalog ]; then
                score=$((score + 200))  # Critical files found
            fi
            ;;
        "business_databases")
            if [ -f "$folder"/*.qbw ] || [ -f "$folder"/*.pst ]; then
                score=$((score + 150))
            fi
            ;;
    esac
    
    echo "$score"
}

# Function to display preset menu
show_preset_menu() {
    echo "Select Recovery Preset:"
    echo "======================"
    echo ""
    echo "1. Family/Personal        - Photos, videos, and memories"
    echo "2. Photographer (Exports) - Edited photos, deliverables, then RAW"
    echo "3. Photographer (RAW)     - Original RAW files first (slower)"
    echo "4. Business/Office        - Documents, QuickBooks, emails"
    echo "5. Developer              - Source code, git repos, databases"
    echo "6. Gamer/Streamer         - Game saves, recordings, content"
    echo "7. Student/Academic       - Homework, research, thesis"
    echo "8. Balanced (Default)     - General purpose recovery"
    echo ""
    echo -n "Select preset [1-8, default=8]: "
}

# Function to get preset choice
get_preset_choice() {
    local choice="${1:-8}"
    
    case "$choice" in
        1) echo "family" ;;
        2) echo "photographer" ;;
        3) echo "photographer_raw" ;;
        4) echo "business" ;;
        5) echo "developer" ;;
        6) echo "gamer" ;;
        7) echo "student" ;;
        *) echo "balanced" ;;
    esac
}

# Export functions for use in other scripts
export -f get_preset_config
export -f score_folder_with_preset
export -f show_preset_menu
export -f get_preset_choice