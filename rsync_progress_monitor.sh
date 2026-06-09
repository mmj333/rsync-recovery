#!/bin/bash

# rsync_progress_monitor.sh - Real-time progress monitoring for rsync_recovery.sh
# Version 1.0.0
# This script displays transfer progress in a separate terminal window

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
PROGRESS_FILE="${1:-/tmp/rsync_progress_$$}"
DEST_PATH="${2:-}"
UPDATE_INTERVAL=1

# Check if progress file exists
if [ ! -p "$PROGRESS_FILE" ] && [ ! -f "$PROGRESS_FILE" ]; then
    echo "Error: Progress file not found: $PROGRESS_FILE"
    echo "This script should be launched by rsync_recovery.sh"
    exit 1
fi

# Terminal setup
clear
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}           RSYNC RECOVERY - PROGRESS MONITOR                    ${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Function to format bytes
format_bytes() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}B"
    elif [ $bytes -lt 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}")KB"
    elif [ $bytes -lt 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")MB"
    elif [ $bytes -lt 1099511627776 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}")TB"
    fi
}

# Function to draw progress bar
draw_progress_bar() {
    local percent=$1
    local width=50
    local filled=$(awk "BEGIN {printf \"%.0f\", $percent * $width / 100}")
    local empty=$((width - filled))
    
    echo -n "["
    if [ $filled -gt 0 ]; then
        printf "%${filled}s" | tr ' ' '█'
    fi
    if [ $empty -gt 0 ]; then
        printf "%${empty}s" | tr ' ' '░'
    fi
    echo -n "]"
}

# Function to calculate ETA
calculate_eta() {
    local percent=$1
    local elapsed=$2
    local rate=$3
    
    if [ "$percent" = "0" ] || [ -z "$rate" ] || [ "$rate" = "0" ]; then
        echo "Calculating..."
        return
    fi
    
    # Calculate remaining time based on percentage
    local total_time=$(awk "BEGIN {printf \"%.0f\", $elapsed * 100 / $percent}")
    local remaining=$((total_time - elapsed))
    
    if [ $remaining -lt 60 ]; then
        echo "${remaining}s"
    elif [ $remaining -lt 3600 ]; then
        local minutes=$((remaining / 60))
        local seconds=$((remaining % 60))
        echo "${minutes}m ${seconds}s"
    else
        local hours=$((remaining / 3600))
        local minutes=$(((remaining % 3600) / 60))
        echo "${hours}h ${minutes}m"
    fi
}

# Function to get disk space
get_disk_space() {
    local path=$1
    if [ -z "$path" ] || [ ! -d "$path" ]; then
        echo "N/A|N/A|0"
        return
    fi
    
    # Get disk usage for the filesystem containing the path
    df -h "$path" 2>/dev/null | awk 'NR==2 {
        gsub(/%/, "", $5)
        print $4 "|" $3 "|" $5
    }'
}

# Initialize variables
start_time=$(date +%s)
last_bytes=0
last_time=$start_time
stall_count=0
current_file=""
files_completed=0
total_files="Unknown"

