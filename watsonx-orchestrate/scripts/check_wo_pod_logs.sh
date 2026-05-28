#!/bin/bash

################################################################################
# Script: check_wo_pod_logs.sh
# Description: Check WatsonX Orchestrate pod logs for actual errors
# Author: Manu Thapar
# Version: 2.0
# 
# Updates:
# - Exclude INFO and DEBUG level logs that contain error keywords
# - Exclude empty error fields like "error":""
# - Focus on actual ERROR/FATAL logs and real exceptions
# - Improved filtering to reduce false positives
# - Default time period changed to 5m
# - Added 20-second timeout per pod to prevent hanging
# - Interactive mode for easy use
################################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default values
NAMESPACE=""
TIME_PERIOD="5m"
SEARCH_ALL=false
SEARCH_PATTERN=""
OUTPUT_FILE=""
VERBOSE=false
TIMEOUT=20
INTERACTIVE=false

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Check WatsonX Orchestrate pod logs for actual errors (excluding INFO/DEBUG false positives)

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (auto-detected if not provided)
    -t, --time PERIOD           Time period to check (default: 5m)
                                Examples: 5m, 1h, 2h, 1d
    -a, --all                   Search for all common error patterns
    -s, --search PATTERN        Search for specific pattern (supports regex: "text1|text2")
    -m, --match STRING          Search for exact string match (case-insensitive)
    -o, --output FILE           Save output to file
    -v, --verbose               Show full output (no truncation)
    -i, --interactive           Interactive mode (prompts for options)
    -h, --help                  Show this help message

EXAMPLES:
    # Interactive mode
    $0 -i

    # Check last 5 minutes in auto-detected namespace
    $0 -a

    # Check last 10 minutes for all errors
    $0 -t 10m -a

    # Check specific namespace for last 2 hours
    $0 -n cpd-instance-1 -t 2h -a

    # Search for specific pattern (regex)
    $0 -s "connection refused|timeout|failed" -t 30m

    # Search for exact string match
    $0 -m "database connection" -t 30m

    # Save output to file
    $0 -a -o error_report.txt

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -t|--time)
            TIME_PERIOD="$2"
            shift 2
            ;;
        -a|--all)
            SEARCH_ALL=true
            shift
            ;;
        -s|--search)
            SEARCH_PATTERN="$2"
            shift 2
            ;;
        -m|--match)
            SEARCH_PATTERN="$2"
            SEARCH_ALL=false
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -i|--interactive)
            INTERACTIVE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Function to print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Function to print header
