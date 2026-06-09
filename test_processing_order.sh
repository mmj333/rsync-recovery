#!/bin/bash
# Test script to show processing order for a given source

if [ $# -eq 0 ]; then
    echo "Usage: $0 <source_path>"
    echo "Shows the order in which folders would be processed"
    exit 1
fi

source="$1"

# Colors
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Analyzing folder structure of: $source"
echo "======================================"
echo ""

# Arrays to categorize folders
priority_folders=()
backup_folders=()
normal_folders=()
system_folders=()
recycle_folders=()
root_files=()

# Windows system folders
windows_system_folders=("Windows" "Program Files" "Program Files (x86)" "ProgramData" "PerfLogs" "Intel" "AMD" "\$Recycle.Bin" "System Volume Information" "Recovery" "Documents and Settings" "\$Windows.~BT" "\$Windows.~WS" "Windows.old")

# First check for Users folder
if [ -d "$source/Users" ]; then
    echo -e "${GREEN}Found Users folder - would process first with user prioritization${NC}"
    echo ""
fi

# Categorize all items at root
for item in "$source"/*; do
    if [ -f "$item" ]; then
        root_files+=("$item")
    elif [ -d "$item" ] && [ ! -L "$item" ]; then
        dirname=$(basename "$item")
        
        # Skip Users (already noted above)
        if [ "$dirname" = "Users" ]; then
            continue
        fi
        
        # Check for $RECYCLE.BIN or RECYCLER
        if [[ "$dirname" == '$RECYCLE.BIN' ]] || [[ "$dirname" == "RECYCLER" ]] || [[ "$dirname" == '$Recycle.Bin' ]]; then
            recycle_folders+=("$item")
            continue
        fi
        
        # Check if it's a system folder
        is_system=false
        for sys_folder in "${windows_system_folders[@]}"; do
            if [ "$dirname" = "$sys_folder" ]; then
                is_system=true
                system_folders+=("$item")
                break
            fi
        done
        
        if [ "$is_system" = true ]; then
            continue
        fi
        
        # Check if it's a priority folder
        if [[ "$dirname" =~ (Documents|Pictures|Photos|Videos|Music) ]] || 
           [ -d "$item/Documents" ] || [ -d "$item/Pictures" ] || [ -d "$item/Photos" ]; then
            priority_folders+=("$item")
        # Check if it's a backup folder
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

# Show processing order
echo -e "${YELLOW}Phase 1: Priority user folders${NC}"
if [ ${#priority_folders[@]} -gt 0 ]; then
    for folder in "${priority_folders[@]}"; do
        echo "  - $(basename "$folder")"
    done
else
    echo "  (none found)"
fi

echo ""
echo -e "${YELLOW}Phase 2: Root-level files${NC}"
if [ ${#root_files[@]} -gt 0 ]; then
    echo "  - ${#root_files[@]} files found"
else
    echo "  (none found)"
fi

echo ""
echo -e "${YELLOW}Phase 3: Backup/dated folders${NC}"
if [ ${#backup_folders[@]} -gt 0 ]; then
    for folder in "${backup_folders[@]}"; do
        dirname=$(basename "$folder")
        if [ -d "$folder/Users" ]; then
            echo "  - $dirname (contains Users folder)"
        else
            echo "  - $dirname"
        fi
    done
else
    echo "  (none found)"
fi

echo ""
echo -e "${YELLOW}Phase 4: Other folders${NC}"
if [ ${#normal_folders[@]} -gt 0 ]; then
    for folder in "${normal_folders[@]}"; do
        echo "  - $(basename "$folder")"
    done
else
    echo "  (none found)"
fi

echo ""
echo -e "${YELLOW}Phase 5: System folders (would be skipped in normal mode)${NC}"
if [ ${#system_folders[@]} -gt 0 ]; then
    for folder in "${system_folders[@]}"; do
        echo "  - $(basename "$folder")"
    done
else
    echo "  (none found)"
fi

echo ""
echo -e "${YELLOW}Phase 6: Recycle bin (only copied in 'Copy Everything' mode)${NC}"
if [ ${#recycle_folders[@]} -gt 0 ]; then
    for folder in "${recycle_folders[@]}"; do
        echo "  - $(basename "$folder")"
    done
else
    echo "  (none found)"
fi

echo ""
echo "======================================"
echo "This is the order folders would be processed in v1.4.0"