# Main monitoring loop
while true; do
    # Read progress data
    if [ -p "$PROGRESS_FILE" ]; then
        # Named pipe - read with timeout
        if read -t 0.1 line < "$PROGRESS_FILE" 2>/dev/null; then
            # Parse progress data
            # Expected format: bytes|percent|rate|current_file|files_completed|total_files
            IFS='|' read -r bytes percent rate current_file files_completed total_files <<< "$line"
        fi
    elif [ -f "$PROGRESS_FILE" ]; then
        # Regular file - read last line
        line=$(tail -n 1 "$PROGRESS_FILE" 2>/dev/null)
        if [ -n "$line" ]; then
            IFS='|' read -r bytes percent rate current_file files_completed total_files <<< "$line"
        fi
    fi
    
    # Get current time
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    # Calculate transfer rate if not provided
    if [ -z "$rate" ] || [ "$rate" = "0" ]; then
        time_diff=$((current_time - last_time))
        if [ $time_diff -gt 0 ] && [ -n "$bytes" ] && [ $bytes -gt $last_bytes ]; then
            bytes_diff=$((bytes - last_bytes))
            rate=$((bytes_diff / time_diff))
            last_bytes=$bytes
            last_time=$current_time
        fi
    fi
    
    # Check for stalls
    if [ -n "$bytes" ] && [ "$bytes" = "$last_bytes" ]; then
        stall_count=$((stall_count + 1))
    else
        stall_count=0
        last_bytes=$bytes
    fi
    
    # Get disk space info
    IFS='|' read -r disk_free disk_used disk_percent <<< "$(get_disk_space "$DEST_PATH")"
    
    # Clear screen and redraw
    tput cup 4 0  # Move cursor to line 5
    
    # Progress bar
    echo -e "${BOLD}Overall Progress:${NC}"
    if [ -n "$percent" ]; then
        # Color based on status
        if [ $stall_count -gt 10 ]; then
            color=$RED
            status=" [STALLED]"
        elif [ -n "$rate" ] && [ $rate -lt 1048576 ]; then  # Less than 1MB/s
            color=$YELLOW
            status=" [SLOW]"
        else
            color=$GREEN
            status=""
        fi
        
        echo -ne "$color"
        draw_progress_bar ${percent%.*}
        echo -e " ${percent}%$status${NC}"
    else
        echo "Waiting for data..."
    fi
    echo ""
    
    # Transfer statistics
    echo -e "${BOLD}Transfer Statistics:${NC}"
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ]; then
        echo -e "  Transferred: $(format_bytes $bytes)"
    else
        echo -e "  Transferred: Waiting..."
    fi
    
    if [ -n "$rate" ] && [ "$rate" -gt 0 ]; then
        echo -e "  Speed: $(format_bytes $rate)/s"
    else
        echo -e "  Speed: Calculating..."
    fi
    
    # Calculate and display ETA
    if [ -n "$percent" ] && [ -n "$elapsed" ]; then
        eta=$(calculate_eta ${percent%.*} $elapsed "$rate")
        echo -e "  ETA: $eta"
    else
        echo -e "  ETA: Calculating..."
    fi
    
    # Elapsed time
    if [ $elapsed -lt 60 ]; then
        echo -e "  Elapsed: ${elapsed}s"
    elif [ $elapsed -lt 3600 ]; then
        echo -e "  Elapsed: $((elapsed / 60))m $((elapsed % 60))s"
    else
        echo -e "  Elapsed: $((elapsed / 3600))h $(((elapsed % 3600) / 60))m"
    fi
    echo ""
    
    # File progress
    echo -e "${BOLD}File Progress:${NC}"
    if [ -n "$files_completed" ] && [ -n "$total_files" ]; then
        echo -e "  Files: $files_completed / $total_files"
    else
        echo -e "  Files: Counting..."
    fi
    
    if [ -n "$current_file" ] && [ "$current_file" != "none" ]; then
        # Truncate long filenames
        max_len=60
        if [ ${#current_file} -gt $max_len ]; then
            display_file="...${current_file: -$((max_len-3))}"
        else
            display_file="$current_file"
        fi
        echo -e "  Current: $display_file"
    else
        echo -e "  Current: Scanning..."
    fi
    echo ""
    
    # Destination disk space
    echo -e "${BOLD}Destination Disk Space:${NC}"
    if [ "$disk_percent" != "0" ]; then
        echo -e "  Used: $disk_used ($disk_percent%)"
        echo -e "  Free: $disk_free"
        
        # Disk space bar
        echo -n "  "
        if [ $disk_percent -gt 90 ]; then
            echo -ne "$RED"
        elif [ $disk_percent -gt 80 ]; then
            echo -ne "$YELLOW"
        else
            echo -ne "$GREEN"
        fi
        draw_progress_bar $disk_percent
        echo -e "${NC}"
    else
        echo -e "  Checking..."
    fi
    echo ""
    
    # Check if transfer is complete
    if [ -n "$percent" ] && [ "${percent%.*}" -ge "100" ]; then
        echo -e "${GREEN}${BOLD}Transfer Complete!${NC}"
        echo "Press any key to close this window..."
        read -n 1
        break
    fi
    
    # Check if progress file still exists (main script still running)
    if [ ! -e "$PROGRESS_FILE" ]; then
        echo -e "${YELLOW}Main recovery process has ended.${NC}"
        echo "Press any key to close this window..."
        read -n 1
        break
    fi
    
    # Wait before next update
    sleep $UPDATE_INTERVAL
done

# Cleanup
rm -f "$PROGRESS_FILE" 2>/dev/null

exit 0