print_header() {
    echo ""
    print_color "$BLUE" "╔══════════════════════════════════════════════════════════════════════════════╗"
    print_color "$BLUE" "║           WatsonX Orchestrate Pod Logs Error Checker                        ║"
    print_color "$BLUE" "║                    Author: Manu Thapar                                       ║"
    print_color "$BLUE" "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

# Function to detect namespace
detect_namespace() {
    if [ -z "$NAMESPACE" ]; then
        # Try to find namespace with WatsonX Orchestrate
        NAMESPACE=$(oc get wo --all-namespaces 2>/dev/null | grep -v NAMESPACE | head -1 | awk '{print $1}')
        
        if [ -z "$NAMESPACE" ]; then
            print_color "$RED" "Error: Could not auto-detect namespace. Please specify with -n option."
            exit 1
        fi
        
        if [ "$INTERACTIVE" = false ]; then
            print_color "$GREEN" "Auto-detected namespace: $NAMESPACE"
        fi
    fi
}

# Interactive mode function
interactive_mode() {
    print_header
    
    # Detect namespace
    detect_namespace
    
    print_color "$GREEN" "Detected namespace: $NAMESPACE"
    read -p "Use this namespace? (y/n): " use_ns
    if [[ ! $use_ns =~ ^[Yy]$ ]]; then
        read -p "Enter namespace: " NAMESPACE
    fi
    
    echo ""
    print_color "$BLUE" "Time period options:"
    echo "  1) 5 minutes (default)"
    echo "  2) 10 minutes"
    echo "  3) 30 minutes"
    echo "  4) 1 hour"
    echo "  5) 2 hours"
    echo "  6) Custom"
    read -p "Select time period [1-6] (default: 1): " time_choice
    
    case $time_choice in
        2) TIME_PERIOD="10m" ;;
        3) TIME_PERIOD="30m" ;;
        4) TIME_PERIOD="1h" ;;
        5) TIME_PERIOD="2h" ;;
        6) 
            read -p "Enter custom time period (e.g., 15m, 3h): " TIME_PERIOD
            ;;
        *) TIME_PERIOD="5m" ;;
    esac
    
    echo ""
    print_color "$BLUE" "Search options:"
    echo "  1) All common errors (recommended)"
    echo "  2) Custom regex pattern (e.g., 'error1|error2|error3')"
    echo "  3) Exact string match (case-insensitive)"
    read -p "Select search option [1-3] (default: 1): " search_choice
    
    case $search_choice in
        2)
            read -p "Enter regex pattern (use | for multiple): " SEARCH_PATTERN
            print_color "$YELLOW" "Using regex pattern: $SEARCH_PATTERN"
            ;;
        3)
            read -p "Enter exact string to match: " SEARCH_PATTERN
            print_color "$YELLOW" "Using exact match: $SEARCH_PATTERN"
            ;;
        *)
            SEARCH_ALL=true
            ;;
    esac
    
    echo ""
    read -p "Save output to file? (y/n): " save_file
    if [[ $save_file =~ ^[Yy]$ ]]; then
        read -p "Enter filename: " OUTPUT_FILE
    fi
    
    echo ""
    read -p "Show full output (no truncation)? (y/n): " show_full
    if [[ $show_full =~ ^[Yy]$ ]]; then
        VERBOSE=true
    fi
    
    echo ""
}

# Function to check pod logs with improved filtering and timeout
check_pod_logs() {
    local pod=$1
    local since=$2
    local pattern=$3
    
    # Get logs with timeout and apply filtering
    local logs=$(timeout $TIMEOUT oc logs "$pod" -n "$NAMESPACE" --since="$since" 2>/dev/null | \
        grep -E "$pattern" | \
        grep -v '"level":"INFO"' | \
        grep -v '"level":"DEBUG"' | \
        grep -v '"level":"TRACE"' | \
        grep -v '"error":""' | \
        grep -v '"error":""}' | \
        grep -v 'level=info' | \
        grep -v 'level=debug' | \
        grep -v 'level=trace' | \
        grep -v '\[INFO\].*\[failed=0\]' | \
        grep -v '\[INFO\].*\[Failed.*:0\]' | \
        grep -v 'import task stats.*failed=0' | \
        grep -v 'import job stats.*Failed.*:0')
    
    local exit_code=$?
    
    # Check if timeout occurred
    if [ $exit_code -eq 124 ]; then
        print_color "$YELLOW" "⚠ Pod $pod: Timeout after ${TIMEOUT}s, skipping..."
        return 2
    fi
    
    if [ -n "$logs" ]; then
        local line_count=$(echo "$logs" | wc -l | tr -d ' ')
        
        print_color "$YELLOW" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_color "$RED" "Pod: $pod"
        print_color "$BLUE" "Found $line_count matching line(s)"
        print_color "$YELLOW" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if [ "$VERBOSE" = true ] || [ "$line_count" -le 25 ]; then
            echo "$logs"
        else
            echo "$logs" | head -25
            print_color "$YELLOW" "... (showing first 25 lines, use -v for full output) ..."
        fi
        
        echo ""
        return 0
    fi
    
    return 1
}

