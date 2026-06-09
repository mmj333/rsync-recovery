#!/bin/bash

# Utility functions for displaying partition information

# Function to calculate and format used space
calculate_used_space() {
    local total_size="$1"
    local used_percent="$2"
    
    # Skip if no percentage
    if [[ ! "$used_percent" =~ ^[0-9]+% ]]; then
        echo ""
        return
    fi
    
    local used_num=${used_percent%\%}
    
    # Extract size value and unit
    local size_value=""
    local size_unit=""
    
    if [[ "$total_size" =~ ^([0-9.]+)([KMGT])i?B?$ ]]; then
        size_value="${BASH_REMATCH[1]}"
        size_unit="${BASH_REMATCH[2]}"
    else
        echo ""
        return
    fi
    
    # Convert to integer for bash arithmetic
    local size_int=${size_value%.*}
    [ "$size_int" = "$size_value" ] && size_int=$size_value
    
    # Calculate in appropriate unit to avoid overflow
    local used_value=0
    case "$size_unit" in
        K) 
            used_value=$((size_int * used_num / 100))
            [ $used_value -gt 1024 ] && echo "$((used_value / 1024))MB" || echo "${used_value}KB"
            ;;
        M) 
            used_value=$((size_int * used_num / 100))
            [ $used_value -gt 1024 ] && echo "$((used_value / 1024))GB" || echo "${used_value}MB"
            ;;
        G) 
            used_value=$((size_int * used_num / 100))
            [ $used_value -gt 1024 ] && echo "$((used_value / 1024))TB" || echo "${used_value}GB"
            ;;
        T) 
            # For TB, show in GB to avoid overflow
            local gb_value=$((size_int * 1024))
            used_value=$((gb_value * used_num / 100))
            echo "${used_value}GB"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to format bytes to human readable
format_bytes() {
    local bytes="$1"
    
    # Handle empty or zero
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0B"
        return
    fi
    
    # Use numfmt if available
    if command -v numfmt &> /dev/null; then
        numfmt --to=iec-i --suffix=B --format="%.1f" "$bytes" 2>/dev/null || echo "0B"
        return
    fi
    
    # Manual calculation if numfmt not available
    local tb=$((bytes / 1099511627776))
    local gb=$((bytes / 1073741824))
    local mb=$((bytes / 1048576))
    local kb=$((bytes / 1024))
    
    if [ $tb -gt 0 ]; then
        local tb_decimal=$((bytes % 1099511627776 * 10 / 1099511627776))
        echo "${tb}.${tb_decimal}TB"
    elif [ $gb -gt 0 ]; then
        local gb_decimal=$((bytes % 1073741824 * 10 / 1073741824))
        echo "${gb}.${gb_decimal}GB"
    elif [ $mb -gt 0 ]; then
        local mb_decimal=$((bytes % 1048576 * 10 / 1048576))
        echo "${mb}.${mb_decimal}MB"
    elif [ $kb -gt 0 ]; then
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

# Function to format partition size display
format_size_display() {
    local total_size="$1"
    local used_percent="$2"
    local free_space="$3"
    
    local output="Size: $total_size"
    
    # Add used percentage and calculated size
    if [[ "$used_percent" != "N/A" ]]; then
        local used_space=$(calculate_used_space "$total_size" "$used_percent")
        if [ -n "$used_space" ]; then
            output="$output | Used: $used_percent ($used_space)"
        else
            output="$output | Used: $used_percent"
        fi
        
        # Add free space if available
        if [[ "$free_space" != "N/A" ]] && [ -n "$free_space" ]; then
            output="$output | Free: $free_space"
        fi
    else
        output="$output | Used: N/A"
    fi
    
    echo "$output"
}

# Export functions
export -f calculate_used_space
export -f format_bytes
export -f format_size_display