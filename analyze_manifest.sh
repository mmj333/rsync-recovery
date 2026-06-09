#!/bin/bash

# Script to analyze recovery manifest and show folder copy order
# Shows unique folders in the order they were first copied

if [ $# -eq 0 ]; then
    echo "Usage: $0 <manifest_file>"
    echo "Analyzes recovery manifest to show folder copy order"
    exit 1
fi

manifest_file="$1"

if [ ! -f "$manifest_file" ]; then
    echo "Error: File not found: $manifest_file"
    exit 1
fi

echo "Analyzing manifest: $manifest_file"
echo "Total files: $(wc -l < "$manifest_file")"
echo ""
echo "Folder Copy Order:"
echo "=================="

# Extract unique folders in order of first appearance
# This preserves the order folders were processed
awk -F'/' '{
    # Build the folder path progressively
    path = ""
    for (i = 1; i < NF; i++) {
        if (i == 1) {
            path = $i
        } else {
            path = path "/" $i
        }
        
        # Only print if we have not seen this folder before
        if (!(path in seen)) {
            seen[path] = 1
            # Calculate depth for indentation
            depth = gsub("/", "/", path)
            indent = ""
            for (j = 0; j < depth; j++) {
                indent = indent "  "
            }
            print indent path
        }
    }
}' "$manifest_file"

echo ""
echo "Summary Statistics:"
echo "=================="

# Show top-level folder counts
echo ""
echo "Files per top-level folder:"
awk -F'/' '{
    # Get the first meaningful folder after the mount point
    # Assuming format like /media/xxx/drive/Users/...
    if (NF > 4) {
        folder = $5
        if (folder != "") {
            count[folder]++
        }
    }
}
END {
    for (f in count) {
        printf "%-30s %d files\n", f, count[f]
    }
}' "$manifest_file" | sort -k2 -nr

# Show user folder statistics if Users folder exists
echo ""
if grep -q "/Users/" "$manifest_file"; then
    echo "User folder breakdown:"
    awk -F'/' '
    /\/Users\// {
        # Extract username and their first-level folder
        for (i = 1; i <= NF; i++) {
            if ($i == "Users" && i+2 <= NF) {
                user = $(i+1)
                if (i+2 < NF) {
                    folder = $(i+2)
                    key = user "/" folder
                    userfolders[key]++
                }
                users[user]++
                break
            }
        }
    }
    END {
        # First show total files per user
        print "\nFiles per user:"
        for (u in users) {
            printf "  %-25s %d files\n", u, users[u]
        }
        
        # Then show breakdown by user folders
        print "\nUser folder priorities:"
        for (uf in userfolders) {
            printf "  %-40s %d files\n", uf, userfolders[uf]
        }
    }' "$manifest_file" | sort -k2 -nr
fi

# Check for AppData timing
echo ""
echo "Special folder timing:"
echo ""

# Find line numbers for key folders
pictures_line=$(grep -n -m1 "/Pictures/" "$manifest_file" 2>/dev/null | cut -d: -f1)
documents_line=$(grep -n -m1 "/Documents/" "$manifest_file" 2>/dev/null | cut -d: -f1)
desktop_line=$(grep -n -m1 "/Desktop/" "$manifest_file" 2>/dev/null | cut -d: -f1)
appdata_line=$(grep -n -m1 "/AppData/" "$manifest_file" 2>/dev/null | cut -d: -f1)
downloads_line=$(grep -n -m1 "/Downloads/" "$manifest_file" 2>/dev/null | cut -d: -f1)

[ -n "$pictures_line" ] && echo "Pictures first appeared at line: $pictures_line"
[ -n "$documents_line" ] && echo "Documents first appeared at line: $documents_line"
[ -n "$desktop_line" ] && echo "Desktop first appeared at line: $desktop_line"
[ -n "$downloads_line" ] && echo "Downloads first appeared at line: $downloads_line"
[ -n "$appdata_line" ] && echo "AppData first appeared at line: $appdata_line"

# Show if any system folders were included
echo ""
echo "System folders detected:"
grep -E "/(Windows|Program Files|ProgramData|System32)/" "$manifest_file" | head -5 | sed 's/^/  /'
if grep -qE "/(Windows|Program Files|ProgramData|System32)/" "$manifest_file"; then
    echo "  ... and $(grep -cE '/(Windows|Program Files|ProgramData|System32)/' "$manifest_file") more system files"
fi