# Main execution
main() {
    # Run interactive mode if requested
    if [ "$INTERACTIVE" = true ]; then
        interactive_mode
    else
        print_header
        
        # Detect namespace if not provided
        detect_namespace
        
        # Validate inputs
        if [ "$SEARCH_ALL" = false ] && [ -z "$SEARCH_PATTERN" ]; then
            print_color "$RED" "Error: Must specify either -a (all errors), -s PATTERN (regex), or -m STRING (exact match)"
            usage
        fi
    fi
    
    # Build grep pattern - focusing on actual errors
    if [ "$SEARCH_ALL" = true ]; then
        # Pattern for actual errors, excluding INFO/DEBUG level logs
        grep_pattern='"level":"ERROR"|"level":"FATAL"|level=error|level=fatal|\[ERROR\]|\[FATAL\]|Exception:|Traceback|panic:|PANIC:|Error:|ERROR:|Fatal:|FATAL:|failed to|Failed to|FAILED TO|cannot|Cannot|CANNOT'
    else
        grep_pattern="$SEARCH_PATTERN"
    fi
    
    # Get list of WatsonX Orchestrate pods
    print_color "$BLUE" "Fetching WatsonX Orchestrate pods from namespace: $NAMESPACE"
    
    local pods=$(oc get pods -n "$NAMESPACE" 2>/dev/null | \
        grep -E "^(wo-|tf-|milvus)" | \
        grep -v "Completed" | \
        awk '{print $1}')
    
    if [ -z "$pods" ]; then
        print_color "$RED" "Error: No WatsonX Orchestrate pods found in namespace $NAMESPACE"
        exit 1
    fi
    
    local pod_count=$(echo "$pods" | wc -l | tr -d ' ')
    print_color "$GREEN" "Found $pod_count pods"
    echo ""
    
    # Print search criteria
    print_color "$BLUE" "Search Criteria:"
    echo "  Namespace: $NAMESPACE"
    echo "  Time Period: $TIME_PERIOD"
    echo "  Timeout per pod: ${TIMEOUT}s"
    if [ "$SEARCH_ALL" = true ]; then
        echo "  Pattern: Actual errors (ERROR/FATAL level, exceptions, failures)"
        echo "  Filtering: Excluding INFO/DEBUG logs and empty error fields"
    else
        echo "  Pattern: $SEARCH_PATTERN"
    fi
    echo ""
    
    # Check each pod
    local total_errors=0
    local pods_with_errors=0
    local pods_timeout=0
    local current_pod=0
    
    # Redirect output to file if specified
    if [ -n "$OUTPUT_FILE" ]; then
        exec > >(tee "$OUTPUT_FILE")
    fi
    
    for pod in $pods; do
        current_pod=$((current_pod + 1))
        echo -ne "Checking pod $current_pod/$pod_count: $pod..."
        echo -ne "\r"
        
        check_pod_logs "$pod" "$TIME_PERIOD" "$grep_pattern"
        local result=$?
        
        if [ $result -eq 0 ]; then
            pods_with_errors=$((pods_with_errors + 1))
        elif [ $result -eq 2 ]; then
            pods_timeout=$((pods_timeout + 1))
        fi
    done
    
    # Clear the progress line
    echo -ne "\033[2K\r"
    
    # Print summary
    print_color "$YELLOW" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_color "$BOLD" "Summary:"
    echo "  Total pods checked: $pod_count"
    echo "  Pods with actual errors: $pods_with_errors"
    
    if [ $pods_timeout -gt 0 ]; then
        print_color "$YELLOW" "  Pods timed out: $pods_timeout"
    fi
    
    if [ "$pods_with_errors" -eq 0 ]; then
        print_color "$GREEN" "  ✓ No actual errors found in the specified time period"
    else
        print_color "$RED" "  ✗ Found actual errors in $pods_with_errors pod(s)"
    fi
    
    print_color "$YELLOW" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -n "$OUTPUT_FILE" ]; then
        print_color "$GREEN" "Output saved to: $OUTPUT_FILE"
    fi
    
    echo ""
}

# Run main function
main

# Made with Bob
