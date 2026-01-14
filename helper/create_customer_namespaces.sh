#!/bin/bash
#
# Script: create-customer_namespaces.sh
# Description: Creates one or more customer namespaces for vm deployment.
# Author: FOERSTERF with the help of Gemini

# === Defaults ===
DRY_RUN=false

# Function to display usage help
usage() {
    echo "Usage: $0 --customers customer1,customer2 [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --customers   Comma-separated list of customer names"
    echo "  --dry-run     Print commands without executing them"
    exit 1
}

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --customers) customers="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

# Check if the customers argument was provided
if [ -z "$customers" ]; then
    echo "Error: The parameter --customers is required."
    usage
fi

# Feedback for Dry-Run mode
if [ "$DRY_RUN" = true ]; then
    echo "!!! DRY-RUN MODE ACTIVE: No changes will be applied !!!"
    echo "-------------------------------------------------------"
fi

# Set IFS to comma to split the string into an array
IFS=',' read -ra CUSTOMER_LIST <<< "$customers"

# Iterate over each customer
for customer in "${CUSTOMER_LIST[@]}"; do
    # Trim whitespace
    customer=$(echo "$customer" | xargs)

    if [ -n "$customer" ]; then
        ns_name="har-${customer}-02"
        
        if [ "$DRY_RUN" = true ]; then
            # Dry-run: Just print the command
            echo "[DRY-RUN] Would execute: kubectl create namespace $ns_name"
        else
            # Real execution
            echo "--> Creating namespace: $ns_name"
            kubectl create namespace "$ns_name" || echo "Warning: Failed to create $ns_name (it might already exist)."
        fi
    fi
done

echo "Done."