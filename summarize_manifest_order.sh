#!/bin/bash

# Simple script to show folder processing order from manifest

if [ $# -eq 0 ]; then
    echo "Usage: $0 <manifest_file>"
    exit 1
fi

manifest="$1"

echo "Recovery Manifest Analysis"
echo "========================="
echo "Total files: $(wc -l < "$manifest")"
echo ""

# Show first appearance of major folders
echo "Major Folder First Appearance:"
echo "------------------------------"

# Function to find and display folder timing
check_folder() {
    local pattern="$1"
    local name="$2"
    local line=$(grep -n -m1 "$pattern" "$manifest" 2>/dev/null | cut -d: -f1)
    if [ -n "$line" ]; then
        printf "%-20s line %7d (%.1f%%)\n" "$name:" "$line" $(echo "scale=1; $line * 100 / $(wc -l < "$manifest")" | bc)
    else
        printf "%-20s NOT FOUND\n" "$name:"
    fi
}

# Check key folders
check_folder "/Users/" "Users folder"
check_folder "/Pictures/" "Pictures"
check_folder "/Documents/" "Documents"  
check_folder "/Desktop/" "Desktop"
check_folder "/Downloads/" "Downloads"
check_folder "/Videos/" "Videos"
check_folder "/Music/" "Music"
check_folder "/AppData/" "AppData"
check_folder "/Up/" "Up folder"
check_folder "/Program Files/" "Program Files"
check_folder "/Windows/" "Windows"

echo ""
echo "Top-Level Folder Order (first 20 unique folders):"
echo "-------------------------------------------------"

# Extract top-level folders in order of appearance
awk -F'/' 'NF > 5 && !seen[$5]++ { print NR ": /" $5 "/" }' "$manifest" | head -20

echo ""
echo "Folder Size Summary (files per folder):"
echo "--------------------------------------"

# Count files per top-level folder
awk -F'/' 'NF > 5 { count[$5]++ } 
END { 
    for (f in count) 
        printf "%-30s %6d files\n", f, count[f] 
}' "$manifest" | sort -k2 -nr | head -20